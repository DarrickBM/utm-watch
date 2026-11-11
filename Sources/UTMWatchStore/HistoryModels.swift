import Foundation
import UTMWatchCore

public struct VMInfo: Equatable {
    public var key: String
    public var name: String
    public var backend: String
    public init(key: String, name: String, backend: String) { self.key = key; self.name = name; self.backend = backend }
}

/// A VM's configured limits from a point in time onwards.
public struct VMConfig: Equatable {
    public var ts: Int64
    public var cores: Int?
    public var memBytes: Double?
    public init(ts: Int64, cores: Int?, memBytes: Double?) { self.ts = ts; self.cores = cores; self.memBytes = memBytes }
}

/// One point of a VM's history: a raw sample, or the average (and peak) of a bucket of samples.
public struct VMPoint: Equatable {
    public var t: Int64            // milliseconds since 1970
    public var cpu: Double?        // cores
    public var cpuMax: Double?
    public var mem: Double?        // bytes
    public var down: Double?       // bytes per second
    public var downMax: Double?
    public var up: Double?
    public var upMax: Double?
    public var downTotal: Double?  // bytes since the VM's interface came up
    public var upTotal: Double?
    public var diskRead: Double?   // bytes per second
    public var diskWrite: Double?

    public init(t: Int64, cpu: Double?, cpuMax: Double? = nil, mem: Double?, down: Double?, downMax: Double? = nil,
                up: Double?, upMax: Double? = nil, downTotal: Double?, upTotal: Double?, diskRead: Double? = nil, diskWrite: Double? = nil) {
        self.t = t; self.cpu = cpu; self.cpuMax = cpuMax ?? cpu; self.mem = mem
        self.down = down; self.downMax = downMax ?? down; self.up = up; self.upMax = upMax ?? up
        self.downTotal = downTotal; self.upTotal = upTotal; self.diskRead = diskRead; self.diskWrite = diskWrite
    }

    public init(row: VMRow, ts: Int64) {
        self.init(t: ts, cpu: row.cpuCores, mem: row.memoryBytes.map { Double($0) }, down: row.downRate, up: row.upRate,
                  downTotal: row.downTotal.map { Double($0) }, upTotal: row.upTotal.map { Double($0) },
                  diskRead: row.diskReadRate, diskWrite: row.diskWriteRate)
    }
}

public struct HostPoint: Equatable {
    public var t: Int64
    public var used: Double
    public var other: Double
    public var allocatable: Double
    /// 0 normal, 1 warning, 2 critical.
    public var pressure: Int
    public var swapUsed: Double
    public var swapTotal: Double
    public var cores: Int
    /// Cores busy across the whole Mac.
    public var cpu: Double?

    public init(t: Int64, used: Double, other: Double, allocatable: Double, pressure: Int, swapUsed: Double, swapTotal: Double, cores: Int, cpu: Double? = nil) {
        self.t = t; self.used = used; self.other = other; self.allocatable = allocatable
        self.pressure = pressure; self.swapUsed = swapUsed; self.swapTotal = swapTotal; self.cores = cores; self.cpu = cpu
    }

    public init(snapshot s: Snapshot) {
        self.init(t: s.timestamp.msSince1970, used: Double(s.host.hostUsed), other: Double(s.host.hostOtherUsed),
                  allocatable: Double(s.host.allocatable), pressure: HostPoint.code(s.host.pressure),
                  swapUsed: Double(s.host.swapUsed), swapTotal: Double(s.host.swapTotal), cores: s.host.allocatedCores,
                  cpu: s.host.hostCPUCores)
    }

    public static func code(_ p: MemoryPressure) -> Int {
        switch p { case .warning: return 1; case .critical: return 2; default: return 0 }
    }
}

public struct HistoryEvent: Equatable {
    public var ts: Int64
    public var kind: String
    public var vmKey: String?
    public var label: String
    /// Extra context as JSON, e.g. the busiest processes when the event fired.
    public var detail: String?
    public init(ts: Int64, kind: String, vmKey: String?, label: String, detail: String? = nil) {
        self.ts = ts; self.kind = kind; self.vmKey = vmKey; self.label = label; self.detail = detail
    }

    public static let warningKinds: Set<String> = ["pressure_warning", "pressure_critical", "swap_high", "cpu_limit", "link_weak", "link_down", "sleep"]
    public var isWarning: Bool { HistoryEvent.warningKinds.contains(kind) }
}

/// Ping results for one target: a single probe, or a bucket of them.
public struct ProbePoint: Equatable {
    public var t: Int64
    /// Average round-trip time in ms over the replies received; nil if none came back.
    public var rtt: Double?
    public var rttMax: Double?
    public var sent: Int
    public var lost: Int
    public init(t: Int64, rtt: Double?, rttMax: Double? = nil, sent: Int = 1, lost: Int = 0) {
        self.t = t; self.rtt = rtt; self.rttMax = rttMax ?? rtt; self.sent = sent; self.lost = lost
    }
}

public struct LinkPoint: Equatable {
    public var t: Int64
    public var kind: String
    public var interface: String?
    public var rssi: Double?
    public var noise: Double?
    public var txRate: Double?
    public var channel: Int?
    public var speed: Double?
    public init(t: Int64, kind: String, interface: String?, rssi: Double?, noise: Double?, txRate: Double?, channel: Int?, speed: Double?) {
        self.t = t; self.kind = kind; self.interface = interface; self.rssi = rssi; self.noise = noise
        self.txRate = txRate; self.channel = channel; self.speed = speed
    }
    public init(_ l: LinkInfo, ts: Int64) {
        self.init(t: ts, kind: l.kind, interface: l.interface, rssi: l.rssi.map { Double($0) }, noise: l.noise.map { Double($0) },
                  txRate: l.txRateMbps, channel: l.channel, speed: l.speedMbps)
    }
}

/// Probe target names used in storage: "gateway", "internet", or "vm:<key>".
public enum ProbeTarget {
    public static let gateway = "gateway"
    public static let internet = "internet"
    public static func vm(_ key: String) -> String { "vm:" + key }
    /// One internet server by address, e.g. "anchor:1.1.1.1".
    public static func anchor(_ address: String) -> String { anchorPrefix + address }
    public static let anchorPrefix = "anchor:"
}

/// Everything the detail window needs for one time frame.
public struct History: Equatable {
    public var from: Int64
    public var to: Int64
    public var vms: [VMInfo] = []
    public var series: [String: [VMPoint]] = [:]
    public var host: [HostPoint] = []
    public var events: [HistoryEvent] = []
    public var configs: [String: [VMConfig]] = [:]
    /// Ping series keyed by `ProbeTarget` name.
    public var probes: [String: [ProbePoint]] = [:]
    public var link: [LinkPoint] = []
    /// Width of one point in milliseconds (the sample interval for raw data).
    public var bucketMs: Double = 2000

    public init(from: Int64, to: Int64) { self.from = from; self.to = to }

    /// The limits that applied to a VM at time `t`.
    public func config(for key: String, at t: Int64) -> VMConfig? {
        guard let list = configs[key], !list.isEmpty else { return nil }
        return list.last(where: { $0.ts <= t }) ?? list.first
    }
}

public extension Date {
    var msSince1970: Int64 { Int64((timeIntervalSince1970 * 1000).rounded()) }
    init(ms: Int64) { self.init(timeIntervalSince1970: Double(ms) / 1000) }
}
