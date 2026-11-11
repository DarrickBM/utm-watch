import CSysShim
import Foundation

public struct TopProcess: Codable, Equatable {
    public var name: String
    public var pid: Int32
    public var memoryBytes: UInt64
    public var cpuCores: Double
}

/// The busiest processes on the Mac right now, by memory and by CPU.
/// Only processes this user may inspect are seen (system daemons owned by root are not).
public enum ProcessTop {
    private static func readAll() -> [Int32: (cpu: UInt64, mem: UInt64)] {
        var pids = [pid_t](repeating: 0, count: 8192)
        let n = shim_list_pids(&pids, Int32(pids.count))
        var out: [Int32: (cpu: UInt64, mem: UInt64)] = [:]
        guard n > 0 else { return out }
        for i in 0..<Int(n) where pids[i] > 0 {
            var user: UInt64 = 0, system: UInt64 = 0, footprint: UInt64 = 0
            if shim_proc_rusage(pids[i], &user, &system, &footprint) == 0 { out[pids[i]] = (user &+ system, footprint) }
        }
        return out
    }

    private static func name(_ pid: Int32) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        return shim_proc_name(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : "pid \(pid)"
    }

    /// Blocks for `window` seconds to measure CPU. Call off the main thread.
    public static func capture(count: Int = 5, window: TimeInterval = 0.5) -> (byMemory: [TopProcess], byCPU: [TopProcess]) {
        let first = readAll()
        let start = MonotonicClock.now()
        Thread.sleep(forTimeInterval: window)
        let second = readAll()
        let elapsed = Double(MonotonicClock.now() - start)
        var all: [TopProcess] = []
        for (pid, cur) in second {
            let cpu = first[pid].map { cur.cpu >= $0.cpu ? Double(cur.cpu - $0.cpu) / elapsed : 0 } ?? 0
            all.append(TopProcess(name: name(pid), pid: pid, memoryBytes: cur.mem, cpuCores: (cpu * 100).rounded() / 100))
        }
        let byMemory = Array(all.sorted { $0.memoryBytes > $1.memoryBytes }.prefix(count))
        let byCPU = Array(all.sorted { $0.cpuCores > $1.cpuCores }.prefix(count).filter { $0.cpuCores > 0 })
        return (byMemory, byCPU)
    }
}
