import CSysShim
import Foundation

/// Owns every collector and turns their readings into one `Snapshot` per tick.
public final class MonitorEngine {
    public struct Options {
        public var utmDirectory: URL = UTMBundles.defaultDirectory
        /// How often the slow sources (UTM list, bridge table, bundle configs) are re-read.
        public var listRefreshSeconds: Double = 10
        public var useUTMScripting = true
        /// Flip if the R1 check shows vmenet in/out are the other way round.
        public var swapDirections = false
        public var macOSLimit = 2
        public init() {}
    }

    public let options: Options

    private let sampler = ProcessSampler()
    private let rateTracker = InterfaceRateTracker()
    private var knownPids: Set<Int32> = []
    private var pidBundle: [Int32: String] = [:]          // pid -> bundle path
    private var bundles: [String: UTMBundle] = [:]        // bundle path -> config
    private var macToInterface: [String: String] = [:]
    private var utmList: [UTMListedVM]?
    private var utmError: UTMScriptingError?
    private var lastSlowRefresh: UInt64 = 0
    private var slowInFlight = false
    private var slowRequested = true
    private var everRefreshed = false
    private var firstRefreshDone: DispatchSemaphore?
    /// How long the very first tick waits for bundle configs so the first frame has names.
    /// Never longer: a macOS permission prompt can hold the directory read for minutes.
    private let firstRefreshWait: TimeInterval = 2
    /// After a failed/timed-out UTM query (typically the Automation permission prompt still on screen),
    /// wait this long before asking again so the user is not re-prompted every 10 seconds.
    private var utmRetryAfter: UInt64 = 0
    private var utmForced = false
    private let utmBackoffSeconds: Double = 60
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "utmwatch.slow-refresh", qos: .utility)
    private var lastCPUTicks: (busy: UInt64, total: UInt64)?
    private var targets: [(key: String, name: String, macs: [String])] = []

    /// Running VMs and their MAC addresses, for the network probes. Safe to call from any thread.
    public func networkTargets() -> [(key: String, name: String, macs: [String])] {
        lock.lock(); defer { lock.unlock() }
        return targets
    }

    public init(options: Options = Options()) {
        self.options = options
    }

    /// Ask for the slow sources to be re-read on the next tick (e.g. user pressed `r`).
    public func requestRefresh() {
        lock.lock(); slowRequested = true; utmForced = true; lock.unlock()
    }

    // MARK: - Slow sources

    private struct ConfigResult {
        var bundles: [String: UTMBundle]
        var macToInterface: [String: String]
    }

    /// Bundle configs and the bridge table: local file and ifconfig reads, normally well under a second.
    private func collectConfigs(extraBundlePaths: [String]) -> ConfigResult {
        var found: [String: UTMBundle] = [:]
        for b in UTMBundles.scan(directory: options.utmDirectory) { found[b.url.path] = b }
        for path in extraBundlePaths where found[path] == nil {
            if let b = UTMBundles.load(url: URL(fileURLWithPath: path, isDirectory: true)) { found[path] = b }
        }
        let bridges = BridgeTable.vmBridges(from: InterfaceList.read().keys)
        return ConfigResult(bundles: found, macToInterface: BridgeTable.read(bridges: bridges))
    }

    private func apply(_ r: ConfigResult) {
        bundles = r.bundles
        if !r.macToInterface.isEmpty || macToInterface.isEmpty { macToInterface = r.macToInterface }
    }

    private func apply(_ utm: Result<[UTMListedVM], UTMScriptingError>) {
        switch utm {
        case .success(let list): utmList = list; utmError = nil
        case .failure(let err):
            if utmError != err { FileLog.shared.log(err.notice) }
            utmError = err
            if err == .notRunning { utmList = nil }
            if err != .notRunning { utmRetryAfter = MonotonicClock.now() &+ UInt64(utmBackoffSeconds * 1e9) }
        }
    }

    private func maybeStartSlowRefresh(now: UInt64) {
        let due = Double(now &- lastSlowRefresh) / 1e9 >= options.listRefreshSeconds
        guard (due || slowRequested), !slowInFlight else { return }
        slowRequested = false
        slowInFlight = true
        lastSlowRefresh = now
        let extra = Array(Set(pidBundle.values))
        let askUTM = options.useUTMScripting && (utmForced || now >= utmRetryAfter)
        utmForced = false
        // Configs first, applied as soon as they are in; the UTM query runs after and is applied
        // separately, so a stalled AppleEvent (e.g. a pending permission prompt) never delays names.
        queue.async { [weak self] in
            guard let self else { return }
            autoreleasepool { self.slowRefresh(extraBundlePaths: extra, askUTM: askUTM) }
        }
    }

    private func slowRefresh(extraBundlePaths extra: [String], askUTM: Bool) {
        do {
            let configs = self.collectConfigs(extraBundlePaths: extra)
            self.lock.lock()
            self.apply(configs)
            let first = self.firstRefreshDone
            self.firstRefreshDone = nil
            if !askUTM { self.slowInFlight = false }
            self.lock.unlock()
            first?.signal()
            guard askUTM else { return }
            let utm = UTMScripting.list()
            self.lock.lock()
            self.apply(utm)
            self.slowInFlight = false
            self.lock.unlock()
        }
    }

    // MARK: - Tick

    public func tick(interval: Double) -> Snapshot {
        let now = MonotonicClock.now()
        lock.lock(); defer { lock.unlock() }

        // 1. Processes; re-match bundles only when the pid set changes.
        let procs = ProcessScanner.scan()
        let pids = Set(procs.map(\.pid))
        if pids != knownPids {
            for pid in pids.subtracting(knownPids) {
                if let url = ProcessVMMatcher.bundleURL(pid: pid) { pidBundle[pid] = url.path }
            }
            for pid in knownPids.subtracting(pids) { pidBundle[pid] = nil }
            knownPids = pids
            slowRequested = true // new VM: bridge table / UTM status need a fresh look
        }

        // 2. Slow sources, always off the main path. On the first tick give them a moment so the
        //    first frame already has names, but never block on them: reading another app's
        //    container or sending UTM an AppleEvent can stall on a macOS permission prompt.
        if !everRefreshed {
            everRefreshed = true
            let done = DispatchSemaphore(value: 0)
            firstRefreshDone = done
            slowRequested = true
            maybeStartSlowRefresh(now: now)
            lock.unlock()
            _ = done.wait(timeout: .now() + firstRefreshWait)
            lock.lock()
        } else {
            maybeStartSlowRefresh(now: now)
        }

        // 3. Fast samples. Timestamp immediately before reading so the first wait above (or any
        //    other delay) does not stretch the measurement window and dilute the rates.
        let sampleTime = MonotonicClock.now()
        let usage = sampler.sample(pids: procs.map(\.pid), now: sampleTime)
        let counters = InterfaceList.read()
        let rates = rateTracker.update(counters, now: sampleTime)

        // 4. Rows.
        var rows: [VMRow] = []
        var usedBundles: Set<String> = []
        var vmFootprints: UInt64 = 0
        var configPending: [String] = []
        var newTargets: [(key: String, name: String, macs: [String])] = []
        for proc in procs {
            let u = usage[proc.pid]
            vmFootprints &+= u?.footprint ?? 0
            if let path = pidBundle[proc.pid] {
                // Until config.plist has been read, show the bundle's folder name without limits.
                let b = bundles[path] ?? Self.placeholderBundle(path: path, backend: proc.backend)
                if bundles[path] == nil { configPending.append(b.name) }
                usedBundles.insert(path)
                let listed = utmEntry(for: b)
                var status = listed.map { VMStatus(utmStatus: $0.status) } ?? .running
                if status == .stopped || status == .unknown { status = .running } // process exists, list is stale
                let iface = b.macAddresses.compactMap { macToInterface[$0] }.first
                let counter = iface.flatMap { counters[$0] }
                let rate = iface.flatMap { rates[$0] }
                let swap = options.swapDirections
                newTargets.append((b.identity, b.name, b.macAddresses))
                var row = VMRow(
                    id: b.identity, name: b.name, backend: b.backend == .unknown ? proc.backend : b.backend,
                    status: status, pid: proc.pid, identified: true, isMacOS: b.isMacOS,
                    cpuCores: u?.cpuCores, cpuAllocated: b.cpuCount,
                    memoryBytes: u?.footprint, memoryAllocatedBytes: b.memoryBytes, interface: iface,
                    downRate: rate.map { swap ? $0.ibytesPerSecond : $0.obytesPerSecond },
                    upRate: rate.map { swap ? $0.obytesPerSecond : $0.ibytesPerSecond },
                    downTotal: counter.map { swap ? $0.ibytes : $0.obytes },
                    upTotal: counter.map { swap ? $0.obytes : $0.ibytes })
                row.diskReadRate = u?.diskReadRate
                row.diskWriteRate = u?.diskWriteRate
                rows.append(row)
            } else {
                var row = VMRow(id: "pid:\(proc.pid)", name: "Unidentified VM (PID \(proc.pid))",
                                backend: proc.backend, status: .running, pid: proc.pid, identified: false,
                                cpuCores: u?.cpuCores, memoryBytes: u?.footprint)
                row.diskReadRate = u?.diskReadRate
                row.diskWriteRate = u?.diskWriteRate
                rows.append(row)
            }
        }
        // Bundles without a process: stopped (or whatever UTM says, e.g. starting).
        for b in bundles.values where !usedBundles.contains(b.url.path) {
            let listed = utmEntry(for: b)
            let status = listed.map { VMStatus(utmStatus: $0.status) } ?? .stopped
            rows.append(VMRow(id: b.identity, name: b.name, backend: b.backend, status: status, identified: true,
                              isMacOS: b.isMacOS, cpuAllocated: b.cpuCount, memoryAllocatedBytes: b.memoryBytes))
        }
        // UTM knows about VMs stored outside the default folder.
        let coveredIds = Set(rows.map(\.id)), coveredNames = Set(rows.map(\.name))
        for entry in utmList ?? [] where !coveredIds.contains(entry.id) && !coveredNames.contains(entry.name) {
            let backend: VMBackend = entry.backend.lowercased() == "apple" ? .apple : entry.backend.lowercased() == "qemu" ? .qemu : .unknown
            rows.append(VMRow(id: entry.id, name: entry.name, backend: backend, status: VMStatus(utmStatus: entry.status), identified: true))
        }

        // 5. Host summary.
        let running = rows.filter { $0.pid != nil }
        let runningAllocated = running.reduce(UInt64(0)) { $0 &+ ($1.memoryAllocatedBytes ?? 0) }
        let allocatedCores = running.reduce(0) { $0 + ($1.cpuAllocated ?? 0) }
        let macOSRunning = running.filter(\.isMacOS).count
        let mem = HostStats.memory()
        let swap = HostStats.swap()
        let host = HostSummary.compute(totalMemory: HostStats.totalMemory, hostUsed: mem?.used ?? 0,
                                       vmFootprints: vmFootprints, runningAllocated: runningAllocated,
                                       pressure: HostStats.pressure(), swapUsed: swap.used, swapTotal: swap.total,
                                       physicalCores: HostStats.physicalCores, allocatedCores: allocatedCores,
                                       macOSRunning: macOSRunning)

        targets = newTargets
        var hostCPU: Double?
        var busy: UInt64 = 0, total: UInt64 = 0
        if shim_host_cpu_ticks(&busy, &total) == 0 {
            if let last = lastCPUTicks, total > last.total, busy >= last.busy {
                hostCPU = Double(busy - last.busy) / Double(total - last.total) * Double(HostStats.physicalCores)
            }
            lastCPUTicks = (busy, total)
        }

        // 6. Notices.
        var notices: [String] = []
        if let err = utmError { notices.append(err.notice) }
        if !configPending.isEmpty {
            notices.append("Reading configs: \(configPending.joined(separator: ", ")) (if macOS asks to allow access to data from other apps, click Allow)")
        }
        let unmapped = running.filter { $0.identified && $0.interface == nil && $0.backend == .apple && !configPending.contains($0.name) }.map(\.name)
        if !unmapped.isEmpty { notices.append("No bridge entry yet for: \(unmapped.joined(separator: ", ")) (appears once the VM sends traffic)") }

        var summary = HostSummary(totalMemory: host.totalMemory, hostUsed: host.hostUsed, hostOtherUsed: host.hostOtherUsed,
                                  freeNow: host.freeNow, allocatable: host.allocatable, pressure: host.pressure,
                                  swapUsed: host.swapUsed, swapTotal: host.swapTotal, physicalCores: host.physicalCores,
                                  allocatedCores: host.allocatedCores, macOSRunning: host.macOSRunning, macOSLimit: options.macOSLimit)
        summary.hostCPUCores = hostCPU
        return Snapshot(timestamp: Date(), intervalSeconds: interval, rows: rows, host: summary, notices: notices)
    }

    public static func placeholderBundle(path: String, backend: VMBackend) -> UTMBundle {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        return UTMBundle(url: url, uuid: nil, name: url.deletingPathExtension().lastPathComponent, backend: backend,
                         cpuCount: nil, memoryBytes: nil, macAddresses: [], networkModes: [], isMacOS: false)
    }

    private func utmEntry(for bundle: UTMBundle) -> UTMListedVM? {
        guard let list = utmList else { return nil }
        if let uuid = bundle.uuid, let hit = list.first(where: { $0.id.caseInsensitiveCompare(uuid) == .orderedSame }) { return hit }
        return list.first { $0.name == bundle.name }
    }
}
