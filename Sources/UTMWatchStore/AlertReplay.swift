import Foundation
import UTMWatchModel

/// Runs a rule over recorded history to say how often it would have alerted, before it goes live.
public enum AlertReplay {
    /// History turned into the engine's inputs once, so trying another threshold only re-runs the engine.
    public struct Timeline {
        public var from: Int64
        public var to: Int64
        public var samples: [AlertSample] = []
        public var probes: [AlertProbe] = []
        public var baselines: [String: AlertBaseline] = [:]
        public var names: [String: String] = [:]
        public var isEmpty: Bool { samples.isEmpty && probes.isEmpty }
    }

    public struct Interval: Equatable {
        public var subject: String
        public var from: Int64
        /// When it ended; the end of the history for one still open there.
        public var to: Int64
        public var title: String
    }

    public struct Bar: Equatable {
        /// 0...1, the reading at its worst in this slice of time; nil when nothing was recorded.
        public var height: Double?
        public var firing: Bool
    }

    public struct Result: Equatable {
        public var intervals: [Interval] = []
        public var bars: [Bar] = []
        /// Where the threshold sits on the bars' 0...1 scale; nil for rules without a number.
        public var threshold: Double?
        /// False when the history holds nothing this rule could be checked against.
        public var hasData = false
        public var count: Int { intervals.count }
    }

