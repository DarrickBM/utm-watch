import Foundation
import UTMWatchCore
import UTMWatchStore

/// The last hour of samples, kept in memory so the live view never waits on disk. Main thread only.
final class LiveRing {
    static let keepMs: Int64 = 61 * 60 * 1000

    private(set) var series: [String: [VMPoint]] = [:]
    private(set) var host: [HostPoint] = []
    private(set) var events: [HistoryEvent] = []
    private(set) var configs: [String: [VMConfig]] = [:]
    private(set) var infos: [String: VMInfo] = [:]
    private(set) var probes: [String: [ProbePoint]] = [:]
    private(set) var link: [LinkPoint] = []
    /// Every VM key ever seen, in first-seen order. Series colors follow this order.
    private(set) var order: [String] = []

    /// Seeds the ring from disk at launch so the live view has context immediately.
    func prefill(_ h: History, knownVMs: [VMInfo]) {
        series = h.series; host = h.host; events = h.events; configs = h.configs; probes = h.probes; link = h.link
        for vm in knownVMs { infos[vm.key] = vm; if !order.contains(vm.key) { order.append(vm.key) } }
    }

    func rename(_ key: String, to name: String) { infos[key]?.name = name }

    func append(_ s: Snapshot, events new: [HistoryEvent]) {
        let ts = s.timestamp.msSince1970
        for row in s.rows where row.pid != nil {
            infos[row.id] = VMInfo(key: row.id, name: row.name, backend: row.backend.rawValue)
            if !order.contains(row.id) { order.append(row.id) }
            let cfg = VMConfig(ts: ts, cores: row.cpuAllocated, memBytes: row.memoryAllocatedBytes.map { Double($0) })
            if cfg.cores != nil || cfg.memBytes != nil {
                let last = configs[row.id]?.last
                if last?.cores != cfg.cores || last?.memBytes != cfg.memBytes { configs[row.id, default: []].append(cfg) }
            }
            series[row.id, default: []].append(VMPoint(row: row, ts: ts))
        }
        host.append(HostPoint(snapshot: s))
        events.append(contentsOf: new)

        let cutoff = ts - LiveRing.keepMs
        for key in series.keys {
            if let n = series[key]?.firstIndex(where: { $0.t >= cutoff }), n > 0 { series[key]?.removeFirst(n) }
            if series[key]?.isEmpty == true { series[key] = nil }
        }
        if let n = host.firstIndex(where: { $0.t >= cutoff }), n > 0 { host.removeFirst(n) }
        events.removeAll { $0.ts < cutoff }
    }

    func append(_ p: ProbeResult) {
        let ts = p.timestamp.msSince1970
        for (key, rtt) in p.vmPing { probes[ProbeTarget.vm(key), default: []].append(ProbePoint(t: ts, rtt: rtt, lost: rtt == nil ? 1 : 0)) }
        if p.gatewayTried { probes[ProbeTarget.gateway, default: []].append(ProbePoint(t: ts, rtt: p.gatewayMs, lost: p.gatewayMs == nil ? 1 : 0)) }
        if p.internetTried { probes[ProbeTarget.internet, default: []].append(ProbePoint(t: ts, rtt: p.internetMs, lost: p.internetMs == nil ? 1 : 0)) }
        link.append(LinkPoint(p.link, ts: ts))
        let cutoff = ts - LiveRing.keepMs
        for key in probes.keys {
            if let n = probes[key]?.firstIndex(where: { $0.t >= cutoff }), n > 0 { probes[key]?.removeFirst(n) }
        }
        if let n = link.firstIndex(where: { $0.t >= cutoff }), n > 0 { link.removeFirst(n) }
    }

    func addEvents(_ new: [HistoryEvent]) { events.append(contentsOf: new) }

    func history(from: Int64, to: Int64, bucketMs: Double) -> History {
        var h = History(from: from, to: to)
        h.bucketMs = bucketMs
        for (key, points) in series {
            let slice = points.filter { $0.t >= from && $0.t <= to }
            if !slice.isEmpty { h.series[key] = slice }
        }
        h.vms = order.filter { h.series[$0] != nil }.compactMap { infos[$0] }
        h.host = host.filter { $0.t >= from && $0.t <= to }
        h.events = events.filter { $0.ts >= from && $0.ts <= to }
        h.configs = configs
        for (key, points) in probes {
            let slice = points.filter { $0.t >= from && $0.t <= to }
            if !slice.isEmpty { h.probes[key] = slice }
        }
        h.link = link.filter { $0.t >= from && $0.t <= to }
        return h
    }

    func clear() {
        series = [:]; host = []; events = []; configs = [:]; probes = [:]; link = []
    }
}

/// Buffers snapshots and writes them to the store in one transaction every few seconds.
final class Recorder {
    let store: HistoryStore
    private var pending: [Snapshot] = []
    private var pendingEvents: [HistoryEvent] = []
    private var pendingProbes: [ProbeResult] = []
    private var timer: Timer?
    private let io = DispatchQueue(label: "utmwatch.recorder", qos: .utility)

    init(store: HistoryStore, flushEvery seconds: TimeInterval = 10) {
        self.store = store
        let t = Timer(timeInterval: seconds, repeats: true) { [weak self] _ in self?.flush() }
        t.tolerance = 2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func add(_ snapshot: Snapshot, events: [HistoryEvent]) {
        pending.append(snapshot)
        pendingEvents.append(contentsOf: events)
    }

    func add(_ probe: ProbeResult) { pendingProbes.append(probe) }
    func add(events: [HistoryEvent]) { pendingEvents.append(contentsOf: events) }

    /// Hands the buffered batch to the store. `wait: true` blocks until it is on disk (used at quit).
    func flush(wait: Bool = false) {
        let batch = pending, events = pendingEvents, probes = pendingProbes
        pending = []; pendingEvents = []; pendingProbes = []
        guard !batch.isEmpty || !events.isEmpty || !probes.isEmpty else { return }
        let work = { [store] in store.write(snapshots: batch, events: events, probes: probes) }
        if wait { io.sync(execute: work) } else { io.async(execute: work) }
    }

    func discardPending() { pending = []; pendingEvents = []; pendingProbes = [] }
}
