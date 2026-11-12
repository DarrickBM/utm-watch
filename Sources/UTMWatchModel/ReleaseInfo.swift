import Foundation

/// A published release, as the app updater needs it. Parsed from GitHub's release JSON.
public struct ReleaseInfo: Equatable {
    public var version: String
    /// The beta number for a pre-release ("v0.6.0-beta.5" is beta 5 of 0.6.0); nil for a final release.
    public var beta: Int?
    /// How the release is named to the user: "0.6.0" or "0.6.0 beta 5".
    public var label: String { AppVersion.label(version, beta: beta) }
    /// The app as a zip, the same file install.sh uses.
    public var appZip: URL
    public var checksums: URL

    public static func parse(_ json: Data) -> ReleaseInfo? {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return nil }
        return parse(root)
    }

    /// The newest usable release in GitHub's list of releases. Betas count only when `includeBetas` is set;
    /// drafts and releases this app cannot install are skipped.
    public static func newest(inList json: Data, includeBetas: Bool) -> ReleaseInfo? {
        guard let list = try? JSONSerialization.jsonObject(with: json) as? [[String: Any]] else { return nil }
        var best: ReleaseInfo?
        for entry in list where entry["draft"] as? Bool != true {
            guard let r = parse(entry), includeBetas || r.beta == nil else { continue }
            if best.map({ AppVersion.isNewer(r.version, beta: r.beta, than: $0.version, beta: $0.beta) }) ?? true { best = r }
        }
        return best
    }

    private static func parse(_ root: [String: Any]) -> ReleaseInfo? {
        guard let tag = root["tag_name"] as? String, let assets = root["assets"] as? [[String: Any]] else { return nil }
        func url(_ match: (String) -> Bool) -> URL? {
            for asset in assets {
                if let name = asset["name"] as? String, match(name), let s = asset["browser_download_url"] as? String,
                   let u = URL(string: s), u.scheme == "https" { return u }
            }
            return nil
        }
        guard let zip = url({ $0.hasPrefix("UTMWatch-") && $0.hasSuffix("macos-arm64.zip") }),
              let sums = url({ $0 == "SHA256SUMS.txt" }) else { return nil }
        // "v0.6.0" or "v0.6.0-beta.5". Any other suffix is a kind of release this app does not know.
        let name = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let pieces = name.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let version = pieces[0]
        guard !AppVersion.parts(version).isEmpty else { return nil }
        var beta: Int?
        if pieces.count == 2 {
            guard pieces[1].hasPrefix("beta."), let n = Int(pieces[1].dropFirst(5)), n > 0 else { return nil }
            beta = n
        }
        return ReleaseInfo(version: version, beta: beta, appZip: zip, checksums: sums)
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

    /// The same, with betas: a beta comes before the final release of its version, and beta 5 after beta 4.
    public static func isNewer(_ candidate: String, beta candidateBeta: Int?, than current: String, beta currentBeta: Int?) -> Bool {
        if isNewer(candidate, than: current) { return true }
        if isNewer(current, than: candidate) || parts(candidate).isEmpty || parts(current).isEmpty { return false }
        switch (candidateBeta, currentBeta) {
        case (nil, nil), (_?, nil): return false
        case (nil, _?): return true
        case let (a?, b?): return a > b
        }
    }

    public static func label(_ version: String, beta: Int?) -> String {
        beta.map { "\(version) beta \($0)" } ?? version
    }
}