    /// What was usual for each VM over the history: the level it stayed under 99% of the time.
    public static func baselines(_ h: History) -> [String: AlertBaseline] {
        func p99(_ values: [Double]) -> Double {
            guard !values.isEmpty else { return 0 }
            let sorted = values.sorted()
            return sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.99))]
        }
        var out: [String: AlertBaseline] = [:]
        for (key, points) in h.series {
            let minutes = Int(Double(points.count) * h.bucketMs / 60_000)
            out[key] = AlertBaseline(cpu: p99(points.compactMap(\.cpu)), mem: p99(points.compactMap(\.mem)),
                                     net: p99(points.compactMap { p in p.down == nil && p.up == nil ? nil : (p.down ?? 0) + (p.up ?? 0) }), minutes: minutes)
        }
        return out
    }

    public static func timeline(_ h: History) -> Timeline {
        var tl = Timeline(from: h.from, to: h.to)
        tl.baselines = baselines(h)
        for vm in h.vms { tl.names[vm.key] = vm.name }
        let width = max(1, Int64(h.bucketMs))
        func slot(_ t: Int64) -> Int64 { (t - h.from) / width }
        let keys = h.series.keys.filter { !$0.hasPrefix("pid:") }.sorted()
        var bySlot: [String: [Int64: VMPoint]] = [:]
        for key in keys { bySlot[key] = Dictionary(h.series[key, default: []].map { (slot($0.t), $0) }, uniquingKeysWith: { a, _ in a }) }
        for hp in h.host {
            let i = slot(hp.t)
            let vms: [AlertSample.VM] = keys.map { key in
                let name = tl.names[key] ?? key
                guard let p = bySlot[key]?[i] else { return AlertSample.VM(key: key, name: name, running: false) }
                return AlertSample.VM(key: key, name: name, running: true, cpu: p.cpu, cores: h.config(for: key, at: p.t)?.cores, mem: p.mem,
                                      net: p.down == nil && p.up == nil ? nil : (p.down ?? 0) + (p.up ?? 0), diskUsed: p.diskUsed, diskSize: p.diskSize)
            }
            var sample = AlertSample(t: hp.t, vms: vms, pressure: hp.pressure, diskFree: hp.diskFree, diskTotal: hp.diskTotal, averaged: true)
            sample.memUsed = hp.used; sample.swapUsed = hp.swapUsed; sample.swapTotal = hp.swapTotal
            tl.samples.append(sample)
        }
        var probeSlots: [Int64: AlertProbe] = [:]
        for l in h.link { probeSlots[slot(l.t)] = AlertProbe(t: l.t, linkKind: l.kind, rssi: l.rssi) }
        for (target, points) in h.probes {
            for p in points {
                let i = slot(p.t)
                var probe = probeSlots[i] ?? AlertProbe(t: p.t, linkKind: "unknown")
                let c = AlertProbe.Count(sent: p.sent, lost: p.lost)
                if target == ProbeTarget.gateway { probe.gateway = c }
                else if target == ProbeTarget.internet { probe.internet = c }
                else if target.hasPrefix("vm:") { probe.vmPing[String(target.dropFirst(3))] = c }
                probeSlots[i] = probe
            }
        }
        tl.probes = probeSlots.keys.sorted().compactMap { probeSlots[$0] }
        return tl
    }

    public static func run(_ rule: AlertRule, over tl: Timeline, bars count: Int = 84) -> Result {
        var result = Result()
        var live = rule
        live.enabled = true
        var engine = AlertEngine(rules: [live])
        engine.baselines = tl.baselines
        var openAt: [String: Interval] = [:]
        func apply(_ changes: [AlertChange]) {
            for c in changes {
                switch c {
                case .opened(let a): openAt[a.key] = Interval(subject: a.subject, from: a.opened, to: tl.to, title: a.title)
                case .updated: break
                case .closed(let key, let at):
                    if var i = openAt.removeValue(forKey: key) { i.to = max(i.from, at); result.intervals.append(i) }
                }
            }
        }
        // Samples and probes each keep their own clock in the engine; feed them in time order.
        var si = 0, pi = 0
        while si < tl.samples.count || pi < tl.probes.count {
            let st = si < tl.samples.count ? tl.samples[si].t : Int64.max
            let pt = pi < tl.probes.count ? tl.probes[pi].t : Int64.max
            if st <= pt { apply(engine.ingest(tl.samples[si])); si += 1 } else { apply(engine.ingest(tl.probes[pi])); pi += 1 }
        }
        result.intervals.append(contentsOf: openAt.values)
        result.intervals.sort { $0.from < $1.from }

        // The bars: the reading at its worst in each slice, on a 0...1 scale that also places the threshold.
        let span = max(1, tl.to - tl.from)
        var worst = [Double?](repeating: nil, count: count)
        let higher = rule.kind.spec.higherIsWorse
        func put(_ t: Int64, _ v: Double?) {
            guard let v, t >= tl.from, t <= tl.to else { return }
            let i = min(count - 1, Int(Double(t - tl.from) / Double(span) * Double(count)))
            worst[i] = worst[i].map { higher ? max($0, v) : min($0, v) } ?? v
        }
        let total = tl.samples.compactMap(\.diskTotal).max()
        let mostRunning = max(1, tl.samples.map { $0.vms.filter(\.running).count }.max() ?? 1)
        switch rule.kind {
        case .cpu:
            for s in tl.samples { put(s.t, s.vms.compactMap { vm in vm.cpu.flatMap { c in vm.cores.flatMap { $0 > 0 ? min(1, c / Double($0)) : nil } } }.max()) }
            result.threshold = rule.value.map { $0 / 100 }
        case .vmDisk, .vmDiskFull:
            for s in tl.samples { put(s.t, s.vms.compactMap { vm in vm.diskUsed.flatMap { u in vm.diskSize.flatMap { $0 > 0 ? min(1, u / $0) : nil } } }.max()) }
            result.threshold = rule.value.map { $0 / 100 }
        case .macDisk, .macDiskFull:
            for s in tl.samples { if let free = s.diskFree, let total, total > 0 { put(s.t, free / total) } }
            if let total, total > 0 { result.threshold = rule.value.map { min(1, $0 * 1_073_741_824 / total) } }
        case .memory, .memoryCritical:
            for s in tl.samples { put(s.t, Double(s.pressure) / 2) }
        case .unusual:
            for s in tl.samples {
                put(s.t, s.vms.compactMap { vm -> Double? in
                    guard let b = tl.baselines[vm.key], b.cpu > 0, let c = vm.cpu else { return nil }
                    return min(1, c / b.cpu / 2)
                }.max())
            }
        case .vmStopped:
            for s in tl.samples { put(s.t, Double(s.vms.filter(\.running).count) / Double(mostRunning)) }
        case .wifi:
            for p in tl.probes { if p.linkKind == "wifi", let r = p.rssi { put(p.t, min(1, max(0, (r + 100) / 70))) } }
            result.threshold = rule.value.map { min(1, max(0, ($0 + 100) / 70)) }
        case .vmFrozen:
            for p in tl.probes {
                let sent = p.vmPing.values.reduce(0) { $0 + $1.sent }, lost = p.vmPing.values.reduce(0) { $0 + $1.lost }
                if sent > 0 { put(p.t, Double(lost) / Double(sent)) }
            }
        case .networkDown, .poorConnection:
            for p in tl.probes {
                let each = [p.gateway, p.internet].compactMap { $0 }.filter { $0.sent > 0 }.map { Double($0.lost) / Double($0.sent) }
                put(p.t, p.linkKind == "none" ? 1 : each.max())
            }
            if rule.kind == .poorConnection { result.threshold = rule.value.map { $0 / 100 } }
        }
        result.hasData = worst.contains { $0 != nil }
        result.bars = worst.enumerated().map { i, v in
            let from = tl.from + Int64(Double(span) * Double(i) / Double(count)), to = tl.from + Int64(Double(span) * Double(i + 1) / Double(count))
            return Bar(height: v, firing: result.intervals.contains { $0.from < to && $0.to >= from })
        }
        return result
    }
}
