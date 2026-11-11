import CSysShim
import Foundation

public struct HostMemory: Equatable {
    public var total: UInt64
    /// App memory (internal - purgeable) + wired + compressed: Activity Monitor's "Memory Used".
    public var used: UInt64
    public var appMemory: UInt64
    public var wired: UInt64
    public var compressed: UInt64
}

public enum HostStats {
    public static let totalMemory: UInt64 = Sysctl.uint64("hw.memsize") ?? 0
    public static let physicalCores: Int = Int(Sysctl.int32("hw.ncpu") ?? 0)

    public static func memory() -> HostMemory? {
        var s = shim_vm_stats()
        guard shim_host_memory(&s) == 0 else { return nil }
        let page = s.page_size
        let app = (s.internal_pages > s.purgeable_pages ? s.internal_pages - s.purgeable_pages : 0) * page
        let wired = s.wired_pages * page
        let compressed = s.compressor_pages * page
        return HostMemory(total: totalMemory, used: app + wired + compressed, appMemory: app, wired: wired, compressed: compressed)
    }

    public static func pressure() -> MemoryPressure {
        switch Sysctl.int32("kern.memorystatus_vm_pressure_level") {
        case 1: return .normal
        case 2: return .warning
        case 4: return .critical
        default: return .unknown
        }
    }

    public static func swap() -> (used: UInt64, total: UInt64) {
        var total: UInt64 = 0, used: UInt64 = 0
        guard shim_swap_usage(&total, &used) == 0 else { return (0, 0) }
        return (used, total)
    }
}
