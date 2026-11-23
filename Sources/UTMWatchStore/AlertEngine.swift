import Foundation
import UTMWatchModel

/// One problem, from the moment it began until it is over.
public struct Alert: Equatable, Codable, Identifiable {
    /// The store's row id; 0 for an alert that has not been stored.
    public var id: Int64 = 0
    /// The rule that raised it (`AlertKind` raw value).
    public var rule: String
    public var level: AlertLevel
    /// What it is about: a VM key, or "host" for the Mac itself.
    public var subject: String
    public var vmKey: String?
    public var title: String
    /// What is wrong, in a sentence or two.
    public var what: String
    /// What to do about it.
    public var todo: String
    /// When the problem began, in milliseconds since 1970.
    public var opened: Int64
    public var closed: Int64?
    /// What an AI agent found when it looked into it.
    public var finding: String?
    public var findingAt: Int64?

    public var key: String { Alert.key(rule: rule, subject: subject) }
    public static func key(rule: String, subject: String) -> String { rule + "|" + subject }
    public static let host = "host"

    public init(rule: String, level: AlertLevel, subject: String, vmKey: String?, title: String, what: String, todo: String, opened: Int64) {
        self.rule = rule; self.level = level; self.subject = subject; self.vmKey = vmKey
        self.title = title; self.what = what; self.todo = todo; self.opened = opened
    }
}

public enum AlertChange: Equatable {
    case opened(Alert)
    /// The alert is still open and its wording changed (a disk went from 92% to 94% full).
    case updated(Alert)
    case closed(key: String, at: Int64)
}

/// One moment of VM and host readings, as the engine wants them.
public struct AlertSample {
    public struct VM {
        public var key: String
        public var name: String
        public var running: Bool
        public var cpu: Double?        // cores
        public var cores: Int?
        public var mem: Double?        // bytes
        public var net: Double?        // bytes per second, both directions
        public var diskUsed: Double?
        public var diskSize: Double?
        public init(key: String, name: String, running: Bool, cpu: Double? = nil, cores: Int? = nil, mem: Double? = nil, net: Double? = nil,
                    diskUsed: Double? = nil, diskSize: Double? = nil) {
            self.key = key; self.name = name; self.running = running; self.cpu = cpu; self.cores = cores; self.mem = mem; self.net = net
            self.diskUsed = diskUsed; self.diskSize = diskSize
        }
    }
    public var t: Int64
    public var vms: [VM]
    /// 0 normal, 1 warning, 2 critical.
    public var pressure: Int
    public var diskFree: Double?
    public var diskTotal: Double?
    /// The Mac's memory in use and its size, and its swap space in use and its size, in bytes; nil when not known.
    public var memUsed: Double?
    public var memTotal: Double?
    public var swapUsed: Double?
    public var swapTotal: Double?
    /// True when the readings are already averages over a minute (replayed history), so the engine does not average again.
    public var averaged = false

    public init(t: Int64, vms: [VM], pressure: Int, diskFree: Double? = nil, diskTotal: Double? = nil, averaged: Bool = false) {
        self.t = t; self.vms = vms; self.pressure = pressure; self.diskFree = diskFree; self.diskTotal = diskTotal; self.averaged = averaged
    }

    /// VMs that belong to other apps have no identity that outlives their process, so alerts leave them out.
    public init(_ s: Snapshot) {
        t = s.timestamp.msSince1970
        vms = s.rows.filter { !$0.id.hasPrefix("pid:") }.map { r in
            VM(key: r.id, name: r.name, running: r.pid != nil, cpu: r.cpuCores, cores: r.cpuAllocated, mem: r.memoryBytes.map { Double($0) },
               net: r.downRate == nil && r.upRate == nil ? nil : (r.downRate ?? 0) + (r.upRate ?? 0),
               diskUsed: r.diskUsedBytes.map { Double($0) }, diskSize: r.diskSizeBytes.map { Double($0) })
        }
        pressure = HostPoint.code(s.host.pressure)
        diskFree = s.host.diskFreeBytes.map { Double($0) }
        diskTotal = s.host.diskTotalBytes.map { Double($0) }
        memUsed = Double(s.host.hostUsed)
        memTotal = s.host.totalMemory > 0 ? Double(s.host.totalMemory) : nil
        swapUsed = Double(s.host.swapUsed)
        swapTotal = Double(s.host.swapTotal)
    }
}

