import Foundation

/// The newest published release, as the app updater needs it. Parsed from GitHub's "latest release" JSON.
public struct ReleaseInfo: Equatable {
    public var version: String
    /// The app as a zip, the same file install.sh uses.
    public var appZip: URL
    public var checksums: URL

    public static func parse(_ json: Data) -> ReleaseInfo? {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let tag = root["tag_name"] as? String, let assets = root["assets"] as? [[String: Any]] else { return nil }
        func url(_ match: (String) -> Bool) -> URL? {
            for asset in assets {
                if let name = asset["name"] as? String, match(name), let s = asset["browser_download_url"] as? String,
                   let u = URL(string: s), u.scheme == "https" { return u }
            }
            return nil
        }
        guard let zip = url({ $0.hasPrefix("UTMWatch-") && $0.hasSuffix("macos-arm64.zip") }),
              let sums = url({ $0 == "SHA256SUMS.txt" }) else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard !AppVersion.parts(version).isEmpty else { return nil }
        return ReleaseInfo(version: version, appZip: zip, checksums: sums)
    }

    /// The checksum listed for `fileName` in a `shasum -a 256` listing.
    public static func checksum(for fileName: String, in listing: String) -> String? {
        for line in listing.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            if fields.count == 2, fields[1].trimmingCharacters(in: CharacterSet(charactersIn: "*")) == fileName, fields[0].count == 64 {
                return fields[0].lowercased()
            }
        }
        return nil
    }
}

public enum AppVersion {
    /// "0.10.2" -> [0, 10, 2]; empty when any part is not a number.
    public static func parts(_ version: String) -> [Int] {
        let fields = version.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        return fields.contains(where: { $0 == nil }) ? [] : fields.compactMap { $0 }
    }

    /// Compares number by number, so 0.10.0 is newer than 0.9.0. A version that cannot be read is never newer.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = parts(candidate), b = parts(current)
        guard !a.isEmpty, !b.isEmpty else { return false }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
