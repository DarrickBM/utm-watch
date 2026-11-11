import Foundation

public enum MonotonicClock {
    /// Nanoseconds from a monotonic clock that does not jump with wall-clock changes.
    public static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) }
}

public struct ShellResult {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool
}

public enum Shell {
    /// Runs an executable with a hard timeout; the process is killed if it exceeds it.
    public static func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 5) -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch {
            return ShellResult(status: -1, stdout: "", stderr: "\(error)", timedOut: false)
        }
        // Read pipes on background threads so a chatty child cannot deadlock on a full pipe.
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        group.enter(); DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter(); DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        let deadline = DispatchTime.now() + timeout
        var timedOut = false
        if group.wait(timeout: deadline) == .timedOut {
            timedOut = true
            process.terminate()
            _ = group.wait(timeout: .now() + 1)
        }
        process.waitUntilExit()
        return ShellResult(status: process.terminationStatus,
                           stdout: String(decoding: outData, as: UTF8.self),
                           stderr: String(decoding: errData, as: UTF8.self),
                           timedOut: timedOut)
    }
}

enum Sysctl {
    static func uint64(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }
    static func int32(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }
}

/// Minimal logger: appends timestamped lines to a file when one is configured.
public final class FileLog {
    public static let shared = FileLog()
    private var handle: FileHandle?
    private let lock = NSLock()
    private static let stamp = ISO8601DateFormatter()
    public func open(path: String) {
        FileManager.default.createFile(atPath: path, contents: nil)
        handle = FileHandle(forWritingAtPath: path)
        handle?.seekToEndOfFile()
    }
    public func log(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return }
        let line = "\(Self.stamp.string(from: Date())) \(message)\n"
        handle.write(Data(line.utf8))
    }
}