/// One round of network probes (or a minute of them), as the engine wants them.
public struct AlertProbe {
    public struct Count: Equatable {
        public var sent: Int
        public var lost: Int
        public init(sent: Int, lost: Int) { self.sent = sent; self.lost = lost }
    }
    public var t: Int64
    public var linkKind: String
    public var rssi: Double?
    public var vmPing: [String: Count]
    public var gateway: Count?
    public var internet: Count?
    /// Checks of the Mac's route back to each VM: lost when it did not lead to the VM's bridge.
    public var vmRoute: [String: Count] = [:]
    /// What the live checks saw, for the wording; replayed history has only the counts.
    public var vmRouteSeen: [String: VMRoute] = [:]

    public init(t: Int64, linkKind: String, rssi: Double? = nil, vmPing: [String: Count] = [:], gateway: Count? = nil, internet: Count? = nil,
                vmRoute: [String: Count] = [:]) {
        self.t = t; self.linkKind = linkKind; self.rssi = rssi; self.vmPing = vmPing; self.gateway = gateway; self.internet = internet
        self.vmRoute = vmRoute
    }

    public init(_ p: ProbeResult) {
        t = p.timestamp.msSince1970
        linkKind = p.link.kind
        rssi = p.link.rssi.map { Double($0) }
        vmPing = p.vmPing.mapValues { Count(sent: 1, lost: $0 == nil ? 1 : 0) }
        gateway = p.gatewayTried ? Count(sent: 1, lost: p.gatewayMs == nil ? 1 : 0) : nil
        internet = p.internetTried ? Count(sent: 1, lost: p.internetMs == nil ? 1 : 0) : nil
        vmRoute = p.vmRoute.mapValues { Count(sent: 1, lost: $0.ok ? 0 : 1) }
        vmRouteSeen = p.vmRoute
    }
}

/// What is usual for one VM: levels it stayed under 99% of the time in its recent history.
public struct AlertBaseline: Equatable {
    public var cpu: Double
    public var mem: Double
    public var net: Double
    /// Minutes of history behind it. Too few, and nothing is called unusual.
    public var minutes: Int
    public init(cpu: Double, mem: Double, net: Double, minutes: Int) { self.cpu = cpu; self.mem = mem; self.net = net; self.minutes = minutes }
}

/// Turns readings into alerts. An alert opens once the rule's condition has lasted its time, stays open while the
/// problem lasts, and closes by itself once things have been normal for as long as it took to open.
/// Pure state machine, no I/O: the live app and the 7-day replay run the same code.
public struct AlertEngine {
    public var rules: [AlertRule]
    /// Alerts the user silenced, by alert key, until a time.
    public var muted: [String: Int64] = [:]
    public var baselines: [String: AlertBaseline] = [:]
    public private(set) var open: [String: Alert] = [:]

    private struct Track {
        var badSince: Int64?
        var goodSince: Int64?
        /// The user said the problem is theirs (they stopped the VM); stay quiet until it is over.
        var acknowledged = false
        var refreshedAt: Int64 = 0
        var note = ""
    }
    private var tracks: [String: Track] = [:]
    private var recent: [String: [(t: Int64, v: Double)]] = [:]     // short windows for one-minute averages
    private var trend: [String: [(t: Int64, v: Double)]] = [:]      // hours of disk readings for the forecast
    private var everRan: [String: String] = [:]                      // VM key -> name, once seen running
    private var runningNow: Set<String> = []
    private var answered: Set<String> = []                           // running VMs that have answered a ping
    private var absentSince: [String: Int64] = [:]                   // VMs that ran once and are no longer listed at all
    /// One probe round of the router and internet pings. `dead` when neither answered (or there was no network at all).
    private struct Round {
        var t: Int64
        var gateway: AlertProbe.Count?
        var internet: AlertProbe.Count?
        var dead: Bool
    }
    private var pings: [Round] = []
    private var routerAnswered = false                               // some routers never answer pings
    private var lastSample: Int64?
    private var lastProbe: Int64?
    private var lastDiskFree: Double?
    private var lastPressure = 0

    public static let gapMs: Int64 = 150_000
    static let trendKeepMs: Int64 = 6 * 3600_000
    static let trendMinMs: Int64 = 3600_000
    /// A VM needs this much history before anything about it is called unusual.
    public static let baselineMinutes = 1440

    public init(rules: [AlertRule] = AlertRule.defaults) { self.rules = rules }

