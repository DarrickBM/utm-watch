// Minimal self-contained checks for the pure logic in UTMWatchCore.
// Run with `swift run selftest`; exits non-zero on the first group with failures.
import Foundation
import UTMWatchCore
import UTMWatchStore

var failures = 0
var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String, file: String = #fileID, line: Int = #line) {
    checks += 1
    if !condition() {
        failures += 1
        print("FAIL \(file):\(line): \(message)")
    }
}
func near(_ a: Double, _ b: Double, _ eps: Double = 1e-6) -> Bool { abs(a - b) < eps }

// MARK: Rates
do {
    let a = ProcessSample(cpuNanos: 1_000_000_000, footprint: 1, wallNanos: 10_000_000_000)
    let b = ProcessSample(cpuNanos: 3_900_000_000, footprint: 1, wallNanos: 12_000_000_000)
    check(near(ProcessSampler.cores(previous: a, current: b) ?? -1, 1.45), "cores = cpu delta / wall delta")
    let c = ProcessSample(cpuNanos: 5, footprint: 1, wallNanos: 10)
    let d = ProcessSample(cpuNanos: 4, footprint: 1, wallNanos: 20)
    check(ProcessSampler.cores(previous: c, current: d) == nil, "cpu time going backwards is dropped")
    check(ProcessSampler.cores(previous: d, current: c) == nil, "wall time going backwards is dropped")

    let p = InterfaceCounter(name: "vmenet1", index: 55, ibytes: 1_000, obytes: 2_000)
    let q = InterfaceCounter(name: "vmenet1", index: 55, ibytes: 1_500, obytes: 6_000)
    let r = InterfaceRateTracker.rate(previous: p, previousWall: 0, current: q, currentWall: 2_000_000_000)
    check(near(r?.ibytesPerSecond ?? -1, 250), "ibytes rate uses elapsed seconds")
    check(near(r?.obytesPerSecond ?? -1, 2_000), "obytes rate uses elapsed seconds")
    let reset = InterfaceCounter(name: "vmenet1", index: 55, ibytes: 10, obytes: 20)
    check(InterfaceRateTracker.rate(previous: p, previousWall: 0, current: reset, currentWall: 1_000_000_000) == nil, "counter reset is dropped")
    let rebuilt = InterfaceCounter(name: "vmenet1", index: 61, ibytes: 5_000, obytes: 9_000)
    check(InterfaceRateTracker.rate(previous: p, previousWall: 0, current: rebuilt, currentWall: 1_000_000_000) == nil, "interface rebuild (new index) is dropped")

    let tracker = InterfaceRateTracker()
    check(tracker.update(["en0": InterfaceCounter(name: "en0", index: 1, ibytes: 1, obytes: 1)], now: 1).isEmpty, "no rate on first sample")
    check(tracker.update(["en0": InterfaceCounter(name: "en0", index: 1, ibytes: 1_001, obytes: 1)], now: 1_000_000_001).count == 1, "rate on second sample")
}

