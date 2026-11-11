import Foundation

public enum VMBackend: String, Codable, Equatable {
    case apple = "Apple"
    case qemu = "QEMU"
    case unknown = "?"
}

public enum VMStatus: String, Codable, Equatable {
    case stopped, starting, running, pausing, paused, resuming, stopping, unknown

    /// Maps a UTM AppleScript `status` enumerator to our status.
    public init(utmStatus: String) {
        switch utmStatus.lowercased() {
        case "stopped": self = .stopped
        case "starting": self = .starting
        case "started": self = .running
        case "pausing": self = .pausing
        case "paused": self = .paused
        case "resuming": self = .resuming
        case "stopping": self = .stopping
        default: self = .unknown
        }
    }

    public var isActive: Bool { self != .stopped && self != .unknown }
}

public enum MemoryPressure: String, Codable, Equatable {
    case normal, warning, critical, unknown
}

public struct VMRow: Codable, Equatable {
    /// Stable identity: UTM UUID when known, otherwise "pid:<n>".
    public var id: String
    public var name: String
    public var backend: VMBackend
    public var status: VMStatus
    public var pid: Int32?
    /// False for VM processes we could not link to a UTM bundle.
    public var identified: Bool
    public var isMacOS: Bool
    /// CPU in cores (1.0 = one core fully busy). nil until two samples exist.
    public var cpuCores: Double?
    public var cpuAllocated: Int?
    /// Physical footprint (includes compressed pages), like Activity Monitor's Memory column.
    public var memoryBytes: UInt64?
    public var memoryAllocatedBytes: UInt64?
    public var interface: String?
    /// Bytes per second as seen by the guest: down = into the VM, up = out of the VM.
    public var downRate: Double?
    public var upRate: Double?
    public var downTotal: UInt64?
    public var upTotal: UInt64?
    /// Bytes per second the VM process reads from and writes to disk.
    public var diskReadRate: Double? = nil
    public var diskWriteRate: Double? = nil
    /// The part of `memoryBytes` that is in physical RAM right now. The rest has been compressed or swapped by the Mac.
    public var residentBytes: UInt64? = nil

    public init(id: String, name: String, backend: VMBackend, status: VMStatus, pid: Int32? = nil,
                identified: Bool, isMacOS: Bool = false, cpuCores: Double? = nil, cpuAllocated: Int? = nil,
                memoryBytes: UInt64? = nil, memoryAllocatedBytes: UInt64? = nil, interface: String? = nil,
                downRate: Double? = nil, upRate: Double? = nil, downTotal: UInt64? = nil, upTotal: UInt64? = nil) {
        self.id = id; self.name = name; self.backend = backend; self.status = status; self.pid = pid
        self.identified = identified; self.isMacOS = isMacOS; self.cpuCores = cpuCores; self.cpuAllocated = cpuAllocated
        self.memoryBytes = memoryBytes; self.memoryAllocatedBytes = memoryAllocatedBytes; self.interface = interface
        self.downRate = downRate; self.upRate = upRate; self.downTotal = downTotal; self.upTotal = upTotal
    }
}

public struct HostSummary: Codable, Equatable {
    public var totalMemory: UInt64
    /// Activity Monitor "Memory Used": app memory + wired + compressed.
    public var hostUsed: UInt64
    /// hostUsed minus the footprint of all VM processes: what macOS and your own apps take.
    public var hostOtherUsed: UInt64
    /// totalMemory - hostUsed.
    public var freeNow: UInt64
    /// totalMemory - hostOtherUsed - configured memory of running VMs.
    public var allocatable: UInt64
    public var pressure: MemoryPressure
    public var swapUsed: UInt64
    public var swapTotal: UInt64
    public var physicalCores: Int
    public var allocatedCores: Int
    public var macOSRunning: Int
    public var macOSLimit: Int
    /// Cores busy across the whole Mac (all processes); nil until two samples exist.
    public var hostCPUCores: Double? = nil

    public var overcommitted: Bool { allocatedCores > physicalCores }

    public init(totalMemory: UInt64, hostUsed: UInt64, hostOtherUsed: UInt64, freeNow: UInt64, allocatable: UInt64,
                pressure: MemoryPressure, swapUsed: UInt64, swapTotal: UInt64, physicalCores: Int, allocatedCores: Int,
                macOSRunning: Int, macOSLimit: Int = 2) {
        self.totalMemory = totalMemory; self.hostUsed = hostUsed; self.hostOtherUsed = hostOtherUsed
        self.freeNow = freeNow; self.allocatable = allocatable; self.pressure = pressure
        self.swapUsed = swapUsed; self.swapTotal = swapTotal; self.physicalCores = physicalCores
        self.allocatedCores = allocatedCores; self.macOSRunning = macOSRunning; self.macOSLimit = macOSLimit
    }

    /// Pure footer math, kept separate so it can be unit tested.
    public static func compute(totalMemory: UInt64, hostUsed: UInt64, vmFootprints: UInt64, runningAllocated: UInt64,
                               pressure: MemoryPressure, swapUsed: UInt64, swapTotal: UInt64, physicalCores: Int,
                               allocatedCores: Int, macOSRunning: Int) -> HostSummary {
        let other = hostUsed > vmFootprints ? hostUsed - vmFootprints : 0
        let free = totalMemory > hostUsed ? totalMemory - hostUsed : 0
        let committed = other &+ runningAllocated
        let allocatable = totalMemory > committed ? totalMemory - committed : 0
        return HostSummary(totalMemory: totalMemory, hostUsed: hostUsed, hostOtherUsed: other, freeNow: free,
                           allocatable: allocatable, pressure: pressure, swapUsed: swapUsed, swapTotal: swapTotal,
                           physicalCores: physicalCores, allocatedCores: allocatedCores, macOSRunning: macOSRunning)
    }
}

public struct Snapshot: Codable, Equatable {
    public var timestamp: Date
    public var intervalSeconds: Double
    public var rows: [VMRow]
    public var host: HostSummary
    /// Human-readable degradation notices (e.g. UTM automation denied).
    public var notices: [String]

    public init(timestamp: Date, intervalSeconds: Double, rows: [VMRow], host: HostSummary, notices: [String]) {
        self.timestamp = timestamp; self.intervalSeconds = intervalSeconds; self.rows = rows; self.host = host; self.notices = notices
    }
}

public enum RefreshInterval: Int, CaseIterable, Codable {
    case one = 1, two = 2, five = 5
    public var seconds: Double { Double(rawValue) }
}