    /// Alerts that were open when the app last quit, so they carry on instead of opening a second time.
    public mutating func restore(_ alerts: [Alert]) {
        for a in alerts where a.closed == nil {
            open[a.key] = a
            var track = Track(badSince: a.opened)
            if a.rule == AlertKind.vmStopped.rawValue {
                everRan[a.subject] = a.title.replacingOccurrences(of: " stopped", with: "")
                track.note = a.what // what was wrong when it stopped is not known again later
            }
            tracks[a.key] = track
        }
    }

    /// Gives the store's row id to an alert the engine opened.
    public mutating func setID(_ id: Int64, for key: String) { open[key]?.id = id }

    public mutating func setFinding(_ text: String, at t: Int64, for key: String) {
        open[key]?.finding = text
        open[key]?.findingAt = t
    }

    /// Closes an alert because the user says the situation is theirs. It stays quiet until the condition has cleared.
    public mutating func acknowledge(_ key: String, at t: Int64) -> [AlertChange] {
        guard open[key] != nil else { return [] }
        open[key] = nil
        tracks[key, default: Track()].acknowledged = true
        return [.closed(key: key, at: t)]
    }

    /// Silences one alert until `until`; it closes now and may open again afterwards.
    public mutating func mute(_ key: String, until: Int64, at t: Int64) -> [AlertChange] {
        muted[key] = until
        tracks[key] = nil
        guard open[key] != nil else { return [] }
        open[key] = nil
        return [.closed(key: key, at: t)]
    }

    /// Disk readings from recorded history, so a forecast does not have to wait hours after a launch.
    /// Safe to call after live readings have begun: the history goes in front of what is already there.
    public mutating func seedTrend(_ h: History) {
        func seed(_ key: String, _ points: [(t: Int64, v: Double)]) {
            let live = trend[key] ?? []
            var older: [String: [(t: Int64, v: Double)]] = [:]
            for p in points where p.t < (live.first?.t ?? Int64.max) { AlertEngine.record(&older, key, p.t, p.v, every: 60_000, keep: AlertEngine.trendKeepMs) }
            let merged = (older[key] ?? []) + live
            guard let newest = merged.last else { return }
            trend[key] = merged.filter { $0.t >= newest.t - AlertEngine.trendKeepMs }
        }
        for (key, points) in h.series { seed(key, points.compactMap { p in p.diskUsed.map { (p.t, $0) } }) }
        seed(Alert.host, h.host.compactMap { p in p.diskFree.map { (p.t, $0) } })
    }

    // MARK: Samples

