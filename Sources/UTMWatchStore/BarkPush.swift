import Foundation

/// Pushes to an iPhone through Bark (https://github.com/Finb/Bark): the request to send and how to read the answer.
/// No I/O here; the app sends it.
public enum BarkPush {
    public static let defaultServer = "https://api.day.app"

    /// What the user typed or pasted into the key field: the bare device key, or the whole address Bark shows
    /// ("https://api.day.app/AbCd1234/Title/Body"), from which the server and the key are both taken.
    /// A server may sit under a path of its own ("https://home.example/bark/AbCd1234/Title"): the key is the first
    /// part of the path that looks like one, and what comes before it belongs to the server.
    /// An address that cannot be read gives an empty key, never the address itself.
    public static func parse(_ typed: String) -> (server: String?, key: String) {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.contains("://") else { return (nil, text.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) }
        // The title and body in the address may hold spaces or other characters a URL may not.
        let url = URL(string: text) ?? text.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed).flatMap { URL(string: $0) }
        guard let url, let scheme = url.scheme, scheme == "http" || scheme == "https", let host = url.host else { return (nil, "") }
        let parts = url.path.split(separator: "/").map(String.init)
        let looksLikeKey: (String) -> Bool = { $0.count >= 16 && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } }
        let at = parts.firstIndex(where: looksLikeKey) ?? 0
        var server = "\(scheme)://\(host)" + (url.port.map { ":\($0)" } ?? "")
        if at > 0 { server += "/" + parts[..<at].joined(separator: "/") }
        return (server, parts.indices.contains(at) ? parts[at] : "")
    }

    /// How much the push may interrupt, in Bark's own words.
    public enum Level: String {
        /// Shows while a Focus is on.
        case timeSensitive
        case active
        /// Lands in the list without lighting the screen or making a sound: for an update to a push already seen.
        case passive
    }

    public struct Message: Equatable {
        public var title: String
        public var body: String
        public var level: Level
        /// Pushes with the same id replace one another on the phone, so a later one updates the first.
        public var id: String?
        public init(title: String, body: String, level: Level = .active, id: String? = nil) {
            self.title = title; self.body = body; self.level = level; self.id = id
        }
    }

    /// The POST to make: the server's /push address and its JSON body. nil when the server is not a web address or
    /// there is no key.
    public static func request(server: String, key: String, message m: Message) -> (url: URL, body: Data)? {
        var base = server.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = defaultServer }
        while base.hasSuffix("/") { base.removeLast() }
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, let url = URL(string: base + "/push"), url.scheme == "http" || url.scheme == "https", url.host != nil else { return nil }
        var json: [String: Any] = ["device_key": key, "title": m.title, "body": m.body, "group": "UTM Watch",
                                   "level": m.level.rawValue]
        if let id = m.id { json["id"] = id }
        guard let body = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]) else { return nil }
        return (url, body)
    }

    /// nil when the push was accepted; otherwise why not, in the server's words where it gave any.
    /// A Bark server answers with JSON carrying "code": 200. A reply without it came from something else at that
    /// address, however friendly its status.
    public static func failure(status: Int, body: Data?) -> String? {
        let obj = body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        let code = (obj?["code"] as? NSNumber)?.intValue
        if (200..<300).contains(status), code == 200 { return nil }
        if let message = obj?["message"] as? String, !message.isEmpty { return message }
        if (200..<300).contains(status) { return "The server at that address did not answer like a Bark server." }
        return "The Bark server answered HTTP \(status)."
    }

    /// Whether a push that failed with this HTTP status is worth sending again later: the server was unwell, not unwilling.
    public static func worthRetrying(status: Int) -> Bool { status == 0 || status == 408 || status == 429 || status >= 500 }
}
