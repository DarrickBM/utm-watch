import CSysShim
import Foundation

public struct VMProcess: Hashable {
    public var pid: Int32
    public var executablePath: String
    public var startTime: UInt64

    public var backend: VMBackend {
        let base = (executablePath as NSString).lastPathComponent
        if base == ProcessScanner.appleExecutable { return .apple }
        if base == ProcessScanner.utmQEMULauncher || base.hasPrefix(ProcessScanner.qemuPrefix) { return .qemu }
        return .unknown
    }
}

/// Finds every running VM process: Apple Virtualization.framework helpers and QEMU.
public enum ProcessScanner {
    /// Apple Virtualization.framework helper (UTM "Apple" backend, also Tart, Lume, ...).
    public static let appleExecutable = "com.apple.Virtualization.VirtualMachine"
    /// UTM runs QEMU in a QEMULauncher process, a child of its QEMUHelper.xpc service, rather than as qemu-system-*.
    public static let utmQEMULauncher = "QEMULauncher"
    /// Standalone QEMU (Homebrew etc.).
    public static let qemuPrefix = "qemu-system-"

    public static func isVMExecutable(_ path: String) -> Bool {
        let base = (path as NSString).lastPathComponent
        return base == appleExecutable || base == utmQEMULauncher || base.hasPrefix(qemuPrefix)
    }

    public static func scan() -> [VMProcess] {
        var capacity = 4096
        var pids = [pid_t](repeating: 0, count: capacity)
        var count = shim_list_pids(&pids, Int32(capacity))
        while count == Int32(capacity) { // buffer was full; grow and retry
            capacity *= 2
            pids = [pid_t](repeating: 0, count: capacity)
            count = shim_list_pids(&pids, Int32(capacity))
        }
        guard count > 0 else { return [] }
        var result: [VMProcess] = []
        var buf = [CChar](repeating: 0, count: 4 * 1024)
        for i in 0..<Int(count) {
            let pid = pids[i]
            guard pid > 0 else { continue }
            let len = shim_proc_path(pid, &buf, UInt32(buf.count))
            guard len > 0 else { continue }
            let path = String(cString: buf)
            guard isVMExecutable(path) else { continue }
            var start: UInt64 = 0
            _ = shim_proc_start_time(pid, &start)
            result.append(VMProcess(pid: pid, executablePath: path, startTime: start))
        }
        return result.sorted { $0.pid < $1.pid }
    }
}
