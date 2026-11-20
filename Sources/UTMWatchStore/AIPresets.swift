import Foundation

/// A chat-completions service the user saved under a name of their own: where it is, and which model to ask for.
/// The key is not part of it; keys stay in the Keychain.
public struct AIPreset: Codable, Equatable {
    public var name: String
    public var address: String
    public var model: String

    public init(name: String, address: String, model: String) {
        self.name = name; self.address = address; self.model = model
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        address = try c.decode(String.self, forKey: .address)
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
    }

    /// The host the address points at, with its port when it names one; nil when the address is not a web address.
    public var host: String? { AIPreset.host(of: address) }

    public static func host(of address: String) -> String? {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme == "http" || url.scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return host + (url.port.map { ":\($0)" } ?? "")
    }
}

/// The user's own presets, in a file beside the history database that can also be edited by hand:
/// a JSON list of {"name", "address", "model"}.
public enum AIPresetsFile {
    public static var path: String {
        ((HistoryStore.defaultPath as NSString).deletingLastPathComponent as NSString).appendingPathComponent("ai-presets.json")
    }

    /// Entries without a name or a usable web address are skipped one by one, so one slip in a hand edit does not
    /// lose the rest. A later entry with a name already seen replaces nothing: the first one wins.
    public static func load(path: String = AIPresetsFile.path) -> [AIPreset] {
        guard let data = FileManager.default.contents(atPath: path), let raw = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return [] }
        var out: [AIPreset] = []
        for item in raw {
            // Only an object can be an entry; anything else in the list (a stray string or number) is passed over.
            guard item is [String: Any], let d = try? JSONSerialization.data(withJSONObject: item), var p = try? JSONDecoder().decode(AIPreset.self, from: d) else { continue }
            p.name = p.name.trimmingCharacters(in: .whitespacesAndNewlines)
            p.address = p.address.trimmingCharacters(in: .whitespacesAndNewlines)
            p.model = p.model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !p.name.isEmpty, p.host != nil, !out.contains(where: { $0.name.caseInsensitiveCompare(p.name) == .orderedSame }) else { continue }
            out.append(p)
        }
        return out
    }

    public static func save(_ presets: [AIPreset], path: String = AIPresetsFile.path) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? enc.encode(presets) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// When the file last changed; nil when there is none. The app re-reads the file when this moves.
    public static func modified(path: String = AIPresetsFile.path) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }
}
