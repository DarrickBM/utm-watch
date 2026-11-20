import Foundation

/// API keys and the phone's device key, in a file beside the history database that only the user's account can read.
/// A file, not the Keychain: the Keychain asks for the login password whenever the app's signature changes, which for
/// a build that is not notarised means after every update. The cost is that the keys are on disk unencrypted,
/// readable by anything that runs as the user.
public enum KeysFile {
    public static var path: String {
        ((HistoryStore.defaultPath as NSString).deletingLastPathComponent as NSString).appendingPathComponent("keys.json")
    }

    private static let lock = NSLock()

    private static func read(_ path: String) -> [String: String] {
        guard let data = FileManager.default.contents(atPath: path) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: String] ?? [:]
    }

    /// The key saved under `account`, or nil when there is none.
    public static func get(_ account: String, path: String = KeysFile.path) -> String? {
        lock.lock(); defer { lock.unlock() }
        let value = read(path)[account]
        return value?.isEmpty == false ? value : nil
    }

    /// Saves the key; an empty one removes it. The file is written whole, readable and writable by its owner only,
    /// and swapped into place so a reader never sees half of it. Returns false when it could not be written.
    @discardableResult public static func set(_ value: String, for account: String, path: String = KeysFile.path) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var all = read(path)
        if value.isEmpty { all[account] = nil } else { all[account] = value }
        guard let data = try? JSONSerialization.data(withJSONObject: all, options: [.prettyPrinted, .sortedKeys]) else { return false }
        let temp = path + ".new"
        try? FileManager.default.removeItem(atPath: temp)
        guard FileManager.default.createFile(atPath: temp, contents: data, attributes: [.posixPermissions: 0o600]) else { return false }
        guard rename(temp, path) == 0 else { try? FileManager.default.removeItem(atPath: temp); return false }
        return true
    }
}
