import Foundation

/// Minimal logger: appends timestamped lines to a file when one is configured.
public final class FileLog {
    public static let shared = FileLog()
    private var handle: FileHandle?
    private let lock = NSLock()
    private static let stamp = ISO8601DateFormatter()
    public func open(path: String) {
        _ = FileManager.default.createFile(atPath: path, contents: nil)
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
