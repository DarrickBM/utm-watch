import CSysShim
import Foundation

public struct ProcessSample: Equatable {
    public var cpuNanos: UInt64
    public var footprint: UInt64
    public var wallNanos: UInt64
    public var diskRead: UInt64
    public var diskWritten: UInt64
    /// Bytes in physical RAM right now; the rest of the footprint is compressed or swapped.
    public var resident: UInt64? = nil
    public init(cpuNanos: UInt64, footprint: UInt64, wallNanos: UInt64, diskRead: UInt64 = 0, diskWritten: UInt64 = 0) {
        self.cpuNanos = cpuNanos; self.footprint = footprint; self.wallNanos = wallNanos
        self.diskRead = diskRead; self.diskWritten = diskWritten
    }
}

public struct ProcessUsage: Equatable {
    /// nil until a previous sample exists or when the sample was discarded.
    public var cpuCores: Double?
    public var footprint: UInt64
    public var diskReadRate: Double? = nil
    public var diskWriteRate: Double? = nil
    public var resident: UInt64? = nil
}

/// Turns cumulative per-process CPU time into "cores busy" between consecutive samples.
public final class ProcessSampler {
    private var previous: [Int32: ProcessSample] = [:]

    public init() {}

    public static func read(pid: Int32, now: UInt64) -> ProcessSample? {
        var user: UInt64 = 0, system: UInt64 = 0, footprint: UInt64 = 0
        guard shim_proc_rusage(pid, &user, &system, &footprint) == 0 else { return nil }
        var read: UInt64 = 0, written: UInt64 = 0
        _ = shim_proc_diskio(pid, &read, &written)
        var sample = ProcessSample(cpuNanos: user &+ system, footprint: footprint, wallNanos: now, diskRead: read, diskWritten: written)
        var resident: UInt64 = 0
        if shim_proc_resident(pid, &resident) == 0 { sample.resident = resident }
        return sample
    }

    /// Cores busy between two samples; nil when time went backwards (pid reuse, clock issue).
    public static func cores(previous: ProcessSample, current: ProcessSample) -> Double? {
        guard current.wallNanos > previous.wallNanos, current.cpuNanos >= previous.cpuNanos else { return nil }
        let wall = Double(current.wallNanos - previous.wallNanos)
        let cpu = Double(current.cpuNanos - previous.cpuNanos)
        return cpu / wall
    }

    public func sample(pids: [Int32], now: UInt64) -> [Int32: ProcessUsage] {
        var result: [Int32: ProcessUsage] = [:]
        var next: [Int32: ProcessSample] = [:]
        for pid in pids {
            guard let cur = Self.read(pid: pid, now: now) else { continue }
            next[pid] = cur
            let cores = previous[pid].flatMap { Self.cores(previous: $0, current: cur) }
            var usage = ProcessUsage(cpuCores: cores, footprint: cur.footprint)
            usage.resident = cur.resident
            if let prev = previous[pid], cur.wallNanos > prev.wallNanos, cur.diskRead >= prev.diskRead, cur.diskWritten >= prev.diskWritten {
                let seconds = Double(cur.wallNanos - prev.wallNanos) / 1e9
                usage.diskReadRate = Double(cur.diskRead - prev.diskRead) / seconds
                usage.diskWriteRate = Double(cur.diskWritten - prev.diskWritten) / seconds
            }
            result[pid] = usage
        }
        previous = next // forgets pids that disappeared
        return result
    }
}
