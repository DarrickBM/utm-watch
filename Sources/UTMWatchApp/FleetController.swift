import AppKit
import Combine
import Foundation
import UserNotifications
import UTMWatchCore
import UTMWatchFleet
import UTMWatchStore

/// The private network helper's state, as the Settings window shows it.
enum NetState: Equatable {
    case off
    case starting
    /// Joined. `proxy` is the helper's loopback proxy; `address` is this Mac's address on the fleet's network.
    case ready(proxy: String, address: String)
    /// The key was missing, wrong or has expired.
    case needsKey
    case failed(String)
}

/// Everything about this Mac's place in a fleet: joining and leaving, hosting the hub, the private network helper,
/// and what the fleet window shows. Only ever touched on the main thread; slow work goes to its own queue.
/// With no fleet configured it does nothing, and the app is the single-Mac app it always was.
final class FleetController: ObservableObject {
    // This Mac
    @Published private(set) var identity: HostIdentity?
    @Published private(set) var upload: Uploader.Status?
    @Published private(set) var joining = false
    @Published var joinError: String?
    // Hosting the hub
    @Published private(set) var hubRunning = false
    @Published private(set) var hubError: String?
    @Published private(set) var enrolled: [HostStatus] = []
    @Published var pairingCode: String?
    @Published private(set) var net: NetState = .off
    // The fleet view
    @Published private(set) var hosts: [HostStatus] = []
    @Published private(set) var hostsError: String?
    @Published private(set) var loadedOnce = false
    @Published private(set) var updatedAt: Date?
    /// The Mac the fleet window has drilled into, by UUID; nil shows the overview.
    @Published private(set) var selected: String?

    /// True while the fleet window is open, so nothing is asked of the hub for an invisible view.
    var viewActive = false { didSet { if viewActive { pollHosts() } } }

    let settings: AppSettings
    /// A stand-in model for the Mac being looked at in the drill-in, so the detail window's views work unchanged.
    let mirror: AppModel
    let remoteDetail: DetailModel
    private weak var model: AppModel?
    private let work = DispatchQueue(label: "utmwatch.fleet", qos: .utility)
    private var hubProcess: Process?
    private var hubStore: HubStore?
    private var netProcess: Process?
    private var netBuffer = Data()
    private var timer: Timer?
    private var tick = 0
    private var lastEventID: Int64 = 0
    private let startedAt = Date().msSince1970
    private var cancellables: Set<AnyCancellable> = []
    private var askedForNotifications = false

