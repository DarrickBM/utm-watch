import Combine
import Foundation
import UTMWatchCore
import UTMWatchFleet
import UTMWatchStore

/// UI-facing state. Only ever touched on the main thread.
final class AppModel: ObservableObject {
    @Published var snapshot: Snapshot?
    /// The Mac's network link as of the last probe round.
    @Published var link: LinkInfo?
    let ring = LiveRing()
    let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
        // @Published fires before the value changes; hop to the next main-loop turn to read the new one.
        otherVMsSetting = settings.$showOtherVMs.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
            guard let self, let full = self.fullSnapshot else { return }
            self.snapshot = self.shown(full)
        }
    }

    /// The latest sample with every VM in it. `snapshot` is what the views show, which leaves out
    /// other apps' VMs when the user has hidden them; recording always gets this one.
    private var fullSnapshot: Snapshot?
    private var otherVMsSetting: AnyCancellable?

    private func shown(_ snap: Snapshot) -> Snapshot {
        guard !settings.showOtherVMs else { return snap }
        var s = snap
        s.rows.removeAll { OtherVMs.isOther(key: $0.id) }
        return s
    }

    /// True while something is outside its normal range; drives the menu bar warning mark.
    var hasWarning: Bool {
        guard let s = snapshot else { return false }
        return Explain.pressure(s.host) != nil || Explain.swap(s.host) != nil || s.rows.contains { Explain.cpu($0) != nil }
            || Explain.link(link) != nil
    }
    private(set) var store: HistoryStore?
    private var recorder: Recorder?
    /// Sends the recorded history to the fleet's hub; nil when this Mac is not in a fleet.
    private(set) var uploader: Uploader?
    private var detector = EventDetector()
    /// Each VM's name in UTM, kept so clearing a user-given name can bring it back.
    private var utmNames: [String: String] = [:]

    /// Gives a VM the user's own name; an empty name returns it to its UTM name. UTM is not changed.
    func rename(vm key: String, to newName: String) {
        var name = VMName.clean(newName)
        // Typing the UTM name back is the same as clearing it: the VM follows UTM again if it is renamed there.
        if name == utmNames[key] { name = "" }
        if name.isEmpty { settings.vmAliases[key] = nil } else { settings.vmAliases[key] = name }
        // A VM that UTM no longer lists has no name to fall back to; it keeps the one it has.
        guard let shown = name.isEmpty ? utmNames[key] : name else { return }
        if var snap = fullSnapshot, let i = snap.rows.firstIndex(where: { $0.id == key }) {
            snap.rows[i].name = shown
            fullSnapshot = snap
            snapshot = self.shown(snap)
        }
        ring.rename(key, to: shown)
        if let store { DispatchQueue.global(qos: .utility).async { store.rename(key: key, to: shown) } }
    }

    var running: [VMRow] { (snapshot?.rows ?? []).filter { $0.pid != nil } }

    /// Menu bar text, e.g. "2 VM · 4.2 cores".
    var title: String {
        guard snapshot != nil else { return "VM …" }
        let vms = running
        guard !vms.isEmpty else { return "0 VM" }
        let cores = vms.reduce(0.0) { $0 + ($1.cpuCores ?? 0) }
        return "\(vms.count) VM · \(String(format: "%.1f", cores)) cores"
    }

    /// Opens the history store and seeds the in-memory ring with the last hour.
    func attachStore() {
        do {
            let s = try HistoryStore()
            store = s
            recorder = Recorder(store: s)
            let now = Date().msSince1970
            let recent = s.load(from: now - LiveRing.keepMs, to: now, maxPoints: nil)
            ring.prefill(recent, knownVMs: s.knownVMs())
            // Carry the last known state across a restart (if it is fresh) so active conditions are not re-logged.
            if let last = recent.host.last, now - last.t < 10 * 60_000 {
                detector.seed(pressure: last.pressure, swapHigh: last.swapTotal > 0 && last.swapUsed / last.swapTotal >= 0.8)
            }
            FileLog.shared.log("history store open at \(s.path), \(s.stats().sampleCount) host samples")
        } catch {
            FileLog.shared.log("history store unavailable, running without recording: \(error)")
        }
    }

    /// Starts sending this Mac's history to its fleet's hub. Without this call the app is the single-Mac app it always was.
    func attachFleet(identity: HostIdentity, client: HubClient, onStatus: @escaping (Uploader.Status) -> Void) {
        detachFleet()
        guard let store, !identity.hostToken.isEmpty else { return }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let up = Uploader(store: store, client: client, token: identity.hostToken, appVersion: version)
        up.onStatus = { status in
            switch status.state {
            case .starting: break
            case .upToDate: FileLog.shared.log("fleet: up to date with the hub")
            case .catchingUp: FileLog.shared.log("fleet: sending older history to the hub")
            case .unreachable: FileLog.shared.log("fleet: hub not reachable, recording locally and will catch up")
            case .rejected(let why): FileLog.shared.log("fleet: the hub refused this Mac: \(why)")
            }
            DispatchQueue.main.async { onStatus(status) }
        }
        up.setLive(snapshot: snapshot); up.setLive(link: link)
        up.start()
        uploader = up
        FileLog.shared.log("fleet: reporting to \(identity.hubURL) as \(identity.name) (\(identity.hostUUID))")
    }

    func detachFleet() {
        uploader?.stop()
        uploader = nil
    }

    /// Called on the main thread for every new sample.
    func ingest(_ raw: Snapshot) {
        // Rows leave here under the user's own names, so the views, the recorded history and the
        // MCP tools all show the same name.
        var snap = raw
        for i in snap.rows.indices {
            utmNames[snap.rows[i].id] = snap.rows[i].name
            if let alias = settings.vmAliases[snap.rows[i].id] { snap.rows[i].name = alias }
        }
        // The first sample or two after launch come before the VM configs are read, so limits and
        // headroom are not known yet. Show them, but do not record them as history.
        fullSnapshot = snap
        guard !snap.notices.contains(where: { $0.hasPrefix("Reading configs") }) else { snapshot = shown(snap); return }
        let events = detector.ingest(snap)
        let urgent = events.filter { ["pressure_warning", "pressure_critical", "swap_high", "cpu_limit"].contains($0.kind) }
        let plain = events.filter { !urgent.contains($0) }
        ring.append(snap, events: plain)
        recorder?.add(snap, events: plain)
        uploader?.setLive(snapshot: snap)
        snapshot = shown(snap)
        if !urgent.isEmpty { recordWithProcesses(urgent) }
    }

    /// Called on the main thread for every round of network probes.
    func ingestProbe(_ p: ProbeResult) {
        ring.append(p)
        recorder?.add(p)
        record(detector.ingest(p))
        uploader?.setLive(link: p.link)
        link = p.link
    }

    func record(_ events: [HistoryEvent]) {
        guard !events.isEmpty else { return }
        ring.addEvents(events)
        recorder?.add(events: events)
    }

    /// Attaches the busiest processes to warning events, so a later diagnosis can say why.
    private func recordWithProcesses(_ events: [HistoryEvent]) {
        guard settings.captureProcesses else { record(events); return }
        // VM processes all share one system name; label them with the VM's own name instead.
        var vmNames: [Int32: String] = [:]
        for row in fullSnapshot?.rows ?? [] { if let pid = row.pid { vmNames[pid] = "VM: \(row.name)" } }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let top = ProcessTop.capture()
            func name(_ p: TopProcess) -> String { vmNames[p.pid] ?? p.name }
            let detail: [String: Any] = [
                "topMemory": top.byMemory.map { ["name": name($0), "pid": Int($0.pid), "memoryGB": (Double($0.memoryBytes) / 1_073_741_824 * 100).rounded() / 100] },
                "topCPU": top.byCPU.map { ["name": name($0), "pid": Int($0.pid), "cores": $0.cpuCores] },
            ]
            let json = (try? JSONSerialization.data(withJSONObject: detail)).map { String(decoding: $0, as: UTF8.self) }
            DispatchQueue.main.async {
                self?.record(events.map { e in var e = e; e.detail = json; return e })
            }
        }
    }

    func flush(wait: Bool) { recorder?.flush(wait: wait) }

    func clearHistory() {
        recorder?.discardPending()
        store?.clear()
        ring.clear()
    }
}

