// Minimal self-contained checks for the pure logic in UTMWatchCore.
// Run with `swift run selftest`; exits non-zero on the first group with failures.
import Foundation
import UTMWatchCore
import UTMWatchFleet
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
    check(ProcessVMMatcher.otherApp(fromOpenPath: "/Users/d/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw") == "Docker Desktop", "Docker Desktop's disk names its VM")
    check(ProcessVMMatcher.otherApp(fromOpenPath: "/Users/d/.colima/_lima/colima/diffdisk") == "Colima", "Colima wins over the Lima folder it nests")
    check(ProcessVMMatcher.otherApp(fromOpenPaths: ["/dev/null", "/Users/d/.tart/vms/sonoma/disk.img"]) == "Tart", "other app found among open paths")
    check(ProcessVMMatcher.otherApp(fromOpenPath: "/Users/d/Projects/x/main.swift") == nil, "ordinary file names no app")

    check(ProcessScanner.isVMExecutable("/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine"), "Apple VM helper detected")
    check(ProcessScanner.isVMExecutable("/Applications/UTM.app/Contents/Frameworks/qemu-system-aarch64"), "QEMU detected")
    check(ProcessScanner.isVMExecutable("/Applications/UTM.app/Contents/XPCServices/QEMUHelper.xpc/Contents/MacOS/QEMULauncher.app/Contents/MacOS/QEMULauncher"), "UTM QEMU launcher detected")
    check(!ProcessScanner.isVMExecutable("/Applications/UTM.app/Contents/XPCServices/QEMUHelper.xpc/Contents/MacOS/QEMUHelper"), "UTM's QEMUHelper service is not the VM")
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
    let withSettings = try? UTMScripting.parse(#"[{"id":"B390","name":"macOS 26","status":"started","backend":"apple","cpuCores":6,"memoryMB":8192,"macs":["E6:88:A0:15:2A:6C"]}]"#)
    check(withSettings?.first?.cpuCores == 6 && withSettings?.first?.memoryBytes == 8192 * 1024 * 1024 && withSettings?.first?.macs == ["E6:88:A0:15:2A:6C"]
          && list?.first?.cpuCores == nil && list?.first?.memoryBytes == nil, "UTM's list carries each VM's settings when UTM reports them, and reads without them")
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
        rows[0].residentBytes = 3 * gb
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
        check(raw.series["A"]?.first?.res == Double(3 * gb) && raw.series["B"]?.first?.res == nil, "memory in RAM stored when measured, absent otherwise")
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
        a.diskUsedBytes = (i < 600 ? 50 : 56) * gb; a.diskSizeBytes = 60 * gb
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
        check(h.series["A"]?.first?.diskUsed == Double(50 * gb) && h.series["A"]?.last?.diskFraction.map { abs($0 - 56.0 / 60) < 0.001 } == true, "disk usage stored, raw and rolled up")
        var diskDet = EventDetector()
        let diskEvents = snaps.flatMap { diskDet.ingest($0) }.filter { $0.kind.hasPrefix("disk_") }
        check(diskEvents.map(\.kind) == ["disk_high"] && diskEvents.first?.label == "macOS 26 disk 90% full" && diskEvents.first?.isWarning == true, "one warning when a disk passes 90%")
        var diskSeeded = EventDetector()
        diskSeeded.seed(diskHigh: ["A"])
        check(!diskSeeded.ingest(snaps[snaps.count - 1]).contains { $0.kind == "disk_high" }, "a restart while a disk is still nearly full does not log it again")

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

do {
    check(VMName.clean("  Acme   Corp \n") == "Acme Corp", "name is trimmed and spaces collapsed")
    check(VMName.clean(" \t\n ") == "", "a blank name is empty, meaning the UTM name")
    check(VMName.clean("Acme\nCorp\u{07}") == "Acme Corp", "line breaks and control characters become spaces")
    check(VMName.clean(String(repeating: "a", count: 100)).count == VMName.maxLength, "name is cut at the limit")
    check(VMName.clean(String(repeating: "a", count: 39) + "  b") == String(repeating: "a", count: 39), "no trailing space after the cut")
    check(VMName.clean("客户 👨‍👩‍👧 甲") == "客户 👨‍👩‍👧 甲", "non-Latin names and emoji survive")
}

do {
    check(AppVersion.isNewer("0.10.0", than: "0.9.3"), "versions compare number by number")
    check(!AppVersion.isNewer("0.4.0", than: "0.4.0") && !AppVersion.isNewer("0.3.9", than: "0.4"), "same or older is not newer")
    check(AppVersion.isNewer("0.4.1", than: "0.4"), "a missing part counts as zero")
    check(!AppVersion.isNewer("dev", than: "0.4.0") && !AppVersion.isNewer("0.5.0", than: "dev"), "an unreadable version is never newer")
    let json = """
    {"tag_name":"v0.5.0","assets":[
      {"name":"SHA256SUMS.txt","browser_download_url":"https://example.com/SHA256SUMS.txt"},
      {"name":"UTMWatch-0.5.0-macos-arm64.dmg","browser_download_url":"https://example.com/a.dmg"},
      {"name":"UTMWatch-0.5.0-macos-arm64.zip","browser_download_url":"https://example.com/UTMWatch-0.5.0-macos-arm64.zip"}]}
    """
    let r = ReleaseInfo.parse(Data(json.utf8))
    check(r?.version == "0.5.0" && r?.appZip.lastPathComponent == "UTMWatch-0.5.0-macos-arm64.zip", "release parsed: version and app zip")
    check(ReleaseInfo.parse(Data(#"{"tag_name":"v0.5.0","assets":[]}"#.utf8)) == nil, "a release without the app zip is ignored")
    check(ReleaseInfo.parse(Data(json.replacingOccurrences(of: "https://example.com/UTM", with: "http://example.com/UTM").utf8)) == nil, "a download that is not https is ignored")
    check(AppVersion.isNewer("0.6.0", beta: 6, than: "0.6.0", beta: 5) && !AppVersion.isNewer("0.6.0", beta: 5, than: "0.6.0", beta: 5), "a later beta is newer, the same beta is not")
    check(AppVersion.isNewer("0.6.0", beta: nil, than: "0.6.0", beta: 5) && !AppVersion.isNewer("0.6.0", beta: 9, than: "0.6.0", beta: nil), "the final release follows its betas")
    check(AppVersion.isNewer("0.6.0", beta: 1, than: "0.5.0", beta: nil) && !AppVersion.isNewer("0.6.0", beta: 1, than: "0.6.1", beta: nil), "the version outranks the beta number")
    func entry(_ tag: String, draft: Bool = false) -> String {
        #"{"tag_name":"\#(tag)","draft":\#(draft),"prerelease":\#(tag.contains("-")),"assets":[{"name":"SHA256SUMS.txt","browser_download_url":"https://example.com/\#(tag)/SHA256SUMS.txt"},{"name":"UTMWatch-0.6.0-macos-arm64.zip","browser_download_url":"https://example.com/\#(tag)/UTMWatch-0.6.0-macos-arm64.zip"}]}"#
    }
    let list = Data(("[" + [entry("v0.6.0-beta.4"), entry("v0.6.0-beta.10"), entry("v0.6.0-beta.9"), entry("v0.7.0-beta.1", draft: true), entry("v0.6.0-rc.1"), entry("v0.5.0")].joined(separator: ",") + "]").utf8)
    let newestBeta = ReleaseInfo.newest(inList: list, includeBetas: true)
    check(newestBeta?.version == "0.6.0" && newestBeta?.beta == 10 && newestBeta?.label == "0.6.0 beta 10", "beta channel: the highest beta wins, drafts and unknown kinds are skipped")
    check(newestBeta?.appZip.absoluteString.contains("v0.6.0-beta.10") == true, "beta channel: the download is that beta's own file")
    check(ReleaseInfo.newest(inList: list, includeBetas: false)?.label == "0.5.0", "without betas the list gives the newest final release")
    let withFinal = Data(("[" + [entry("v0.6.0-beta.10"), entry("v0.6.0")].joined(separator: ",") + "]").utf8)
    check(ReleaseInfo.newest(inList: withFinal, includeBetas: true)?.beta == nil, "beta channel: the final release outranks its betas")
    check(r?.beta == nil && ReleaseInfo.parse(Data(entry("v0.6.0-beta.0").utf8)) == nil, "a final release has no beta number; beta 0 is not a release")
    let sums = String(repeating: "a", count: 64) + "  UTMWatch-0.5.0-macos-arm64.dmg\n" + String(repeating: "B", count: 64) + "  UTMWatch-0.5.0-macos-arm64.zip\n"
    check(ReleaseInfo.checksum(for: "UTMWatch-0.5.0-macos-arm64.zip", in: sums) == String(repeating: "b", count: 64), "checksum found by file name")
    check(ReleaseInfo.checksum(for: "other.zip", in: sums) == nil, "no checksum for an unlisted file")
}

// MARK: Fleet hub
do {
    check(SHA256.hex(Array("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "SHA-256 of a short message")
    check(SHA256.hex(Array(String(repeating: "a", count: 200).utf8)) == "c2a908d98f5df987ade41b5fce213067efbcc21ef2240212a41e54b5e7c28ae5", "SHA-256 across several blocks")

    let dir = NSTemporaryDirectory() + "utmwatch-fleet-\(ProcessInfo.processInfo.processIdentifier)/"
    try? FileManager.default.removeItem(atPath: dir)
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let gb: UInt64 = 1 << 30
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let t0 = start.msSince1970, t1 = t0 + 600_000
    func snap(_ i: Int, cpu: Double = 1.0, bRunning: Bool = true) -> Snapshot {
        var rows = [VMRow(id: "/Users/me/A.utm", name: "macOS 26", backend: .apple, status: .running, pid: 10, identified: true, isMacOS: true,
                          cpuCores: cpu + Double(i % 5) * 0.1, cpuAllocated: 6, memoryBytes: 7 * gb, memoryAllocatedBytes: 8 * gb,
                          downRate: 1000, upRate: 500, downTotal: UInt64(i) * 2000, upTotal: UInt64(i) * 1000)]
        rows[0].residentBytes = 3 * gb
        rows[0].diskUsedBytes = 50 * gb + UInt64(i) * 1_000_000; rows[0].diskSizeBytes = 60 * gb
        if bRunning {
            rows.append(VMRow(id: "/Users/me/B.utm", name: "Build box", backend: .qemu, status: .running, pid: 11, identified: true,
                              cpuCores: 0.5, cpuAllocated: 4, memoryBytes: 2 * gb, memoryAllocatedBytes: i < 100 ? 4 * gb : 8 * gb))
        }
        let host = HostSummary(totalMemory: 48 * gb, hostUsed: 40 * gb, hostOtherUsed: 24 * gb, freeNow: 8 * gb, allocatable: 8 * gb,
                               pressure: i % 90 == 7 ? .warning : .normal, swapUsed: gb, swapTotal: 4 * gb, physicalCores: 14, allocatedCores: 10, macOSRunning: 1)
        return Snapshot(timestamp: start.addingTimeInterval(Double(i) * 2), intervalSeconds: 2, rows: rows, host: host, notices: [])
    }
    func probe(_ i: Int) -> ProbeResult {
        var link = LinkInfo(kind: "wifi", interface: "en1"); link.rssi = -60 - i % 7; link.noise = -90; link.txRateMbps = 600; link.channel = 44
        return ProbeResult(timestamp: start.addingTimeInterval(Double(i) * 10 + 1), vmPing: ["/Users/me/A.utm": 0.4 + Double(i % 3), "/Users/me/B.utm": i % 9 == 0 ? nil : 0.7],
                           gatewayTried: true, gatewayMs: 2.5, internetTried: true, internetMs: 14, link: link, anchorMs: ["1.1.1.1": 14, "223.5.5.5": nil])
    }
    /// Uploads everything a local store holds, the way the agent does: slice by slice until nothing is left.
    func drain(_ local: HistoryStore, to service: HubService, token: String, from cursor: UploadCursor, sliceMs: Int64 = 300_000, twice: Bool = false) -> UploadCursor {
        var c = cursor
        for _ in 0..<1000 {
            var batch = local.exportBatch(after: c, limitMs: sliceMs)
            if batch.hasNoHistory { break }
            batch.sentAt = t1; batch.appVersion = "9.9.9"
            for _ in 0..<(twice ? 2 : 1) {
                let r = service.handle(HubRequest(method: "POST", path: "/v1/ingest", bearer: token, body: FleetAPI.encode(batch)))
                guard r.status == 200, let reply = FleetAPI.decode(FleetReply<IngestReply>.self, from: r.body)?.data else { check(false, "ingest accepted"); return c }
                c = reply.accepted
            }
        }
        return c
    }
    func get<T: Codable>(_ service: HubService, _ path: String, _ query: [String: String] = [:], token: String?, as: T.Type) -> (Int, T?) {
        let r = service.handle(HubRequest(method: "GET", path: path, query: query, bearer: token))
        return (r.status, FleetAPI.decode(FleetReply<T>.self, from: r.body)?.data)
    }

    if let hub = try? HubStore(path: dir + "hub.sqlite"), let macA = try? HistoryStore(path: dir + "a.sqlite"), let macB = try? HistoryStore(path: dir + "b.sqlite") {
        var clock = t1
        let service = HubService(store: hub, now: { clock })
        let reader = hub.createReaderToken(label: "test", now: clock)

        // Enrolment
        func enroll(_ uuid: String, _ name: String, code: String) -> (Int, String?) {
            let r = service.handle(HubRequest(method: "POST", path: "/v1/enroll", bearer: code,
                                              body: FleetAPI.encode(EnrollRequest(hostUUID: uuid, name: name, appVersion: "9.9.9"))))
            return (r.status, FleetAPI.decode(FleetReply<EnrollReply>.self, from: r.body)?.data?.hostToken)
        }
        let code = hub.createEnrollToken(now: clock)
        let (s1, tokenA) = enroll("uuid-a", "Mini A", code: code)
        check(s1 == 200 && tokenA != nil, "a Mac enrols with a pairing code")
        check(enroll("uuid-x", "Mini X", code: code).0 == 401, "a pairing code works once")
        check(enroll("uuid-x", "Mini X", code: "e_wrong").0 == 401, "an unknown pairing code is refused")
        let expired = hub.createEnrollToken(now: clock - 2 * 86_400_000)
        check(enroll("uuid-x", "Mini X", code: expired).0 == 401, "an expired pairing code is refused")
        let tokenB = enroll("uuid-b", "Mini B", code: hub.createEnrollToken(now: clock)).1 ?? ""

        // Mac A: ten minutes of history written the way the app writes it, with one late event.
        let snaps = (0..<300).map { snap($0, bRunning: !(120..<150).contains($0)) }
        let probes = (0..<60).map(probe)
        macA.write(snapshots: Array(snaps[0..<150]), events: [HistoryEvent(ts: t0 + 5000, kind: "vm_started", vmKey: "/Users/me/B.utm", label: "Build box started")],
                   probes: Array(probes[0..<30]))
        var cursorA = drain(macA, to: service, token: tokenA ?? "", from: macA.uploadCursor(startingAt: t0), sliceMs: 70_000, twice: true)
        macA.write(snapshots: Array(snaps[150...]), events: [HistoryEvent(ts: t0 + 9000, kind: "cpu_limit", vmKey: nil, label: "late, with an old time", detail: #"{"top":[]}"#)],
                   probes: Array(probes[30...]))
        cursorA = drain(macA, to: service, token: tokenA ?? "", from: cursorA, sliceMs: 70_000)
        // Mac B: the same VM paths, different numbers.
        macB.write(snapshots: (0..<300).map { snap($0, cpu: 3.0) }, probes: probes)
        _ = drain(macB, to: service, token: tokenB, from: macB.uploadCursor(startingAt: t0))

        let localRaw = macA.load(from: t0, to: t1, maxPoints: nil)
        let hubRaw = hub.load(hostUUID: "uuid-a", from: t0, to: t1, maxPoints: nil)
        check(localRaw.series["/Users/me/A.utm"]?.count == 300 && localRaw.probes.count == 6, "the local history under test is not empty")
        check(hubRaw == localRaw, "the hub returns a Mac's raw history exactly as that Mac reads it")
        check(hubRaw?.series["/Users/me/A.utm"]?.last?.diskUsed == Double(50 * gb + 299_000_000) && hubRaw?.series["/Users/me/B.utm"]?.last?.diskUsed == nil,
              "disk usage reaches the hub for the VMs that have it")
        check(hub.load(hostUUID: "uuid-a", from: t0, to: t1, maxPoints: 50) == macA.load(from: t0, to: t1, maxPoints: 50), "bucketed history matches too")
        let localLong = macA.load(from: t0 - 3 * 3600_000, to: t1, maxPoints: 600)
        check(localLong.series["/Users/me/A.utm"]?.count == 9, "the local store rolled up nine completed minutes")
        check(hub.load(hostUUID: "uuid-a", from: t0 - 3 * 3600_000, to: t1, maxPoints: 600) == localLong,
              "rollups match after an upload in slices that end mid-minute")
        check(hubRaw?.events.map(\.kind) == ["vm_started", "cpu_limit"], "an event written late with an old time still reaches the hub")
        check(hubRaw?.events.count == 2, "sending a batch twice stores nothing twice")
        check(hubRaw?.configs["/Users/me/B.utm"]?.count == 2, "a changed limit is kept alongside the earlier one")

        let hubB = hub.load(hostUUID: "uuid-b", from: t0, to: t1, maxPoints: nil)
        check(hubB == macB.load(from: t0, to: t1, maxPoints: nil), "a second Mac with the same VM paths keeps its own history")
        check(near(hubB?.series["/Users/me/A.utm"]?.first?.cpu ?? 0, 3.0) && near(hubRaw?.series["/Users/me/A.utm"]?.first?.cpu ?? 0, 1.0), "the two Macs' VMs are not mixed up")
        check(hub.load(hostUUID: "uuid-nobody", from: t0, to: t1, maxPoints: nil) == nil, "an unknown Mac has no history")

        // A first upload that starts part-way carries nothing older, and still carries the limit in force.
        let late = macA.exportBatch(after: macA.uploadCursor(startingAt: t0 + 300_000), limitMs: 60_000)
        check(late.host.first?.first == Double(t0 + 300_000) && late.events.isEmpty, "a first upload starts where it was told to and skips older events")
        check(late.configs.contains { $0.ts < t0 + 300_000 }, "a slice carries the limit that was already in force when it began")
        macA.setUploadCursor(cursorA)
        check(macA.uploadCursor() == cursorA && macA.exportBatch(after: cursorA).hasNoHistory, "the cursor is saved and nothing is left to send")

        // Read API
        var live = IngestBatch(cursor: cursorA)
        live.sentAt = clock - 7000; live.appVersion = "9.9.9"; live.snapshot = snaps.last; live.linkNow = probes.last?.link
        check(service.handle(HubRequest(method: "POST", path: "/v1/ingest", bearer: tokenA, body: FleetAPI.encode(live))).status == 200, "a batch with only the current state is accepted")
        clock += 90_000
        _ = service.handle(HubRequest(method: "POST", path: "/v1/ingest", bearer: tokenB, body: FleetAPI.encode(IngestBatch(cursor: UploadCursor()))))
        let (hs, hosts) = get(service, "/v1/hosts", token: reader, as: [HostStatus].self)
        check(hs == 200 && hosts?.map(\.name) == ["Mini A", "Mini B"], "the fleet lists both Macs")
        check(hosts?.first?.state == "offline" && hosts?.last?.state == "online", "a Mac silent for over a minute is offline, by the hub's clock")
        check(hosts?.first?.snapshot == snaps.last && hosts?.first?.link?.channel == 44 && hosts?.first?.skewMs == 7000, "the overview carries the latest state and the clock skew")
        let (hh, history) = get(service, "/v1/hosts/uuid-a/history", ["from": "\(t0)", "to": "\(t1)", "maxPoints": "50"], token: reader, as: History.self)
        check(hh == 200 && history == macA.load(from: t0, to: t1, maxPoints: 50), "history survives the trip through JSON unchanged")
        check(get(service, "/v1/hosts/uuid-a/history", ["from": "\(t0 - 86_400_000)", "to": "\(t1)"], token: reader, as: History.self).0 == 400, "a long frame without maxPoints is refused")
        let (_, events) = get(service, "/v1/events", token: reader, as: [FleetEvent].self)
        check(events?.count == 2 && events?.first?.hostName == "Mini A" && events?.first?.origin == "agent", "fleet events name their Mac")
        check(get(service, "/v1/events", ["after": "\(events?.first?.id ?? 0)"], token: reader, as: [FleetEvent].self).1?.count == 1, "events can be polled from the last one seen")
        check(get(service, "/v1/hosts/uuid-a/commands", token: tokenA, as: [String].self).1 == [], "the reserved command channel answers with nothing")

        // Authorization
        check(get(service, "/v1/hosts", token: nil, as: [HostStatus].self).0 == 401 && get(service, "/v1/hosts", token: tokenA, as: [HostStatus].self).0 == 401, "reading the fleet needs a reader token")
        check(service.handle(HubRequest(method: "POST", path: "/v1/ingest", bearer: reader, body: FleetAPI.encode(live))).status == 401, "a reader token cannot upload")
        check(get(service, "/v1/health", token: nil, as: [String: Bool].self).0 == 200 && get(service, "/v2/health", token: nil, as: [String: Bool].self).0 == 404, "health is open; unknown paths are not found")
        check(hub.revoke(hostUUID: "uuid-b") && !hub.revoke(hostUUID: "uuid-nobody"), "a Mac can be revoked")
        check(service.handle(HubRequest(method: "POST", path: "/v1/ingest", bearer: tokenB, body: FleetAPI.encode(live))).status == 401, "a revoked Mac can no longer upload")
        check(hub.hosts(now: clock).map(\.uuid) == ["uuid-a"], "a revoked Mac leaves the fleet list")
        // Pairing codes, the Mac's own reader token, and going offline on the timeline
        let packed = PairingCode(hub: "http://mini.local:8787", token: "e_abc", authKey: "tskey-auth-x")
        check(PairingCode(text: "  " + packed.text + "\n") == packed && PairingCode(text: "e_abc") == nil && PairingCode(text: "utmw1.!!") == nil, "a pairing code packs the hub, token and network key into one string")
        func join(_ uuid: String, view: Bool) -> EnrollReply? {
            let r = service.handle(HubRequest(method: "POST", path: "/v1/enroll", bearer: hub.createEnrollToken(now: clock, view: view),
                                              body: FleetAPI.encode(EnrollRequest(hostUUID: uuid, name: "Mini " + uuid, appVersion: "9.9.9"))))
            return FleetAPI.decode(FleetReply<EnrollReply>.self, from: r.body)?.data
        }
        // Seeing the fleet is granted by the pairing code, not by joining.
        let plain = join("uuid-e", view: false)
        check(plain?.hostToken.isEmpty == false && plain?.readerToken == nil
              && get(service, "/v1/hosts", token: plain?.hostToken, as: [HostStatus].self).0 == 401, "a Mac that joins with an ordinary code reports but cannot read the fleet")
        check(service.handle(HubRequest(method: "POST", path: "/v1/ingest", bearer: plain?.hostToken, body: FleetAPI.encode(IngestBatch(cursor: UploadCursor())))).status == 200, "and its uploads are accepted")
        let viewer = join("uuid-f", view: true)
        check(get(service, "/v1/hosts", token: viewer?.readerToken, as: [HostStatus].self).0 == 200, "a code made for viewing gives the Mac its own reader token")
        let demoted = join("uuid-f", view: false)
        check(demoted?.readerToken == nil && get(service, "/v1/hosts", token: viewer?.readerToken, as: [HostStatus].self).0 == 401, "joining again with an ordinary code withdraws the view")
        let granted = hub.grantView(hostUUID: "uuid-e", now: clock)
        check(granted != nil && get(service, "/v1/hosts", token: granted, as: [HostStatus].self).0 == 200 && hub.grantView(hostUUID: "nobody", now: clock) == nil, "the hub can give an enrolled Mac the view, and only an enrolled one")
        hub.revoke(hostUUID: "uuid-e"); hub.revoke(hostUUID: "uuid-f")

        let joinedReply = join("uuid-d", view: true)
        check(get(service, "/v1/hosts", token: joinedReply?.readerToken, as: [HostStatus].self).0 == 200, "a Mac that joins can read the fleet with its own reader token")
        _ = service.handle(HubRequest(method: "POST", path: "/v1/ingest", bearer: joinedReply?.hostToken, body: FleetAPI.encode(IngestBatch(cursor: UploadCursor()))))
        check(hub.noteOfflineChanges(now: clock).filter { $0.hostUUID == "uuid-d" }.isEmpty, "a Mac that is reporting raises nothing")
        let silent = hub.noteOfflineChanges(now: clock + 61_000).filter { $0.hostUUID == "uuid-d" }
        check(silent.map(\.kind) == ["host_offline"] && silent.first?.origin == "hub" && silent.first?.label == "Mini uuid-d stopped reporting", "a Mac that goes silent is put on the timeline by the hub")
        check(hub.noteOfflineChanges(now: clock + 70_000).isEmpty, "and only once")
        var sleepy = IngestBatch(cursor: UploadCursor())
        sleepy.sentAt = clock + 80_000; sleepy.events = [.init(ts: clock + 80_000, kind: "sleep", vmKey: nil, label: "Mac went to sleep", detail: nil)]
        clock += 80_000
        _ = service.handle(HubRequest(method: "POST", path: "/v1/ingest", bearer: joinedReply?.hostToken, body: FleetAPI.encode(sleepy)))
        check(hub.noteOfflineChanges(now: clock).filter { $0.hostUUID == "uuid-d" }.map(\.kind) == ["host_online"], "its return is noted too")
        check(hub.noteOfflineChanges(now: clock + 61_000).filter { $0.hostUUID == "uuid-d" }.map(\.kind) == ["host_asleep"]
              && hub.hosts(now: clock + 61_000).first { $0.uuid == "uuid-d" }?.state == "asleep", "a Mac that said it was going to sleep is asleep, not offline")
        hub.revoke(hostUUID: "uuid-d")
        check(get(service, "/v1/hosts", token: joinedReply?.readerToken, as: [HostStatus].self).0 == 401, "revoking a Mac takes away its view of the fleet")

        let (s2, tokenA2) = enroll("uuid-a", "Mini A renamed", code: hub.createEnrollToken(now: clock))
        check(s2 == 200 && hub.hostID(forToken: tokenA ?? "") == nil && hub.hostID(forToken: tokenA2 ?? "") != nil, "enrolling again replaces the Mac's token")
        check(hub.load(hostUUID: "uuid-a", from: t0, to: t1, maxPoints: nil) == localRaw && hub.hosts(now: clock).first?.name == "Mini A renamed", "and keeps its history under the new name")

        // The agent: uploads in rounds, survives an outage, and carries only recent history on its first upload.
        if let macC = try? HistoryStore(path: dir + "c.sqlite") {
            let tokenC = enroll("uuid-c", "Mini C", code: hub.createEnrollToken(now: clock)).1 ?? ""
            let transport = InProcessTransport(service: service)
            var agentClock = t0 + 400_000
            let agent = Uploader(store: macC, client: HubClient(baseURL: "http://hub.test", transport: transport), token: tokenC, appVersion: "9.9.9",
                                 backfillMs: 200_000, sliceMs: 45_000, now: { agentClock })
            var seen: [Uploader.State] = []
            agent.onStatus = { seen.append($0.state) }
            macC.write(snapshots: (0..<200).map { snap($0) }, probes: (0..<40).map(probe))
            agent.setLive(snapshot: snap(199))
            check(agent.runOnce().state == .upToDate, "the first round sends everything it should")
            let firstC = hub.load(hostUUID: "uuid-c", from: t0, to: t1, maxPoints: nil)
            check(firstC?.host.first?.t == t0 + 200_000 && firstC?.host.count == 100, "a first upload carries the recent history only, not everything on the Mac")
            check(hub.hosts(now: clock).first { $0.uuid == "uuid-c" }?.snapshot == snap(199), "each upload carries the Mac's current state")

            transport.reachable = false
            macC.write(snapshots: (200..<260).map { snap($0) }, probes: (40..<52).map(probe))
            agentClock += 120_000
            check(agent.runOnce().state == .unreachable && macC.uploadCursor()?.sampleTs == t0 + 398_000, "while the hub is down nothing is lost and the cursor stays put")
            macC.write(snapshots: (260..<300).map { snap($0) }, probes: (52..<60).map(probe))
            transport.reachable = true
            agentClock += 80_000
            check(agent.runOnce().state == .upToDate, "when the hub is back the Mac catches up")
            check(hub.load(hostUUID: "uuid-c", from: t0 + 200_000, to: t1, maxPoints: nil) == macC.load(from: t0 + 200_000, to: t1, maxPoints: nil),
                  "after an outage the hub holds the same history as the Mac, with no gap")
            check(agent.runOnce(maxSlices: 1).state == .upToDate && seen == [.upToDate, .unreachable, .upToDate], "status changes are reported once each")

            hub.revoke(hostUUID: "uuid-c")
            var refused = false
            if case .rejected = agent.runOnce().state { refused = true }
            check(refused, "a revoked Mac is told it was refused")
            macC.clear()
            check(macC.uploadCursor() == nil, "clearing local history resets the upload position")
        } else {
            check(false, "agent store opens")
        }

        // Bad input and retention
        var future = IngestBatch(cursor: UploadCursor())
        future.host = [[Double(clock + 3600_000), 1, 1, 1, 0, 0, 0, 4, 1], [1e300, 1, 1, 1, 0, 0, 0, 4, 1], [1]]
        future.samples = [[5, Double(t0), 1, 1, 1, 1, 1, 1, 1, 1, 1]]
        check(service.handle(HubRequest(method: "POST", path: "/v1/ingest", bearer: tokenA2, body: FleetAPI.encode(future))).status == 200, "an upload with unusable rows is still accepted")
        check(hub.load(hostUUID: "uuid-a", from: t0, to: clock + 2 * 3600_000, maxPoints: nil)?.host.count == 300, "rows from the future, out of range or malformed are dropped")
        check(service.handle(HubRequest(method: "POST", path: "/v1/ingest", bearer: tokenA2, body: Data("{nonsense".utf8))).status == 400, "an unreadable upload is a bad request")
        hub.prune(rawOlderThan: t0 + 300_000, rollupsOlderThan: t0 - 1)
        check(hub.load(hostUUID: "uuid-a", from: t0, to: t1, maxPoints: nil)?.series["/Users/me/A.utm"]?.count == 150, "pruning removes old raw samples")
        check(hub.load(hostUUID: "uuid-a", from: t0 - 3 * 3600_000, to: t1, maxPoints: 600)?.series["/Users/me/A.utm"]?.count == 9, "and keeps the rollups for longer")
    } else {
        check(false, "hub and local stores open")
    }
    try? FileManager.default.removeItem(atPath: dir)
}

print("\(checks - failures)/\(checks) checks passed")
exit(failures == 0 ? 0 : 1)