    private var dataDir: URL { HostIdentity.dataDirectory }
    private var hubDatabase: String { dataDir.appendingPathComponent("hub.sqlite").path }
    private var netDirectory: String { dataDir.appendingPathComponent("net", isDirectory: true).path }
    private var hubConfigPath: String { dataDir.appendingPathComponent("fleet-hub.json").path }
    private var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }

    /// What the hub Mac keeps for itself: the key that lets other Macs onto the fleet's private network.
    private struct HubConfig: Codable { var authKey: String? }
    private var hubConfig: HubConfig {
        get { FileManager.default.contents(atPath: hubConfigPath).flatMap { try? JSONDecoder().decode(HubConfig.self, from: $0) } ?? HubConfig() }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            _ = FileManager.default.createFile(atPath: hubConfigPath, contents: data, attributes: [.posixPermissions: 0o600])
        }
    }

    static var defaultName: String { Host.current().localizedName ?? ProcessInfo.processInfo.hostName }

    init(settings: AppSettings, model: AppModel) {
        self.settings = settings
        self.model = model
        mirror = AppModel(settings: settings)
        remoteDetail = DetailModel(model: mirror, settings: settings)
    }

    // MARK: Lifecycle

    func start() {
        identity = HostIdentity.load()
        // The helper's own state is enough to rejoin; the key is only needed the first time.
        if FileManager.default.fileExists(atPath: netDirectory) { startNet(key: nil) }
        if settings.hostHub { startHub() }
        syncUploader()
        settings.$fleetReportingPaused.dropFirst().removeDuplicates().receive(on: RunLoop.main).sink { [weak self] _ in self?.syncUploader() }.store(in: &cancellables)
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.everyFiveSeconds() }
        t.tolerance = 1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Stops the helper programs; called when the app quits so none is left running without it.
    func shutdown() {
        let hub = hubProcess, net = netProcess
        hubProcess = nil; netProcess = nil
        hub?.terminate(); net?.terminate()
    }

    private func everyFiveSeconds() {
        tick += 1
        if viewActive { pollHosts() }
        if tick % 3 == 0 {
            pollEvents()
            if hubRunning { refreshEnrolled() }
        }
    }

    /// A helper program shipped beside the app's own executable.
    private func helper(_ name: String) -> URL? {
        var places: [URL] = []
        if let dir = ProcessInfo.processInfo.environment["UTMWATCH_HELPERS"] { places.append(URL(fileURLWithPath: dir).appendingPathComponent(name)) }
        if let url = Bundle.main.url(forAuxiliaryExecutable: name) { places.append(url) }
        return places.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    // MARK: Reporting

    private func client(for id: HostIdentity) -> HubClient? {
        guard id.viaPrivateNetwork == true else { return HubClient(baseURL: id.hubURL) }
        guard case .ready(let proxy, _) = net else { return nil }
        // Short timeout: the first request after the helper starts can stall, and the caller retries.
        return HubClient(baseURL: id.hubURL, transport: URLSessionTransport(timeout: 8, proxy: proxy))
    }

    /// Starts, restarts or stops the uploader to match the identity, the pause switch and the network helper.
    private func syncUploader() {
        model?.detachFleet()
        upload = nil
        guard let id = identity, !id.hostToken.isEmpty, !settings.fleetReportingPaused, let client = client(for: id) else { return }
        model?.attachFleet(identity: id, client: client) { [weak self] status in self?.upload = status }
    }

    /// Joins the fleet a pairing code belongs to. The code carries the hub's address, so it is all a Mac needs.
    func join(code text: String, name: String) {
        guard !joining else { return }
        guard let code = PairingCode(text: text) else {
            joinError = "That is not a pairing code. Copy the whole code from the hub Mac's Settings, starting with “utmw1.”."
            return
        }
        guard !settings.hostHub else { joinError = "This Mac hosts a hub. Switch that off before joining another fleet."; return }
        joining = true; joinError = nil
        let shownName = name.trimmingCharacters(in: .whitespaces).isEmpty ? FleetController.defaultName : name.trimmingCharacters(in: .whitespaces)
        // Joining again keeps this Mac's UUID, so the hub keeps its history.
        let uuid = identity.flatMap { $0.hostUUID.isEmpty ? nil : $0.hostUUID } ?? UUID().uuidString.lowercased()
        let overNet = code.authKey != nil
        if let key = code.authKey { startNet(key: key) }
        let request = EnrollRequest(hostUUID: uuid, name: shownName, appVersion: version)
        work.async { [weak self] in
            var proxy: String?
            if overNet {
                // Wait for the helper to join the fleet's network: about two seconds the first time.
                for _ in 0..<120 {
                    let state = DispatchQueue.main.sync { self?.net ?? .off }
                    if case .ready(let p, _) = state { proxy = p; break }
                    if case .needsKey = state { self?.finishJoin(error: "The fleet's network did not accept the key in this pairing code. Ask for a new code."); return }
                    if case .failed(let why) = state { self?.finishJoin(error: why); return }
                    Thread.sleep(forTimeInterval: 0.5)
                }
                guard proxy != nil else { self?.finishJoin(error: "Could not reach the fleet's network. Check this Mac's internet connection and try again."); return }
            }
            let client = HubClient(baseURL: code.hub, transport: URLSessionTransport(timeout: 8, proxy: proxy))
            var result = client.enroll(code: code.token, request: request)
            for _ in 0..<2 where result == .failure(.unreachable) { result = client.enroll(code: code.token, request: request) }
            switch result {
            case .success(let reply):
                let id = HostIdentity(hostUUID: uuid, name: shownName, hubURL: code.hub, hostToken: reply.hostToken, readerToken: reply.readerToken, viaPrivateNetwork: overNet ? true : nil)
                do { try id.save() } catch { self?.finishJoin(error: "Joined, but could not save this Mac's fleet identity: \(error.localizedDescription)"); return }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.identity = id; self.joining = false
                    self.settings.fleetReportingPaused = false
                    self.syncUploader()
                    self.pollHosts()
                    FileLog.shared.log("fleet: joined \(code.hub) as \(shownName)")
                }
            case .failure(.unreachable):
                self?.finishJoin(error: "No answer from the hub at \(code.hub). Check that the hub Mac is on and that this Mac can reach it.")
            case .failure(.rejected(let status, let message)):
                self?.finishJoin(error: status == 401 ? "This pairing code was already used or has expired. Ask for a new one." : message)
            }
        }
    }

    private func finishJoin(error: String) {
        DispatchQueue.main.async {
            self.joining = false; self.joinError = error
            // A helper started only for this attempt has nothing to do now.
            if self.identity?.viaPrivateNetwork != true, !self.settings.hostHub { self.stopNet(forget: true) }
        }
    }

    /// Stops reporting and forgets the hub. History already on the hub stays there until it ages out.
    func leave() {
        model?.detachFleet()
        HostIdentity.remove()
        identity = nil; upload = nil; hosts = []; loadedOnce = false; selected = nil; hostsError = nil
        if !settings.hostHub { stopNet(forget: true) }
        FileLog.shared.log("fleet: left the fleet")
    }

    // MARK: Hosting the hub

    var isLocalHub: Bool { identity?.hubURL.hasPrefix("http://127.0.0.1:") ?? false }

    /// The address other Macs use to reach this Mac's hub: its private-network address when there is one, else its name on the LAN.
    var shareAddress: String {
        if case .ready(_, let address) = net { return "http://\(address):\(settings.hubPort)" }
        var name = ProcessInfo.processInfo.hostName
        if name.hasSuffix(".local") { name.removeLast(6) }
        return "http://\(name).local:\(settings.hubPort)"
    }

    func setHosting(_ on: Bool) {
        if on, let id = identity, !isLocalHub, !id.hostToken.isEmpty {
            hubError = "This Mac reports to another hub. Leave that fleet first."
            return
        }
        settings.hostHub = on
        if on { startHub() } else { stopHub() }
    }

    private func startHub() {
        guard hubProcess == nil, !hubRunning else { return }
        let port = settings.hubPort
        let local = HubClient(baseURL: "http://127.0.0.1:\(port)", transport: URLSessionTransport(timeout: 2))
        guard let binary = helper("utmwatch-hub") else {
            hubError = "The hub program is missing from this copy of UTM Watch."
            return
        }
        hubError = nil
        let database = hubDatabase
        work.async { [weak self] in
            // A hub left running by an earlier copy of the app is adopted rather than fought over the port.
            var process: Process?
            if case .failure = local.health() {
                let p = Process()
                p.executableURL = binary
                // All interfaces: the other Macs must be able to reach it. Only enrolled Macs get anything from it.
                p.arguments = ["serve", "--db", database, "--host", "0.0.0.0", "--port", "\(port)"]
                p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
                p.terminationHandler = { ended in DispatchQueue.main.async { self?.hubEnded(ended) } }
                do { try p.run() } catch {
                    DispatchQueue.main.async { self?.hubError = "The hub could not start: \(error.localizedDescription)" }
                    return
                }
                process = p
                DispatchQueue.main.sync { self?.hubProcess = p }
                var up = false
                for _ in 0..<40 where !up {
                    Thread.sleep(forTimeInterval: 0.25)
                    if case .success = local.health() { up = true }
                }
                guard up else {
                    p.terminate()
                    DispatchQueue.main.async { self?.hubError = "The hub did not start. Another program may be using port \(port)." }
                    return
                }
            }
            guard let store = try? HubStore(path: database) else {
                process?.terminate()
                DispatchQueue.main.async { self?.hubError = "The hub's database could not be opened." }
                return
            }
            // The hub Mac is part of its own fleet: it enrols itself the first time.
            var id = DispatchQueue.main.sync { self?.identity }
            if id == nil || id?.hostToken.isEmpty == true || id?.hubURL != local.baseURL {
                let uuid = id.flatMap { $0.hostUUID.isEmpty ? nil : $0.hostUUID } ?? UUID().uuidString.lowercased()
                let name = id.flatMap { $0.name.isEmpty ? nil : $0.name } ?? FleetController.defaultName
                let version = DispatchQueue.main.sync { self?.version ?? "dev" }
                let code = store.createEnrollToken(now: Date().msSince1970, ttlMs: 60_000)
                if case .success(let reply) = local.enroll(code: code, request: EnrollRequest(hostUUID: uuid, name: name, appVersion: version)) {
                    let new = HostIdentity(hostUUID: uuid, name: name, hubURL: local.baseURL, hostToken: reply.hostToken, readerToken: reply.readerToken)
                    try? new.save()
                    id = new
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.hubStore = store
                self.hubRunning = true
                self.identity = id
                self.syncUploader()
                self.refreshEnrolled()
                self.pollHosts()
                // The private network helper has to forward the hub's port; restart it now that the hub is up.
                if self.hubConfig.authKey != nil || FileManager.default.fileExists(atPath: self.netDirectory) { self.startNet(key: nil) }
                FileLog.shared.log("fleet: hosting the hub on port \(port)")
            }
        }
    }

    private func hubEnded(_ process: Process) {
        guard hubProcess === process else { return }
        hubProcess = nil; hubRunning = false; hubStore = nil
        guard settings.hostHub else { return }
        hubError = "The hub stopped unexpectedly. Starting it again."
        FileLog.shared.log("fleet: hub exited with status \(process.terminationStatus); restarting")
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.settings.hostHub else { return }
            self.startHub()
        }
    }

    private func stopHub() {
        let p = hubProcess
        hubProcess = nil; hubRunning = false; hubStore = nil; enrolled = []; pairingCode = nil
        p?.terminate()
        FileLog.shared.log("fleet: hub stopped")
    }

    /// A code that adds one Mac: it works once and for fifteen minutes.
    func newPairingCode() {
        guard let store = hubStore else { return }
        let token = store.createEnrollToken(now: Date().msSince1970, ttlMs: 15 * 60_000)
        var key: String?
        if case .ready = net { key = hubConfig.authKey }
        pairingCode = PairingCode(hub: shareAddress, token: token, authKey: key).text
    }

    func refreshEnrolled() {
        guard let store = hubStore else { return }
        work.async { [weak self] in
            let list = store.hosts(now: Date().msSince1970)
            DispatchQueue.main.async { self?.enrolled = list }
        }
    }

    func revoke(_ uuid: String) {
        guard let store = hubStore, uuid != identity?.hostUUID else { return }
        work.async { [weak self] in
            store.revoke(hostUUID: uuid)
            DispatchQueue.main.async { self?.refreshEnrolled(); self?.pollHosts() }
        }
    }

    // MARK: Private network

    var hasAuthKey: Bool { hubConfig.authKey != nil }

    /// Lets Macs on other networks reach this hub: the hub Mac joins the owner's Tailscale network with this key,
    /// and pairing codes made afterwards carry it so the other Macs join silently.
    func connectOtherNetworks(authKey: String) {
        let key = authKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        hubConfig = HubConfig(authKey: key)
        pairingCode = nil
        startNet(key: key)
    }

    func disconnectOtherNetworks() {
        hubConfig = HubConfig(authKey: nil)
        pairingCode = nil
        stopNet(forget: true)
    }

    private func startNet(key: String?) {
        guard let binary = helper("utmwatch-net") else {
            net = .failed("The network helper is missing from this copy of UTM Watch.")
            return
        }
        stopNet(forget: false)
        net = .starting
        let p = Process()
        p.executableURL = binary
        var args = ["-dir", netDirectory, "-proxy", "127.0.0.1:0"]
        if settings.hostHub { args += ["-forward", "\(settings.hubPort)=127.0.0.1:\(settings.hubPort)"] }
        p.arguments = args
        // The key goes in through the environment, never the command line, where any process could read it.
        // Tailscale settings in this process's environment belong to the user's own Tailscale, not the fleet's node.
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("TS_") && !$0.key.hasPrefix("TAILSCALE_") }
        env["TS_AUTHKEY"] = key ?? hubConfig.authKey
        p.environment = env
        let out = Pipe()
        p.standardOutput = out; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { self?.netOutput(data, from: p) }
        }
        p.terminationHandler = { [weak self] ended in
            DispatchQueue.main.async {
                guard let self, self.netProcess === ended else { return }
                self.netProcess = nil
                if case .ready = self.net { self.net = .failed("The connection to the fleet's network stopped.") }
                else if self.net == .starting { self.net = .failed("The connection to the fleet's network could not start.") }
                self.syncUploader()
            }
        }
        do { try p.run() } catch {
            net = .failed("The network helper could not start: \(error.localizedDescription)")
            return
        }
        netProcess = p
        netBuffer = Data()
    }

    /// The helper reports one JSON object per line.
    private func netOutput(_ data: Data, from process: Process) {
        guard netProcess === process else { return }
        netBuffer.append(data)
        while let newline = netBuffer.firstIndex(of: 0x0A) {
            let line = netBuffer.subdata(in: netBuffer.startIndex..<newline)
            netBuffer.removeSubrange(netBuffer.startIndex...newline)
            guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], let event = obj["event"] as? String else { continue }
            switch event {
            case "ready":
                let ips = obj["ips"] as? [String] ?? []
                guard let proxy = obj["proxy"] as? String, let address = ips.first(where: { $0.contains(".") }) ?? ips.first else { continue }
                net = .ready(proxy: proxy, address: address)
                try? proxy.write(toFile: HostIdentity.proxyNotePath, atomically: true, encoding: .utf8)
                FileLog.shared.log("fleet: joined the private network as \(address)")
                syncUploader()
                if viewActive { pollHosts() }
            case "needs-login":
                net = .needsKey
                process.terminate()
            case "error":
                net = .failed(obj["error"] as? String ?? "The connection to the fleet's network failed.")
            default: break
            }
        }
    }

    private func stopNet(forget: Bool) {
        let p = netProcess
        netProcess = nil
        p?.terminate()
        net = .off
        try? FileManager.default.removeItem(atPath: HostIdentity.proxyNotePath)
        if forget { try? FileManager.default.removeItem(atPath: netDirectory) }
    }

    // MARK: The fleet view

    var canView: Bool { identity?.readerToken?.isEmpty == false }

    func select(_ uuid: String?) {
        selected = uuid
        remoteDetail.isActive = false
        remoteDetail.reset()
        guard let uuid, let host = hosts.first(where: { $0.uuid == uuid }) else { remoteDetail.remoteLoad = nil; return }
        mirror.snapshot = host.snapshot; mirror.link = host.link
        remoteDetail.remoteLoad = { [weak self] from, to, maxPoints, done in
            guard let self, let id = self.identity, let token = id.readerToken, let client = self.client(for: id) else { done(nil); return }
            self.work.async {
                var result = client.history(hostUUID: uuid, from: from, to: to, maxPoints: maxPoints, token: token)
                if result == .failure(.unreachable) { result = client.history(hostUUID: uuid, from: from, to: to, maxPoints: maxPoints, token: token) }
                DispatchQueue.main.async { if case .success(let h) = result { done(h) } else { done(nil) } }
            }
        }
        remoteDetail.isActive = true
    }

    func pollHosts() {
        guard let id = identity, let token = id.readerToken, !token.isEmpty else { return }
        guard let client = client(for: id) else {
            hostsError = "Connecting to the fleet's network…"
            return
        }
        work.async { [weak self] in
            let result = client.hosts(token: token)
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let list):
                    self.hosts = list; self.hostsError = nil; self.loadedOnce = true; self.updatedAt = Date()
                    if let uuid = self.selected {
                        if let host = list.first(where: { $0.uuid == uuid }) {
                            self.mirror.snapshot = host.snapshot; self.mirror.link = host.link
                            self.remoteDetail.refresh(force: false)
                        } else { self.select(nil) }
                    }
                case .failure(.unreachable):
                    self.hostsError = "The hub did not answer. Showing what it last said."
                case .failure(.rejected(let status, let message)):
                    self.hostsError = status == 401 ? "The hub no longer accepts this Mac. Enter a new pairing code in Settings." : message
                }
            }
        }
    }

    // MARK: Alerts

    /// Trouble on another Mac worth interrupting for. This Mac's own trouble shows in its menu bar item as before.
    private static let alertKinds: Set<String> = HistoryEvent.warningKinds.subtracting(["sleep"]).union(["host_offline"])

    private func pollEvents() {
        guard settings.fleetAlerts, let id = identity, let token = id.readerToken, !token.isEmpty, let client = client(for: id) else { return }
        let after = lastEventID
        let since = startedAt
        work.async { [weak self] in
            // Until the first event is seen there is no id to continue from, so ask by time: nothing older than this launch.
            guard case .success(let events) = client.events(after: after > 0 ? after : nil, from: after > 0 ? nil : since, token: token) else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                for e in events where e.id > self.lastEventID {
                    self.lastEventID = e.id
                    if e.hostUUID != self.identity?.hostUUID, FleetController.alertKinds.contains(e.kind) { self.notify(title: e.hostName, body: e.label) }
                }
            }
        }
    }

    private func notify(title: String, body: String) {
        // Notifications need a bundle; a bare development binary has none.
        guard Bundle.main.bundleIdentifier != nil else { FileLog.shared.log("fleet alert: \(title): \(body)"); return }
        let center = UNUserNotificationCenter.current()
        let post = {
            let content = UNMutableNotificationContent()
            content.title = title; content.body = body
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
        if askedForNotifications { post(); return }
        askedForNotifications = true
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in if granted { post() } }
    }
}
