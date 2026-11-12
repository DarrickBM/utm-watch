import Foundation
import UTMWatchModel
import UTMWatchStore

/// Carries one request to a hub and brings the answer back; nil means the hub could not be reached.
public protocol HubTransport {
    func send(_ request: HubRequest, to baseURL: String) -> HubResponse?
}

/// Talks to a hub in the same process. Used by the tests, and to try the whole upload path without a network.
public final class InProcessTransport: HubTransport {
    private let service: HubService
    /// Set to false to imitate a hub that is down.
    public var reachable = true
    public init(service: HubService) { self.service = service }
    public func send(_ request: HubRequest, to baseURL: String) -> HubResponse? { reachable ? service.handle(request) : nil }
}

#if canImport(Darwin)
/// The real thing: HTTP(S) through URLSession. Blocks the calling thread, so never call it on the main thread.
public final class URLSessionTransport: HubTransport {
    private let session: URLSession
    /// Why the most recent request got no answer, for the log. Not synchronised: it is only ever read for a message.
    public nonisolated(unsafe) static var lastError: String?

    /// `proxy` is "host:port" of an HTTP proxy to send everything through: the loopback proxy of the helper that
    /// carries a fleet's traffic over its private network.
    public init(timeout: TimeInterval = 15, proxy: String? = nil) {
        let config = URLSessionConfiguration.ephemeral
        if let proxy, let colon = proxy.lastIndex(of: ":"), let port = Int(proxy[proxy.index(after: colon)...]) {
            config.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable as String: 1,
                kCFNetworkProxiesHTTPProxy as String: String(proxy[..<colon]),
                kCFNetworkProxiesHTTPPort as String: port,
            ]
        }
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 2
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    public func send(_ request: HubRequest, to baseURL: String) -> HubResponse? {
        guard var parts = URLComponents(string: baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL) else { return nil }
        parts.path += request.path
        if !request.query.isEmpty { parts.queryItems = request.query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = parts.url else { return nil }
        var r = URLRequest(url: url)
        r.httpMethod = request.method
        if let bearer = request.bearer { r.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        if request.method != "GET" {
            r.httpBody = request.body
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        var result: HubResponse?
        let done = DispatchSemaphore(value: 0)
        session.dataTask(with: r) { data, response, error in
            if let http = response as? HTTPURLResponse { result = HubResponse(status: http.statusCode, body: data ?? Data()) }
            else if let error = error as NSError? { URLSessionTransport.lastError = "\(error.domain) \(error.code): \(error.localizedDescription)" }
            done.signal()
        }.resume()
        done.wait()
        return result
    }
}
#endif

public enum HubFailure: Error, Equatable {
    /// No answer: the hub is down or the network is.
    case unreachable
    /// The hub answered and said no, e.g. 401 for a revoked token.
    case rejected(status: Int, message: String)
}

/// The calls a Mac makes to its hub. Every call blocks until the hub answers or the transport gives up.
public final class HubClient {
    public let baseURL: String
    private let transport: HubTransport

    #if canImport(Darwin)
    public init(baseURL: String, transport: HubTransport = URLSessionTransport()) { self.baseURL = baseURL; self.transport = transport }
    #else
    public init(baseURL: String, transport: HubTransport) { self.baseURL = baseURL; self.transport = transport }
    #endif

    private func call<T: Codable>(_ request: HubRequest, as: T.Type) -> Result<T, HubFailure> {
        guard let response = transport.send(request, to: baseURL) else { return .failure(.unreachable) }
        let reply = FleetAPI.decode(FleetReply<T>.self, from: response.body)
        if response.status == 200, let data = reply?.data { return .success(data) }
        // Something that answers but is not a hub (a captive portal, a wrong address) lands here too.
        return .failure(.rejected(status: response.status, message: reply?.error ?? "The server at this address did not answer like a UTM Watch hub."))
    }

    public func health() -> Result<[String: Bool], HubFailure> {
        call(HubRequest(method: "GET", path: "/v1/health"), as: [String: Bool].self)
    }

    public func enroll(code: String, request: EnrollRequest) -> Result<EnrollReply, HubFailure> {
        call(HubRequest(method: "POST", path: "/v1/enroll", bearer: code, body: FleetAPI.encode(request)), as: EnrollReply.self)
    }

    public func ingest(_ batch: IngestBatch, token: String) -> Result<IngestReply, HubFailure> {
        call(HubRequest(method: "POST", path: "/v1/ingest", bearer: token, body: FleetAPI.encode(batch)), as: IngestReply.self)
    }

    public func hosts(token: String) -> Result<[HostStatus], HubFailure> {
        call(HubRequest(method: "GET", path: "/v1/hosts", bearer: token), as: [HostStatus].self)
    }

    public func history(hostUUID: String, from: Int64, to: Int64, maxPoints: Int?, token: String) -> Result<History, HubFailure> {
        var query = ["from": "\(from)", "to": "\(to)"]
        if let maxPoints { query["maxPoints"] = "\(maxPoints)" }
        return call(HubRequest(method: "GET", path: "/v1/hosts/\(hostUUID)/history", query: query, bearer: token), as: History.self)
    }

    public func events(after: Int64? = nil, from: Int64? = nil, to: Int64? = nil, hostUUID: String? = nil, token: String) -> Result<[FleetEvent], HubFailure> {
        var query: [String: String] = [:]
        if let after { query["after"] = "\(after)" }
        if let from { query["from"] = "\(from)" }
        if let to { query["to"] = "\(to)" }
        if let hostUUID { query["host"] = hostUUID }
        return call(HubRequest(method: "GET", path: "/v1/events", query: query, bearer: token), as: [FleetEvent].self)
    }
}
