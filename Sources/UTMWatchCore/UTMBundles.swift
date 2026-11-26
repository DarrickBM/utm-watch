import Foundation

/// Static configuration read from a `<Name>.utm/config.plist`.
public struct UTMBundle: Equatable {
    public var url: URL
    public var uuid: String?
    public var name: String
    public var backend: VMBackend
    public var cpuCount: Int?
    public var memoryBytes: UInt64?
    /// Normalized (lowercase, zero-padded) MAC addresses of the VM's network interfaces.
    public var macAddresses: [String]
    public var networkModes: [String]
    public var isMacOS: Bool
    /// File names of the VM's writable disk images, inside the bundle's Data folder.
    public var diskImages: [String] = []

    /// Stable key for a VM. The bundle path is known as soon as the process is seen, before config.plist
    /// has been read, so it never changes mid-run the way a UUID-once-loaded key would.
    public var identity: String { url.path }
}

public enum UTMBundles {
    /// `UTMWATCH_NO_UTM=1` keeps a trial copy of the app away from UTM entirely: it reads none of UTM's files and
    /// sends UTM no questions, so macOS never asks for permissions on its behalf. It then shows no VMs of its own.
    public static let disabled = ProcessInfo.processInfo.environment["UTMWATCH_NO_UTM"] == "1"

    public static var defaultDirectory: URL {
        if disabled { return URL(fileURLWithPath: "/var/empty/utmwatch-no-utm", isDirectory: true) }
        // Testing aid: `UTMWATCH_UTM_DIR` reads VMs from another folder, such as one only Full Disk Access opens, to
        // check that a permission survives an update on a Mac where UTM's own folder is not protected.
        if let dir = ProcessInfo.processInfo.environment["UTMWATCH_UTM_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.utmapp.UTM/Data/Documents", isDirectory: true)
    }

    /// Testing aid: `UTMWATCH_NO_UTM_FILES=1` behaves as if macOS refused access to UTM's folder, while UTM is still
    /// asked for its list, to exercise the settings UTM itself reports.
    public static let filesDisabled = ProcessInfo.processInfo.environment["UTMWATCH_NO_UTM_FILES"] == "1"

    public enum FolderAccess: Equatable { case readable, missing, denied }

    /// Whether UTM's VM folder can be listed. A missing folder is not a refusal: UTM may not be installed, or may never
    /// have made a VM. Anything else that stops the listing is macOS withholding the privacy permission.
    public static func access(directory: URL = defaultDirectory) -> FolderAccess {
        if disabled { return .missing }
        if filesDisabled { return .denied } // the test aid imitates a refusal
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            return .readable
        } catch let error as NSError {
            return error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError ? .missing : .denied
        }
    }

    public static func scan(directory: URL = defaultDirectory) -> [UTMBundle] {
        if filesDisabled { return [] }
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                      options: [.skipsHiddenFiles]) else { return [] }
        return items.filter { $0.pathExtension == "utm" }.compactMap { load(url: $0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Loads a bundle; falls back to the folder name if config.plist is missing or unreadable (PRD R4).
    public static func load(url: URL) -> UTMBundle? {
        // A trial copy knows a running VM by its folder name only, without opening anything inside UTM's folder.
        if disabled || filesDisabled {
            return UTMBundle(url: url, uuid: nil, name: url.deletingPathExtension().lastPathComponent, backend: .unknown,
                             cpuCount: nil, memoryBytes: nil, macAddresses: [], networkModes: [], isMacOS: false)
        }
        let plistURL = url.appendingPathComponent("config.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let any = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = any as? [String: Any] else {
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            FileLog.shared.log("config.plist unreadable for \(url.lastPathComponent); using folder name")
            return UTMBundle(url: url, uuid: nil, name: url.deletingPathExtension().lastPathComponent, backend: .unknown,
                             cpuCount: nil, memoryBytes: nil, macAddresses: [], networkModes: [], isMacOS: false)
        }
        return parse(plist: dict, url: url)
    }

    public static func parse(plist: [String: Any], url: URL) -> UTMBundle {
        let info = plist["Information"] as? [String: Any]
        let system = plist["System"] as? [String: Any]
        let boot = system?["Boot"] as? [String: Any]
        let name = (info?["Name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? url.deletingPathExtension().lastPathComponent
        let backendString = (plist["Backend"] as? String)?.lowercased() ?? ""
        let backend: VMBackend = backendString == "apple" ? .apple : backendString == "qemu" ? .qemu : .unknown
        let cpu = (system?["CPUCount"] as? NSNumber)?.intValue
        let memMiB = (system?["MemorySize"] as? NSNumber)?.uint64Value
        let networks = plist["Network"] as? [[String: Any]] ?? []
        let macs = networks.compactMap { ($0["MacAddress"] as? String).map(MACAddress.normalize) }
        let modes = networks.compactMap { $0["Mode"] as? String }
        let os = (boot?["OperatingSystem"] as? String)?.lowercased()
        let isMac = os == "macos" || (os == nil && backend == .apple && system?["MacPlatform"] != nil)
        return UTMBundle(url: url, uuid: info?["UUID"] as? String, name: name, backend: backend,
                         cpuCount: cpu.flatMap { $0 > 0 ? $0 : nil },
                         memoryBytes: memMiB.flatMap { $0 > 0 ? $0 * 1024 * 1024 : nil },
                         macAddresses: macs, networkModes: modes, isMacOS: isMac, diskImages: DiskImages.imageNames(plist: plist))
    }
}

public enum MACAddress {
    /// Lowercase, zero-padded form so "e:1:2:3:4:5" and "0E:01:02:03:04:05" compare equal.
    public static func normalize(_ raw: String) -> String {
        let parts = raw.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 6 else { return raw.lowercased() }
        return parts.map { part -> String in
            guard let v = UInt8(part, radix: 16) else { return String(part).lowercased() }
            return String(format: "%02x", v)
        }.joined(separator: ":")
    }
}
