import Foundation

/// This Mac's place in a fleet: who it is and which hub it reports to. Present on disk = this Mac is in a fleet.
/// Kept in a file rather than the Keychain (an ad-hoc signed app would be asked for Keychain access after every update)
/// and rather than the history database (clearing history must not make the Mac leave its fleet).
public struct HostIdentity: Codable, Equatable {
    public var hostUUID: String
    /// The name the fleet view shows for this Mac.
    public var name: String
    /// The hub's address, e.g. "https://hub.example.ts.net" or "http://mini-1.local:8787".
    public var hubURL: String
    /// This Mac's own secret for uploading. Never shown in the UI or written to the log.
    public var hostToken: String
    /// Lets this Mac read the whole fleet (the fleet view); absent on Macs that only report.
    public var readerToken: String?
    /// True when the hub is reached over the fleet's private network, through the bundled helper's proxy.
    public var viaPrivateNetwork: Bool?

    public init(hostUUID: String, name: String, hubURL: String, hostToken: String, readerToken: String? = nil, viaPrivateNetwork: Bool? = nil) {
        self.hostUUID = hostUUID; self.name = name; self.hubURL = hubURL; self.hostToken = hostToken; self.readerToken = readerToken
        self.viaPrivateNetwork = viaPrivateNetwork
    }

    /// Where UTM Watch keeps its files. `UTMWATCH_DATA_DIR` moves all of them, so a trial copy never touches the real data.
    public static var dataDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["UTMWATCH_DATA_DIR"], !override.isEmpty {
            let url = URL(fileURLWithPath: override, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("UTM Watch", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `UTMWATCH_FLEET_IDENTITY` points somewhere else, so tests and trials never touch the real identity.
    /// Where the app notes the private network helper's loopback proxy while it runs, for the MCP helper to use.
    public static var proxyNotePath: String { dataDirectory.appendingPathComponent("net-proxy").path }

    public static var defaultPath: String {
        if let override = ProcessInfo.processInfo.environment["UTMWATCH_FLEET_IDENTITY"], !override.isEmpty { return override }
        return dataDirectory.appendingPathComponent("fleet.json").path
    }

    public static func load(path: String = HostIdentity.defaultPath) -> HostIdentity? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(HostIdentity.self, from: data)
    }

    /// Writes the file readable by this user only: it holds the Mac's upload secret.
    public func save(path: String = HostIdentity.defaultPath) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        guard FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    public static func remove(path: String = HostIdentity.defaultPath) {
        try? FileManager.default.removeItem(atPath: path)
    }
}
