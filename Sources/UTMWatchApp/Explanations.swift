import Foundation
import UTMWatchCore

/// Plain-language explanations for values that are outside their normal range.
/// Each returns nil when the value is normal, so the same functions decide whether to show a warning mark.
enum Explain {
    static func pressure(_ host: HostSummary) -> String? {
        switch host.pressure {
        case .warning:
            return "Memory pressure: Warning. macOS is running short of free memory and is compressing and swapping to keep up. VMs and apps may feel slow. Closing apps or shutting down a VM relieves it."
        case .critical:
            return "Memory pressure: Critical. macOS is nearly out of memory and is swapping heavily. Expect stalls. Shut down a VM or quit large apps now."
        default:
            return nil
        }
    }

    static func swap(_ host: HostSummary) -> String? {
        guard host.swapTotal > 0 else { return nil }
        let used = Double(host.swapUsed) / Double(host.swapTotal)
        guard used >= 0.8 else { return nil }
        return "Swap is \(Int((used * 100).rounded()))% full (\(Format.memory(host.swapUsed)) of \(Format.memory(host.swapTotal))). Memory that does not fit in RAM is being moved to disk, which is much slower. Above 80% is treated as a warning."
    }

    static func cores(_ host: HostSummary) -> String? {
        guard host.overcommitted else { return nil }
        return "Running VMs are allocated \(host.allocatedCores) cores but this Mac has \(host.physicalCores). When they are all busy they will compete for CPU time."
    }

    static func allocatable(_ host: HostSummary) -> String? {
        guard host.allocatable < 1 << 30 else { return nil }
        return "Less than 1 GB could be given to another VM right now: what macOS and your apps use, plus the memory limits of the running VMs, already adds up to nearly all of this Mac's \(Format.memory(host.totalMemory))."
    }

    static func link(_ link: LinkInfo?) -> String? {
        guard let link else { return nil }
        if link.kind == "none" { return "The Mac has no network connection. Nothing outside can reach the VMs." }
        guard link.kind == "wifi", let rssi = link.rssi, rssi <= -75 else { return nil }
        return "Wi-Fi signal is weak (\(rssi) dBm). Remote sessions to the VMs will lag or drop even though the VMs themselves are fine. Moving the Mac closer to the router, or using Ethernet, fixes it."
    }

    static func disk(_ vm: VMRow) -> String? {
        guard let fraction = vm.diskFraction, fraction >= 0.9, let used = vm.diskUsedBytes, let size = vm.diskSizeBytes else { return nil }
        return "\(vm.name)'s disk is \(Int((fraction * 100).rounded()))% full (\(Format.memoryPair(used, size))). A guest that runs out of disk space stops saving work and can fail to start. Free space inside the VM, or make its disk larger in UTM."
    }

    static func cpu(_ vm: VMRow) -> String? {
        guard let used = vm.cpuCores, let limit = vm.cpuAllocated, limit > 0, used >= 0.9 * Double(limit) else { return nil }
        return "\(vm.name) is using \(String(format: "%.1f", used)) of its \(limit) cores. It is at its CPU limit, so work inside it is waiting for processor time. Giving it more cores in UTM would help if this lasts."
    }
}