/// Runs the engine on a background timer and hands each snapshot to the main thread.
final class Sampler {
    private let engine = MonitorEngine()
    private let queue = DispatchQueue(label: "utmwatch.sampler", qos: .utility)
    private var timer: DispatchSourceTimer?
    private weak var model: AppModel?
    private var interval: Double = 2
    private let probe = NetProbe()
    private let probeQueue = DispatchQueue(label: "utmwatch.probe", qos: .utility)
    private var probeTimer: DispatchSourceTimer?
    private var lastProbeDiagnostics = ""

    init(model: AppModel) { self.model = model }

    /// Network probes run on their own queue every 10 s: an unanswered ping takes a second and must not delay sampling.
    func startProbes(every seconds: Double = 10) {
        let t = DispatchSource.makeTimerSource(queue: probeQueue)
        t.schedule(deadline: .now() + 3, repeating: seconds, leeway: .milliseconds(500))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            autoreleasepool {
                let result = self.probe.run(targets: self.engine.networkTargets())
                let d = self.probe.diagnostics
                if d != self.lastProbeDiagnostics { self.lastProbeDiagnostics = d; FileLog.shared.log("probe: \(d)") }
                DispatchQueue.main.async { self.model?.ingestProbe(result) }
            }
        }
        t.resume()
        probeTimer = t
    }

    func start(interval: Double) {
        queue.sync { self.interval = interval }
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            autoreleasepool {
                let snap = self.engine.tick(interval: self.interval)
                DispatchQueue.main.async { self.model?.ingest(snap) }
            }
        }
        t.resume()
        timer = t
    }
}

/// VMs that run outside UTM. The engine keys them "pid:<n>" because they have no UTM identity.
enum OtherVMs {
    static func isOther(key: String) -> Bool { key.hasPrefix("pid:") }

    /// The same history without those VMs: their lines, limits and start/stop events.
    static func hidden(in history: History) -> History {
        var h = history
        h.vms.removeAll { isOther(key: $0.key) }
        h.series = h.series.filter { !isOther(key: $0.key) }
        h.configs = h.configs.filter { !isOther(key: $0.key) }
        h.events.removeAll { $0.vmKey.map(isOther) ?? false }
        return h
    }
}