// MARK: Matching and parsing
do {
    let path = "/Users/d/Library/Containers/com.utmapp.UTM/Data/Documents/macOS 26 B.utm/Data/1E99.img"
    check(ProcessVMMatcher.utmBundlePath(fromOpenPath: path) == "/Users/d/Library/Containers/com.utmapp.UTM/Data/Documents/macOS 26 B.utm", "bundle path with spaces")
    check(ProcessVMMatcher.utmBundlePath(fromOpenPath: "/dev/null") == nil, "no bundle in /dev/null")
    check(ProcessVMMatcher.utmBundlePath(fromOpenPath: "/Users/d/notes.utm.txt") == nil, ".utm.txt is not a bundle")

    check(ProcessScanner.isVMExecutable("/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine"), "Apple VM helper detected")
    check(ProcessScanner.isVMExecutable("/Applications/UTM.app/Contents/Frameworks/qemu-system-aarch64"), "QEMU detected")
    check(ProcessScanner.isVMExecutable("/Applications/UTM.app/Contents/XPCServices/QEMUHelper.xpc/Contents/MacOS/QEMUHelper"), "UTM QEMU helper detected")
    check(!ProcessScanner.isVMExecutable("/Applications/UTM.app/Contents/MacOS/UTM"), "UTM itself is not a VM")

    let ifconfig = """
    bridge100: flags=8a63<UP,BROADCAST,SMART,RUNNING,ALLMULTI,SIMPLEX,MULTICAST> mtu 1500
    \tmember: vmenet0 flags=20803<LEARNING,DISCOVER,PRIVATE,VIRTIO>
    \t        ifmaxaddr 0 port 52 priority 0 path cost 0
    \tAddress cache:
    \t\t02:1a:2b:3c:4d:5e Vlan1 vmenet1 1200 flags=0<>
    \t\t02:aa:bb:cc:dd:6c Vlan1 vmenet0 1200 flags=0<>
    \t\t2:1b:0:5:a:f Vlan1 vmenet2 1200 flags=0<>
    \tnd6 options=201<PERFORMNUD,DAD>
    \tmedia: autoselect
    """
    let table = BridgeTable.parseAddressCache(ifconfig)
    check(table["02:1a:2b:3c:4d:5e"] == "vmenet1", "address cache row 1")
    check(table["02:aa:bb:cc:dd:6c"] == "vmenet0", "address cache row 2")
    check(table["02:1b:00:05:0a:0f"] == "vmenet2", "ifconfig drops leading zeros; normalized")
    check(table.count == 3, "exactly three cache rows, nothing after the block")
    check(BridgeTable.vmBridges(from: ["en0", "bridge0", "bridge100", "bridge101", "vmenet0"]) == ["bridge100", "bridge101"], "only bridge1xx are VM bridges")
    check(MACAddress.normalize("0E:01:02:03:04:05") == "0e:01:02:03:04:05", "MAC lowercase")
    check(MACAddress.normalize("e:1:2:3:4:5") == "0e:01:02:03:04:05", "MAC zero padded")

    let plist: [String: Any] = [
        "Backend": "Apple",
        "Information": ["Name": "macOS 26", "UUID": "11111111-2222-3333-4444-555555555555"],
        "Network": [["MacAddress": "02:aa:bb:cc:dd:6c", "Mode": "Shared"]],
        "System": ["CPUCount": 6, "MemorySize": 8192, "Boot": ["OperatingSystem": "macOS"]],
    ]
    let b = UTMBundles.parse(plist: plist, url: URL(fileURLWithPath: "/x/macOS 26.utm"))
    check(b.name == "macOS 26" && b.backend == .apple && b.cpuCount == 6, "bundle basics")
    check(b.memoryBytes == 8192 * 1024 * 1024, "MemorySize is MiB")
    check(b.macAddresses == ["02:aa:bb:cc:dd:6c"] && b.isMacOS, "MAC and macOS flag")
    check(b.identity == "/x/macOS 26.utm" && b.uuid == "11111111-2222-3333-4444-555555555555", "identity is the bundle path; UUID kept for matching UTM")
    check(MonitorEngine.placeholderBundle(path: "/x/macOS 26.utm", backend: .apple).identity == b.identity, "identity is the same before and after the config is read")
    let fallback = UTMBundles.parse(plist: [:], url: URL(fileURLWithPath: "/x/Ubuntu.utm"))
    check(fallback.name == "Ubuntu" && fallback.backend == .unknown && fallback.cpuCount == nil && !fallback.isMacOS, "empty plist falls back to folder name")

    let list = try? UTMScripting.parse(#"[{"id":"B390","name":"macOS 26","status":"started","backend":"apple"}]"#)
    check(list?.count == 1 && VMStatus(utmStatus: list![0].status) == .running, "UTM JSON parsed; started -> running")
    check(VMStatus(utmStatus: "stopped") == .stopped && VMStatus(utmStatus: "weird") == .unknown, "status mapping")
}

// MARK: Footer math
do {
    let gb: UInt64 = 1 << 30
    let s = HostSummary.compute(totalMemory: 48 * gb, hostUsed: 39 * gb, vmFootprints: 16 * gb, runningAllocated: 16 * gb,
                                pressure: .normal, swapUsed: 0, swapTotal: 0, physicalCores: 14, allocatedCores: 10, macOSRunning: 2)
    check(s.hostOtherUsed == 23 * gb, "host usage outside VMs")
    check(s.freeNow == 9 * gb, "free now")
    check(s.allocatable == 48 * gb - 23 * gb - 16 * gb, "allocatable counts configured VM limits, not footprints")
    check(!s.overcommitted, "10 of 14 cores is not overcommitted")
    let t = HostSummary.compute(totalMemory: 48 * gb, hostUsed: 47 * gb, vmFootprints: 10 * gb, runningAllocated: 40 * gb,
                                pressure: .warning, swapUsed: 1, swapTotal: 2, physicalCores: 14, allocatedCores: 16, macOSRunning: 1)
    check(t.allocatable == 0 && t.overcommitted, "clamped at zero and overcommit flagged")
}

// MARK: Formatting
do {
    check(Format.memory(8192 * 1024 * 1024) == "8.0 GB", "memory binary GB")
    check(Format.memoryPair(UInt64(6.1 * 1024 * 1024 * 1024), 8192 * 1024 * 1024) == "6.1 / 8 GB", "memory pair")
    check(Format.memoryPair(nil, 8192 * 1024 * 1024) == "— / 8 GB", "memory pair without usage")
    check(Format.bytes(7_300_000_000) == "7.3 GB", "network totals decimal")
    check(Format.rate(11_800_000, units: .bytes) == "11.8 MB/s", "MB/s")
    check(Format.rate(200, units: .bytes) == "0.2 KB/s", "KB/s")
    check(Format.rate(11_800_000, units: .bits) == "94.4 Mbps", "Mbps")
    check(Format.rate(nil, units: .bytes) == "—", "unknown rate")
    check(Format.cores(2.94, 4) == "2.9 / 4 cores" && Format.cores(nil, 4) == "— / 4 cores" && Format.cores(0.5, nil) == "0.5 cores", "cores text")
    check(Format.displayWidth("macOS 26") == 8 && Format.displayWidth("虚拟机") == 6, "display width")
    check(Format.pad("ab", 5) == "ab   " && Format.pad("ab", 5, .right) == "   ab", "padding")
    check(Format.displayWidth(Format.pad("虚拟机名字很长", 7)) == 7, "truncation respects wide chars")
    check(Format.pad("abcdefgh", 4).hasSuffix("…"), "truncation marker")
}

// MARK: History store and events
do {
    let path = NSTemporaryDirectory() + "utmwatch-selftest-\(ProcessInfo.processInfo.processIdentifier).sqlite"
    for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
    let gb: UInt64 = 1 << 30
    let start = Date(timeIntervalSince1970: 1_800_000_000)   // on a minute boundary
    func snap(_ i: Int, bRunning: Bool = true, pressure: MemoryPressure = .normal, swap: UInt64 = 1, bCPU: Double = 1.0) -> Snapshot {
        var rows = [VMRow(id: "A", name: "macOS 26", backend: .apple, status: .running, pid: 10, identified: true, isMacOS: true,
                          cpuCores: 1.0 + Double(i % 5) * 0.1, cpuAllocated: 6, memoryBytes: 7 * gb, memoryAllocatedBytes: 8 * gb,
                          downRate: 1000, upRate: 500, downTotal: UInt64(i) * 2000, upTotal: UInt64(i) * 1000)]
        rows.append(bRunning
            ? VMRow(id: "B", name: "macOS 26 B", backend: .apple, status: .running, pid: 11, identified: true, isMacOS: true,
                    cpuCores: bCPU, cpuAllocated: 4, memoryBytes: 6 * gb, memoryAllocatedBytes: 8 * gb, downRate: 2e6, upRate: 1e5, downTotal: 5, upTotal: 6)
            : VMRow(id: "B", name: "macOS 26 B", backend: .apple, status: .stopped, identified: true))
        let host = HostSummary(totalMemory: 48 * gb, hostUsed: 40 * gb, hostOtherUsed: 24 * gb, freeNow: 8 * gb, allocatable: 8 * gb,
                               pressure: pressure, swapUsed: swap * gb, swapTotal: 4 * gb, physicalCores: 14, allocatedCores: 10, macOSRunning: 2)
        return Snapshot(timestamp: start.addingTimeInterval(Double(i) * 2), intervalSeconds: 2, rows: rows, host: host, notices: [])
    }

    if let store = try? HistoryStore(path: path) {
        // 10 minutes at 2 s; B stops for one minute in the middle.
        let snaps = (0..<300).map { snap($0, bRunning: !(120..<150).contains($0)) }
        store.write(snapshots: Array(snaps[0..<150]), events: [HistoryEvent(ts: start.msSince1970 + 5000, kind: "vm_started", vmKey: "B", label: "macOS 26 B started")])
        store.write(snapshots: Array(snaps[150...]))
        let t0 = start.msSince1970, t1 = t0 + 600_000

        let raw = store.load(from: t0, to: t1, maxPoints: nil)
        check(raw.series["A"]?.count == 300, "raw load returns every sample for A")
        check(raw.series["B"]?.count == 270, "B has a one-minute gap")
        check(raw.host.count == 300 && raw.events.count == 1, "host samples and events stored")
        check(raw.series["A"]?.first?.mem == Double(7 * gb) && raw.series["A"]?.last?.downTotal == 299 * 2000, "memory and totals stored as real byte counts")
        check(raw.config(for: "A", at: t0)?.memBytes == Double(8 * gb) && raw.host.first?.swapTotal == Double(4 * gb), "limits and host values stored as real byte counts")
        check(raw.vms.map(\.key) == ["A", "B"], "VMs listed in first-seen order")
        check(raw.config(for: "A", at: t0 + 1000)?.cores == 6, "config recorded once and found by time")
        check(raw.configs["A"]?.count == 1, "unchanged config is not rewritten")

        let small = store.load(from: t0, to: t1, maxPoints: 50)
        check((small.series["A"]?.count ?? 0) <= 51 && (small.series["A"]?.count ?? 0) >= 45, "bucketed load respects maxPoints")
        check(near(small.series["A"]?.first?.cpuMax ?? 0, 1.4, 0.001), "bucket keeps the peak")
        check((small.series["A"]?.first?.cpu ?? 0) < 1.4, "bucket average is below the peak")

        let long = store.load(from: t0 - 3 * 3600_000, to: t1, maxPoints: 600)
        check(long.series["A"]?.count == 9, "frames over 2 h read completed 1-minute rollups")
        check(long.bucketMs >= 60000, "rollup points are at least a minute wide")

        let stats = store.stats()
        check(stats.sampleCount == 300 && stats.oldest == t0 && stats.bytes > 0, "stats report count, oldest sample and size")

        store.prune(olderThan: t0 + 300_000)
        check(store.load(from: t0, to: t1, maxPoints: nil).series["A"]?.count == 150, "prune removes old raw samples")
        check(store.load(from: t0 - 3 * 3600_000, to: t1, maxPoints: 600).series["A"]?.count == 4, "prune removes old rollups")

        store.clear()
        let empty = store.load(from: t0, to: t1, maxPoints: nil)
        check(empty.series.isEmpty && empty.host.isEmpty && empty.events.isEmpty && store.knownVMs().isEmpty, "clear removes everything")
        store.write(snapshots: [snap(400)])
        check(store.knownVMs().count == 2, "recording works again after clear")
    } else {
        do { _ = try HistoryStore(path: path) } catch { print("store error:", error) }
        check(false, "history store opens")
    }
    for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }

    var det = EventDetector()
    check(det.ingest(snap(0)).isEmpty, "first snapshot only sets the baseline")
    check(det.ingest(snap(1, bRunning: false)).map(\.kind) == ["vm_stopped"], "VM stop detected")
    check(det.ingest(snap(2)).map(\.kind) == ["vm_started"], "VM start detected")
    check(det.ingest(snap(3, pressure: .warning)).map(\.kind) == ["pressure_warning"], "pressure warning detected")
    check(det.ingest(snap(4, pressure: .warning)).isEmpty, "no repeat while pressure stays")
    check(det.ingest(snap(5, swap: 4)).map(\.kind) == ["pressure_normal", "swap_high"], "pressure clears, swap crosses 80%")
    check(det.ingest(snap(6, swap: 3)).isEmpty, "swap hysteresis: 75% does not clear")
    check(det.ingest(snap(7, swap: 2)).map(\.kind) == ["swap_normal"], "swap clears under 75%")
    var kinds: [String] = []
    for i in 8..<45 { kinds += det.ingest(snap(i, swap: 2, bCPU: 3.8)).map(\.kind) }
    check(kinds == ["cpu_limit"], "CPU limit fires once after 60 s sustained")
    check(det.ingest(snap(45, swap: 2, bCPU: 1.0)).isEmpty && det.ingest(snap(46, swap: 2, bCPU: 3.9)).isEmpty, "CPU limit resets and needs another 60 s")
}

