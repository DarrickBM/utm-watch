import CSysShim
import Foundation

/// Finds helper programs that an earlier copy of the app left running: their parent is gone (they now belong to
/// launchd, PID 1), so nothing will ever stop them.
public enum LeftoverHelpers {
    /// PIDs of this user's processes whose executable has the file name `name`, whose parent is launchd, and whose
    /// arguments include every string in `arguments`.
    public static func find(name: String, arguments: [String]) -> [pid_t] {
        var pids = [pid_t](repeating: 0, count: 8192)
        let count = shim_list_pids(&pids, Int32(pids.count))
        guard count > 0 else { return [] }
        let me = getpid()
        var found: [pid_t] = []
        for pid in pids.prefix(Int(count)) where pid > 1 && pid != me {
            var ppid: pid_t = 0
            guard shim_proc_ppid(pid, &ppid) == 0, ppid == 1 else { continue }
            let argv = args(of: pid)
            // The executable's path cannot be read once its file is gone, as it is after the app is rebuilt or
            // updated in place, which is exactly when helpers get left behind; argv[0] still names it.
            var path = [CChar](repeating: 0, count: 4096)
            let exe = shim_proc_path(pid, &path, UInt32(path.count)) > 0 ? String(cString: path) : argv.first ?? ""
            guard (exe as NSString).lastPathComponent == name else { continue }
            if arguments.allSatisfy(argv.contains) { found.append(pid) }
        }
        return found
    }

    /// The process's arguments, argv[0] first; empty when they cannot be read.
    public static func args(of pid: pid_t) -> [String] {
        var buf = [CChar](repeating: 0, count: 64 * 1024)
        let n = shim_proc_args(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return [] }
        return buf.prefix(Int(n)).split(separator: 0, omittingEmptySubsequences: false).dropLast()
            .map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
    }
}