    public mutating func ingest(_ s: AlertSample) -> [AlertChange] {
        var out: [AlertChange] = []
        if let last = lastSample, s.t - last > AlertEngine.gapMs { resetPending(probeRules: false) }
        lastSample = s.t
        let running = s.vms.filter(\.running)
        for vm in running { everRan[vm.key] = vm.name }
        runningNow = Set(running.map(\.key))
        lastDiskFree = s.diskFree ?? lastDiskFree
        lastPressure = s.pressure
        for vm in s.vms { if let used = vm.diskUsed { AlertEngine.record(&trend, vm.key, s.t, used, every: 60_000, keep: AlertEngine.trendKeepMs) } }
        if let free = s.diskFree { AlertEngine.record(&trend, Alert.host, s.t, free, every: 60_000, keep: AlertEngine.trendKeepMs) }
        var avg: [String: (cpu: Double?, net: Double?)] = [:]
        for vm in running {
            if s.averaged { avg[vm.key] = (vm.cpu, vm.net); continue }
            if let c = vm.cpu { AlertEngine.record(&recent, "cpu|" + vm.key, s.t, c, every: 0, keep: 60_000) }
            if let n = vm.net { AlertEngine.record(&recent, "net|" + vm.key, s.t, n, every: 0, keep: 60_000) }
            avg[vm.key] = (AlertEngine.mean(recent["cpu|" + vm.key]), AlertEngine.mean(recent["net|" + vm.key]))
        }

        for rule in rules where rule.enabled {
            let hold = Int64(rule.minutes) * 60_000
            switch rule.kind {
            case .cpu:
                for vm in running where !rule.excluded.contains(vm.key) {
                    guard let used = avg[vm.key]?.cpu, let cores = vm.cores, cores > 0, let limit = rule.value else { continue }
                    let share = used / Double(cores)
                    step(rule, vm.key, vm.key, s.t, bad: share >= limit / 100, hold: hold, clear: hold, out: &out) { _ in
                        ("\(vm.name) at its CPU limit",
                         "Using \(String(format: "%.1f", used)) of its \(cores) cores (\(Int((share * 100).rounded()))%). Work inside it is waiting for processor time.",
                         "Find what is busy inside the VM, or give it more cores in UTM if this is its normal load.")
                    }
                }
            case .vmDisk, .vmDiskFull:
                for vm in s.vms where !rule.excluded.contains(vm.key) {
                    guard let used = vm.diskUsed, let size = vm.diskSize, size > 0, let limit = rule.value else { continue }
                    let share = min(1, used / size)
                    let pair = "\(AlertEngine.gb(used)) of \(AlertEngine.gb(size)) GB used"
                    if rule.kind == .vmDiskFull {
                        step(rule, vm.key, vm.key, s.t, bad: share >= limit / 100, hold: hold, clear: max(hold, 300_000), out: &out) { _ in
                            ("\(vm.name) disk is full",
                             "\(pair) inside the VM (\(Int((share * 100).rounded()))%). A guest that runs out of disk space stops saving work and can fail to start.",
                             "Free space inside the VM, or make its disk larger in UTM.")
                        }
                    } else {
                        let eta = secondsUntilFull(vm.key, now: s.t, value: used, limit: size, rising: true)
                        let soon = eta.map { $0 <= Double(rule.minutes) * 60 } ?? false
                        let pace = eta.map { " At the pace of the last hours it is full in about \(AlertEngine.span($0))." } ?? ""
                        step(rule, vm.key, vm.key, s.t, bad: share >= limit / 100 || soon, hold: 120_000, clear: 600_000, out: &out) { _ in
                            (share >= limit / 100 ? "\(vm.name) disk \(Int((share * 100).rounded()))% full" : "\(vm.name) disk is filling up",
                             "\(pair) inside the VM.\(soon || share >= limit / 100 ? pace : "")",
                             "Free space inside the VM, or make its disk larger in UTM.")
                        }
                    }
                }
            case .macDisk, .macDiskFull:
                guard let free = s.diskFree, let limit = rule.value else { continue }
                let low = free < limit * 1_073_741_824
                let pair = "\(AlertEngine.gb(free)) GB free" + (s.diskTotal.map { " of \(AlertEngine.gb($0)) GB" } ?? "")
                if rule.kind == .macDiskFull {
                    step(rule, Alert.host, nil, s.t, bad: low, hold: hold, clear: max(hold, 300_000), out: &out) { _ in
                        ("This Mac's disk is full",
                         "\(pair). VM disk images grow as the guests write; when they cannot grow, VMs pause or fail.",
                         "Free space on this Mac now, then check that the VMs are still running.")
                    }
                } else {
                    let eta = secondsUntilFull(Alert.host, now: s.t, value: free, limit: 0, rising: false)
                    let soon = eta.map { $0 <= Double(rule.minutes) * 60 } ?? false
                    let pace = eta.map { " At the pace of the last hours it runs out in about \(AlertEngine.span($0))." } ?? ""
                    step(rule, Alert.host, nil, s.t, bad: low || soon, hold: 120_000, clear: 600_000, out: &out) { _ in
                        (low ? "This Mac's disk is running low" : "This Mac's disk is filling up",
                         "\(pair). VM disk images grow as the guests write; when they cannot grow, VMs pause or fail.\(low || soon ? pace : "")",
                         "Free space on this Mac before it runs out.")
                    }
                }
            case .memory, .memoryCritical:
                let critical = rule.kind == .memoryCritical
                // The figures behind macOS's verdict: it is about the whole Mac, which the VMs' own readings do not show.
                // Whole gigabytes for memory, so the wording does not change with every sample.
                var figures: [String] = []
                if let used = s.memUsed, used > 0 {
                    figures.append("\(Int((used / 1_073_741_824).rounded()))" + (s.memTotal.map { " of \(Int(($0 / 1_073_741_824).rounded()))" } ?? "") + " GB of this Mac's memory in use")
                }
                if let swap = s.swapUsed, let total = s.swapTotal, total > 0 {
                    figures.append("swap \(Int((swap / total * 100).rounded()))% full (\(AlertEngine.gb(swap)) of \(AlertEngine.gb(total)) GB)")
                }
                let facts = figures.isEmpty ? "" : " " + figures.joined(separator: ", ").prefix(1).uppercased() + figures.joined(separator: ", ").dropFirst() + "."
                step(rule, Alert.host, nil, s.t, bad: s.pressure >= (critical ? 2 : 1), hold: hold, clear: hold, out: &out) { _ in
                    critical
                        ? ("Memory is critically short", "Memory pressure is at Critical.\(facts) macOS is nearly out of memory and is swapping heavily; expect stalls.",
                           "Shut down a VM or quit large apps now.")
                        : ("Memory is short", "Memory pressure has stayed at Warning.\(facts) macOS is compressing and swapping to keep up, so VMs and apps may feel slow.",
                           "Close apps or shut down a VM, or give the VMs less memory.")
                }
            case .unusual:
                for vm in running where !rule.excluded.contains(vm.key) {
                    guard let b = baselines[vm.key], b.minutes >= AlertEngine.baselineMinutes else { continue }
                    var odd: String?
                    if let c = avg[vm.key]?.cpu, c > max(b.cpu * 1.3, b.cpu + 0.5) {
                        odd = "CPU is at \(String(format: "%.1f", c)) cores; over the last 7 days it was almost never above \(String(format: "%.1f", b.cpu))."
                    } else if let m = vm.mem, m > b.mem * 1.15, m - b.mem > 536_870_912 {
                        odd = "Memory is at \(AlertEngine.gb(m)) GB; over the last 7 days it was almost never above \(AlertEngine.gb(b.mem)) GB."
                    } else if let n = avg[vm.key]?.net, n > max(b.net * 3, b.net + 5_000_000) {
                        odd = "Network traffic is at \(String(format: "%.1f", n / 1_000_000)) MB/s; over the last 7 days it was almost never above \(String(format: "%.1f", b.net / 1_000_000))."
                    }
                    let known = avg[vm.key]?.cpu != nil || vm.mem != nil
                    step(rule, vm.key, vm.key, s.t, bad: known ? odd != nil : nil, hold: hold, clear: hold, out: &out) { _ in
                        ("\(vm.name) is behaving unusually", odd ?? "", "Look at what changed inside the VM. Nothing is broken yet.")
                    }
                }
            case .vmStopped:
                let present = Dictionary(s.vms.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
                for (key, name) in everRan where !rule.excluded.contains(key) {
                    let isRunning = present[key]?.running ?? false
                    let shown = present[key]?.name ?? name
                    let k = Alert.key(rule: rule.id, subject: key)
                    if !isRunning, tracks[k]?.badSince == nil, open[k] == nil {
                        // What else was wrong at the moment it stopped is the best lead there is.
                        var why = ""
                        if let free = lastDiskFree, free < 10 * 1_073_741_824 { why = " This Mac's disk had \(AlertEngine.gb(free)) GB free at that moment." }
                        else if lastPressure >= 2 { why = " Memory pressure was Critical at that moment." }
                        tracks[k, default: Track()].note = "It was running and stopped at \(AlertEngine.clock(s.t)) without starting again.\(why)"
                    }
                    step(rule, key, key, s.t, bad: !isRunning, hold: hold, clear: 0, out: &out) { context in
                        ("\(shown) stopped", context.isEmpty ? "It was running and stopped without starting again." : context,
                         "Start it in UTM. If you stopped it yourself, say so and this alert goes away.")
                    }
                }
            case .wifi, .vmFrozen, .vmUnrouted, .networkDown, .poorConnection:
                break // probe rules
            }
        }

        // A VM that is not running has no CPU to be busy and nothing to answer pings; its stop is the alert that matters.
        for (key, a) in open where [AlertKind.cpu.rawValue, AlertKind.unusual.rawValue, AlertKind.vmFrozen.rawValue, AlertKind.vmUnrouted.rawValue].contains(a.rule) && !runningNow.contains(a.subject) {
            open[key] = nil; tracks[key] = nil
            out.append(.closed(key: key, at: s.t))
        }
        answered.formIntersection(runningNow)
        // A VM that is no longer listed at all (deleted, or moved away) has no disk to be full.
        let listed = Set(s.vms.map(\.key))
        for (key, a) in open where [AlertKind.vmDisk.rawValue, AlertKind.vmDiskFull.rawValue].contains(a.rule) && !listed.contains(a.subject) {
            open[key] = nil; tracks[key] = nil
            out.append(.closed(key: key, at: s.t))
        }
        // Nor can it start again. It is given a day, in case the list is only unreadable for a while, and then forgotten.
        for key in everRan.keys {
            guard !listed.contains(key) else { absentSince[key] = nil; continue }
            let since = absentSince[key] ?? s.t
            absentSince[key] = since
            guard s.t - since >= 86_400_000 else { continue }
            everRan[key] = nil; absentSince[key] = nil
            let k = Alert.key(rule: AlertKind.vmStopped.rawValue, subject: key)
            tracks[k] = nil
            if open.removeValue(forKey: k) != nil { out.append(.closed(key: k, at: s.t)) }
        }
        closeOrphans(at: s.t, probeRules: false, out: &out)
        return out
    }

    // MARK: Probes

    public mutating func ingest(_ p: AlertProbe) -> [AlertChange] {
        var out: [AlertChange] = []
        if let last = lastProbe, p.t - last > AlertEngine.gapMs { resetPending(probeRules: true); pings.removeAll() }
        lastProbe = p.t
        func silent(_ c: AlertProbe.Count?) -> Bool { c.map { $0.sent > 0 && $0.lost == $0.sent } ?? true }
        let noLink = p.linkKind == "none"
        pings.append(Round(t: p.t, gateway: p.gateway, internet: p.internet,
                           dead: noLink || ((p.gateway != nil || p.internet != nil) && silent(p.gateway) && silent(p.internet))))
        pings.removeAll { $0.t < p.t - 1440 * 60_000 }
        if let g = p.gateway, g.lost < g.sent { routerAnswered = true }

        for rule in rules where rule.enabled {
            let hold = Int64(rule.minutes) * 60_000
            switch rule.kind {
            case .wifi:
                guard let limit = rule.value else { continue }
                let weak: Bool? = p.linkKind == "wifi" ? p.rssi.map { $0 < limit } : false
                step(rule, Alert.host, nil, p.t, bad: weak, hold: hold, clear: hold, out: &out) { _ in
                    ("Wi-Fi signal is weak", "The signal is at \(Int((p.rssi ?? limit).rounded())) dBm. Remote sessions to the VMs will lag or drop even though the VMs themselves are fine.",
                     "Move the Mac closer to the router, or use Ethernet.")
                }
            case .vmFrozen:
                for (key, c) in p.vmPing where !rule.excluded.contains(key) && runningNow.contains(key) && c.sent > 0 {
                    // Only a VM that has answered before can stop answering: a guest whose firewall drops pings never does.
                    if c.lost < c.sent { answered.insert(key) }
                    guard answered.contains(key) else { continue }
                    let name = everRan[key] ?? key
                    let since = tracks[Alert.key(rule: rule.id, subject: key)]?.badSince ?? p.t
                    step(rule, key, key, p.t, bad: c.lost == c.sent, hold: hold, clear: 0, out: &out) { _ in
                        ("\(name) is not responding", "It is running but has not answered a ping since \(AlertEngine.clock(since)).",
                         "Open the VM in UTM and check it. A guest that sleeps on purpose can be left out of this rule.")
                    }
                }
            case .vmUnrouted:
                for (key, c) in p.vmRoute where !rule.excluded.contains(key) && runningNow.contains(key) && c.sent > 0 {
                    let name = everRan[key] ?? key
                    let seen = p.vmRouteSeen[key]
                    step(rule, key, key, p.t, bad: c.lost == c.sent, hold: hold, clear: 0, out: &out) { _ in
                        AlertEngine.unroutedText(name: name, seen: seen)
                    }
                }
            case .networkDown:
                let routerAnswered = self.routerAnswered
                step(rule, Alert.host, nil, p.t, bad: pings.last?.dead ?? false, hold: hold, clear: min(hold, 60_000), out: &out) { _ in
                    ("Network is down", noLink ? "This Mac has no network connection. Nothing outside can reach the VMs."
                                               : "Neither the router nor the internet answers. Nothing outside can reach the VMs.",
                     noLink ? "Connect this Mac to a network."
                            : routerAnswered ? "The router stopped answering too, so the break is on this Mac or between it and the router."
                                             : "This router never answers pings, so whether the break is before or beyond it cannot be told from here.")
                }
            case .poorConnection:
                guard let limit = rule.value else { continue }
                // An outage, where nothing answers for a while, belongs to "Network is down". Only scattered loss is "poor".
                let window = AlertEngine.withoutOutages(pings).filter { $0.t > p.t - hold }
                func loss(_ pick: (Round) -> AlertProbe.Count?) -> Double? {
                    let sent = window.reduce(0) { $0 + (pick($1)?.sent ?? 0) }, lost = window.reduce(0) { $0 + (pick($1)?.lost ?? 0) }
                    return sent >= 4 ? Double(lost) / Double(sent) : nil
                }
                let router = loss { $0.gateway }, internet = loss { $0.internet }
                // A side that loses every ping is not "poor": either the network is down, which has its own rule, or that
                // side never answers pings at all (some routers do not) and says nothing about the connection.
                let known = [router, internet].compactMap { $0 }
                let partial = known.filter { $0 < 1 }
                let worst = partial.max()
                let bad: Bool? = known.isEmpty ? nil : (worst.map { $0 * 100 > limit } ?? false)
                let routerLossy = router.map { $0 < 1 && $0 * 100 > limit } ?? false
                let routerSilent = router == 1
                step(rule, Alert.host, nil, p.t, bad: bad, hold: 0, clear: 60_000, out: &out) { _ in
                    ("Connection is poor", "\(Int(((worst ?? 0) * 100).rounded()))% of pings to \(routerLossy ? "the router" : "the internet") were lost over the last \(AlertRule.duration(rule.minutes)), in scattered gaps rather than one outage. Remote sessions to the VMs will lag or drop.",
                     routerLossy ? "Pings to the router are lost too, so the loss is between this Mac and the router."
                                 : routerSilent ? "This router never answers pings, so whether the loss is before or beyond it cannot be told from here."
                                                : "The router answers, so the loss is beyond the router.")
                }
            default:
                break
            }
        }
        closeOrphans(at: p.t, probeRules: true, out: &out)
        return out
    }

    // MARK: The lifecycle every rule shares

    private static let probeKinds: Set<String> = Set([AlertKind.wifi, .vmFrozen, .vmUnrouted, .networkDown, .poorConnection].map(\.rawValue))

    /// Title, what and what to do for a VM this Mac has no route back to.
    public static func unroutedText(name: String, seen: VMRoute?) -> (String, String, String) {
        let path: String
        if let s = seen {
            path = "Traffic for its address \(s.ip) leaves by \(s.via ?? "no interface") instead of \(s.bridge), its own network"
        } else {
            path = "Traffic for its address does not lead to its own network"
        }
        let what = "\(path). Everything the VM sends out through this Mac gets its replies sent the wrong way, so the VM is cut off from the internet and the rest of the network while it keeps running."
        let fix: String
        if let s = seen, let subnet = s.subnet {
            fix = "Put the route back with \"sudo route -n add -net \(subnet) -interface \(s.bridge)\", or shut down every VM and start them again so macOS sets up the VM network afresh."
        } else {
            fix = "Shut down every VM and start them again so macOS sets up the VM network afresh."
        }
        return ("\(name) is cut off from the network", what, fix)
    }

    private mutating func step(_ rule: AlertRule, _ subject: String, _ vmKey: String?, _ t: Int64, bad: Bool?, hold: Int64, clear: Int64,
                               out: inout [AlertChange], text: (String) -> (String, String, String)) {
        let key = Alert.key(rule: rule.id, subject: subject)
        if let until = muted[key] {
            if until > t { return }
            muted[key] = nil
        }
        guard let bad else { return }
        var track = tracks[key] ?? Track()
        defer { tracks[key] = track }
        if bad {
            track.goodSince = nil
            if track.acknowledged { return }
            if var a = open[key] {
                // Keep the wording current, but not more often than once a minute.
                guard t - track.refreshedAt >= 60_000 else { return }
                track.refreshedAt = t
                let (title, what, todo) = text(track.note)
                if a.title != title || a.what != what || a.level != rule.level {
                    a.title = title; a.what = what; a.todo = todo; a.level = rule.level
                    open[key] = a
                    out.append(.updated(a))
                }
                return
            }
            let since = track.badSince ?? t
            track.badSince = since
            guard t - since >= hold else { return }
            let (title, what, todo) = text(track.note)
            let a = Alert(rule: rule.id, level: rule.level, subject: subject, vmKey: vmKey, title: title, what: what, todo: todo, opened: since)
            open[key] = a
            track.refreshedAt = t
            out.append(.opened(a))
        } else {
            track.badSince = nil
            track.acknowledged = false
            track.note = ""
            guard open[key] != nil else { return }
            let since = track.goodSince ?? t
            track.goodSince = since
            guard t - since >= clear else { return }
            open[key] = nil
            track.goodSince = nil
            out.append(.closed(key: key, at: since))
        }
    }

    /// Alerts whose rule was switched off, or whose VM the rule now leaves out, close at once.
    private mutating func closeOrphans(at t: Int64, probeRules: Bool, out: inout [AlertChange]) {
        for (key, a) in open where AlertEngine.probeKinds.contains(a.rule) == probeRules {
            let rule = rules.first { $0.id == a.rule }
            if rule?.enabled != true || (a.vmKey.map { rule?.excluded.contains($0) ?? false } ?? false) {
                open[key] = nil; tracks[key] = nil
                out.append(.closed(key: key, at: t))
            }
        }
    }

    /// After a gap in the readings (the Mac slept, the app was not running) nothing half-counted carries over.
    private mutating func resetPending(probeRules: Bool) {
        for key in tracks.keys {
            let rule = String(key.split(separator: "|", maxSplits: 1).first ?? "")
            guard AlertEngine.probeKinds.contains(rule) == probeRules else { continue }
            // A VM that was found stopped keeps counting: it did not start again while nobody looked.
            if open[key] == nil, rule != AlertKind.vmStopped.rawValue { tracks[key]?.badSince = nil }
            tracks[key]?.goodSince = nil
        }
        if !probeRules { recent.removeAll() }
    }

    // MARK: Small helpers

    /// A run of rounds in which nothing answered, long enough to be an outage rather than a few lost pings.
    static let outageRounds = 3

    /// The rounds left once outages are taken out: runs of dead rounds with at least `outageRounds` rounds or pings in them.
    private static func withoutOutages(_ rounds: [Round]) -> [Round] {
        var keep: [Round] = [], run: [Round] = []
        func endRun() {
            let pinged = run.reduce(0) { $0 + max($1.gateway?.sent ?? 0, $1.internet?.sent ?? 0) }
            if run.count < outageRounds && pinged < outageRounds { keep += run }
            run = []
        }
        for r in rounds {
            if r.dead { run.append(r) } else { endRun(); keep.append(r) }
        }
        endRun()
        return keep
    }

    private static func record(_ store: inout [String: [(t: Int64, v: Double)]], _ key: String, _ t: Int64, _ v: Double, every: Int64, keep: Int64) {
        var list = store[key] ?? []
        if let last = list.last, t - last.t < every { return }
        if let last = list.last, t <= last.t { return }
        list.append((t, v))
        if let n = list.firstIndex(where: { $0.t >= t - keep }), n > 0 { list.removeFirst(n) }
        store[key] = list
    }

    private static func mean(_ list: [(t: Int64, v: Double)]?) -> Double? {
        guard let list, !list.isEmpty else { return nil }
        return list.reduce(0) { $0 + $1.v } / Double(list.count)
    }

    /// Seconds until a disk reaches `limit` at the pace of the last hours; nil when it is not heading there or too little is known.
    private func secondsUntilFull(_ key: String, now: Int64, value: Double, limit: Double, rising: Bool) -> Double? {
        guard let list = trend[key], let first = list.first, now - first.t >= AlertEngine.trendMinMs else { return nil }
        let seconds = Double(now - first.t) / 1000
        let rate = (value - first.v) / seconds
        let left = rising ? limit - value : value - limit
        guard left > 0 else { return 0 }
        let pace = rising ? rate : -rate
        // Less than 50 MB an hour is the ordinary breathing of a disk, not a trend.
        guard pace > 50_000_000 / 3600 else { return nil }
        return left / pace
    }

    static func gb(_ bytes: Double) -> String {
        let g = bytes / 1_073_741_824
        return g >= 100 ? String(Int(g.rounded())) : String(format: "%.1f", g)
    }

    static func span(_ seconds: Double) -> String {
        if seconds < 5400 { return "\(max(1, Int((seconds / 60).rounded()))) min" }
        if seconds < 36 * 3600 { return "\(Int((seconds / 3600).rounded())) hours" }
        return "\(Int((seconds / 86400).rounded())) days"
    }

    static func clock(_ ms: Int64) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return f.string(from: Date(ms: ms))
    }
}