// MARK: Probes, link and incident finding
do {
    check(NetProbe.parseRoute("   route to: default\n    gateway: 192.168.1.1\n  interface: en1\n      flags: <UP>").gateway == "192.168.1.1", "default gateway parsed")
    check(NetProbe.parseRoute("    gateway: 192.168.1.1\n  interface: en1\n").interface == "en1", "default interface parsed")
    let arp = NetProbe.parseARP("? (192.168.64.3) at 02:1a:2b:3c:4d:5e on bridge100 ifscope [bridge]\n? (203.0.113.9) at (incomplete) on bridge100 ifscope [bridge]\n? (192.168.1.9) at a:b:c:d:e:f on en1 ifscope [ethernet]\n? (192.168.64.2) at 02:aa:bb:cc:dd:6 on bridge100 ifscope [bridge]")
    check(arp["02:1a:2b:3c:4d:5e"] == "192.168.64.3" && arp["02:aa:bb:cc:dd:06"] == "192.168.64.2" && arp.count == 2, "ARP: bridge entries only, MACs normalized, incomplete skipped")

    let path = NSTemporaryDirectory() + "utmwatch-selftest-probe-\(ProcessInfo.processInfo.processIdentifier).sqlite"
    for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
    let gb: UInt64 = 1 << 30
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let t0 = start.msSince1970
    // 30 minutes: memory pressure in minutes 10-14, weak Wi-Fi with slow router in 20-22, a sleep gap in 25-28.
    func minute(_ i: Int) -> Int { i * 2 / 60 }
    var snaps: [Snapshot] = [], probes: [ProbeResult] = []
    for i in 0..<900 where !(25..<28).contains(minute(i)) {
        let pressured = (10..<14).contains(minute(i))
        var a = VMRow(id: "A", name: "macOS 26", backend: .apple, status: .running, pid: 10, identified: true, isMacOS: true,
                      cpuCores: 1.0, cpuAllocated: 6, memoryBytes: 7 * gb, memoryAllocatedBytes: 8 * gb, downRate: 1000,
                      upRate: (20..<22).contains(minute(i)) ? 400_000 : 500, downTotal: 1, upTotal: 1)
        a.diskWriteRate = 2_000_000
        var host = HostSummary(totalMemory: 48 * gb, hostUsed: 40 * gb, hostOtherUsed: (pressured ? 34 : 24) * gb, freeNow: 8 * gb, allocatable: 8 * gb,
                               pressure: pressured ? .warning : .normal, swapUsed: (pressured ? 3600 : 1000) * (gb / 1000), swapTotal: 4 * gb,
                               physicalCores: 14, allocatedCores: 6, macOSRunning: 1)
        host.hostCPUCores = 3.5
        snaps.append(Snapshot(timestamp: start.addingTimeInterval(Double(i) * 2), intervalSeconds: 2, rows: [a], host: host, notices: []))
        if i % 5 == 0 {
            let weak = (20..<22).contains(minute(i))
            var link = LinkInfo(kind: "wifi", interface: "en1")
            link.rssi = weak ? -80 : -55; link.noise = -94; link.txRateMbps = weak ? 86 : 866; link.channel = 36
            probes.append(ProbeResult(timestamp: start.addingTimeInterval(Double(i) * 2), vmPing: ["A": pressured ? 180.0 : 0.6],
                                      gatewayTried: true, gatewayMs: weak ? 140 : 3, internetTried: true,
                                      internetMs: weak && i % 10 == 0 ? nil : (weak ? 230 : 20), link: link))
        }
    }
    if let store = try? HistoryStore(path: path) {
        store.write(snapshots: snaps, events: [HistoryEvent(ts: t0 + 25 * 60_000, kind: "sleep", vmKey: nil, label: "Mac went to sleep"),
                                                HistoryEvent(ts: t0 + 11 * 60_000, kind: "pressure_warning", vmKey: nil, label: "Memory pressure: warning", detail: #"{"topMemory":[{"name":"oMLX"}]}"#)],
                    probes: probes)
        let h = store.load(from: t0, to: t0 + 30 * 60_000, maxPoints: 180)
        check(h.probes[ProbeTarget.vm("A")]?.isEmpty == false && h.probes[ProbeTarget.gateway]?.isEmpty == false && h.probes[ProbeTarget.internet]?.isEmpty == false, "probe series stored for VM, router and internet")
        check((h.probes[ProbeTarget.internet] ?? []).reduce(0) { $0 + $1.lost } == 6, "lost pings counted")
        check(h.link.count > 100 && h.link.contains { ($0.rssi ?? 0) <= -79 }, "link samples stored with signal strength")
        check(h.series["A"]?.first?.diskWrite == 2_000_000 && h.host.first?.cpu == 3.5, "disk rate and host CPU stored")
        check(h.events.first { $0.kind == "pressure_warning" }?.detail?.contains("oMLX") == true, "event detail stored")

        let found = Diagnostics.incidents(h)
        let kinds = Set(found.map(\.kind))
        check(kinds.isSuperset(of: ["memory_pressure", "vm_slow_response", "local_network", "wifi_weak", "no_data"]), "incident kinds found: \(kinds.sorted())")
        check(found.first { $0.kind == "wifi_weak" }?.remoteSessionLikely == true, "remote session inferred from sustained upload")
        check(found.first { $0.kind == "memory_pressure" }?.remoteSessionLikely == false, "no session inferred when upload is idle")
        check(found.first { $0.kind == "no_data" }?.summary.contains("asleep") == true, "gap explained by the sleep event")
        check(found.first { $0.kind == "internet_path" } != nil, "internet loss reported")
        check(!kinds.contains("swap_high") && !kinds.contains("vm_cpu_limit"), "no false incidents for healthy signals")
        if let mem = found.first(where: { $0.kind == "memory_pressure" }) {
            check(abs(mem.from - (t0 + 10 * 60_000)) < 30_000 && abs(mem.to - (t0 + 14 * 60_000)) < 30_000, "incident bounds match the bad period")
        }
        let sum = Diagnostics.summary(h)
        let data = try? JSONSerialization.data(withJSONObject: sum)
        check(data != nil && ((sum["vms"] as? [[String: Any]])?.first?["pingMs"] as? [String: Any])?["peak"] as? Double == 180, "summary is valid JSON and carries ping peaks")

        let ro = try? HistoryStore(path: path, readOnly: true)
        check(ro?.load(from: t0, to: t0 + 60_000, maxPoints: nil).series["A"]?.count == 31, "read-only store reads alongside the writer")
    } else {
        check(false, "history store opens for probe tests")
    }
    for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }

    // Chronic jitter and recurring spikes, on hand-built histories.
    do {
        var h = History(from: t0, to: t0 + 120 * 60_000)
        h.bucketMs = 60_000
        h.link = (0..<120).map { LinkPoint(t: t0 + Int64($0) * 60_000, kind: "wifi", interface: "en1", rssi: -52, noise: -94, txRate: 1700, channel: 36, speed: nil) }
        h.probes[ProbeTarget.gateway] = (0..<120).map { ProbePoint(t: t0 + Int64($0) * 60_000, rtt: 15, rttMax: $0 % 3 == 0 ? 90 : 20, sent: 6, lost: 0) }
        // Internet: flat, with eight isolated one-minute spikes.
        h.probes[ProbeTarget.internet] = (0..<120).map { ProbePoint(t: t0 + Int64($0) * 60_000, rtt: 8, rttMax: $0 % 15 == 7 ? 230 : 9, sent: 6, lost: 0) }
        let found = Diagnostics.incidents(h)
        let jitter = found.first { $0.kind == "local_network_jitter" }
        check(jitter != nil && jitter!.summary.contains("not the cause"), "steady router jitter with a strong signal is reported, and signal is ruled out")
        check(found.filter { $0.kind == "local_network" }.isEmpty, "the regular 90 ms peaks are not listed again one by one")
        let spikes = found.filter { $0.kind == "internet_path" }
        check(spikes.count == 1 && spikes[0].occurrences == 8, "eight brief internet spikes fold into one entry with a count")
        check(found.first?.kind == "local_network_jitter", "chronic jitter ranks first")

        var healthy = History(from: t0, to: t0 + 60 * 60_000)
        healthy.bucketMs = 60_000
        healthy.probes[ProbeTarget.gateway] = (0..<60).map { ProbePoint(t: t0 + Int64($0) * 60_000, rtt: 1.2, rttMax: 3, sent: 6, lost: 0) }
        check(Diagnostics.incidents(healthy).isEmpty, "a healthy local network raises nothing")
    }

    var seeded = EventDetector()
    seeded.seed(pressure: 1, swapHigh: true)
    do {
        let host = HostSummary(totalMemory: 48 * gb, hostUsed: 40 * gb, hostOtherUsed: 24 * gb, freeNow: 8 * gb, allocatable: 8 * gb, pressure: .warning,
                               swapUsed: 3600 * (gb / 1000), swapTotal: 4 * gb, physicalCores: 14, allocatedCores: 6, macOSRunning: 1)
        let snap = Snapshot(timestamp: start, intervalSeconds: 2, rows: [], host: host, notices: [])
        check(seeded.ingest(snap).isEmpty, "a restart while pressure and swap are still high does not log them again")
    }

    var det = EventDetector()
    func probe(_ kind: String, _ rssi: Int?) -> ProbeResult {
        var l = LinkInfo(kind: kind, interface: "en1"); l.rssi = rssi
        return ProbeResult(timestamp: start, vmPing: [:], gatewayTried: true, gatewayMs: 3, internetTried: true, internetMs: 20, link: l)
    }
    check(det.ingest(probe("wifi", -55)).isEmpty && det.ingest(probe("wifi", -80)).isEmpty, "one weak reading is not an event")
    check(det.ingest(probe("wifi", -81)).map(\.kind) == ["link_weak"], "two weak readings raise an event")
    check(det.ingest(probe("wifi", -73)).isEmpty, "needs a 5 dB margin to clear")
    check(det.ingest(probe("wifi", -60)).map(\.kind) == ["link_recovered"], "recovery detected")
    check(det.ingest(probe("ethernet", nil)).map(\.kind) == ["link_changed"], "link type change detected")
    check(det.ingest(probe("none", nil)).map(\.kind) == ["link_down"], "link loss detected")
}

print("\(checks - failures)/\(checks) checks passed")
exit(failures == 0 ? 0 : 1)
