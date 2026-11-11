import Foundation
import UTMWatchModel
import UTMWatchStore

/// One HTTP request, reduced to what the hub needs. The server shell fills this in; tests build it directly.
public struct HubRequest {
    public var method: String
    public var path: String
    public var query: [String: String]
    /// The token from `Authorization: Bearer …`.
    public var bearer: String?
    public var body: Data
    public init(method: String, path: String, query: [String: String] = [:], bearer: String? = nil, body: Data = Data()) {
        self.method = method; self.path = path; self.query = query; self.bearer = bearer; self.body = body
    }
}

public struct HubResponse {
    public var status: Int
    /// Always JSON: a `FleetReply`.
    public var body: Data
}

/// The hub's API with no transport attached: it turns a request into a response and nothing else.
/// The HTTP server in `Hub/` and the in-process transport used by tests both call `handle`.
public final class HubService {
    public let store: HubStore
    private let now: () -> Int64

    public init(store: HubStore, now: @escaping () -> Int64 = { Date().msSince1970 }) {
        self.store = store; self.now = now
    }

    private struct Empty: Codable {}
    private struct Health: Codable { var ok = true }

    public func handle(_ r: HubRequest) -> HubResponse {
        let t = now()
        do {
            return try route(r, t)
        } catch HubError.unauthorized {
            return fail(401, "This token is not valid for the hub.", t)
        } catch HubError.notFound {
            return fail(404, "Not found.", t)
        } catch HubError.badRequest(let why) {
            return fail(400, why, t)
        } catch {
            FileLog.shared.log("hub request failed: \(r.method) \(r.path): \(error)")
            return fail(500, "The hub could not handle this request.", t)
        }
    }

    private func route(_ r: HubRequest, _ t: Int64) throws -> HubResponse {
        let parts = r.path.split(separator: "/").map(String.init)
        guard parts.first == "v1" else { throw HubError.notFound }
        switch (r.method, Array(parts.dropFirst())) {
        case ("GET", ["health"]):
            return ok(Health(), t)

        case ("POST", ["enroll"]):
            guard let token = r.bearer else { throw HubError.unauthorized }
            guard let request = FleetAPI.decode(EnrollRequest.self, from: r.body) else { throw HubError.badRequest("The enrolment request could not be read.") }
            return ok(try store.enroll(token: token, request: request, now: t), t)

        case ("POST", ["ingest"]):
            guard let token = r.bearer, let host = store.hostID(forToken: token) else { throw HubError.unauthorized }
            guard let batch = FleetAPI.decode(IngestBatch.self, from: r.body) else { throw HubError.badRequest("The upload could not be read.") }
            guard batch.apiVersion == FleetAPI.version else { throw HubError.badRequest("This hub speaks API version \(FleetAPI.version); the upload used \(batch.apiVersion).") }
            try store.ingest(batch, hostID: host, now: t)
            return ok(IngestReply(accepted: batch.cursor), t)

        case ("GET", ["hosts"]):
            try requireReader(r)
            return ok(store.hosts(now: t), t)

        case ("GET", let p) where p.count == 3 && p[0] == "hosts" && p[2] == "history":
            try requireReader(r)
            guard let from = r.query["from"].flatMap(Int64.init), let to = r.query["to"].flatMap(Int64.init), to >= from else {
                throw HubError.badRequest("from and to are required, in milliseconds since 1970.")
            }
            let maxPoints = r.query["maxPoints"].flatMap(Int.init).map { min(max($0, 1), 5000) }
            // Every raw sample is only sensible for short frames; cap the rest so one request cannot pull days of rows.
            guard maxPoints != nil || to - from <= 3600_000 else { throw HubError.badRequest("maxPoints is required for frames longer than an hour.") }
            guard let history = store.load(hostUUID: p[1], from: from, to: to, maxPoints: maxPoints) else { throw HubError.notFound }
            return ok(history, t)

        case ("GET", ["events"]):
            try requireReader(r)
            let events = store.events(from: r.query["from"].flatMap(Int64.init), to: r.query["to"].flatMap(Int64.init), hostUUID: r.query["host"],
                                      after: r.query["after"].flatMap(Int64.init), limit: min(r.query["limit"].flatMap(Int.init) ?? 1000, 5000))
            return ok(events, t)

        case ("GET", let p) where p.count == 3 && p[0] == "hosts" && p[2] == "commands":
            // Reserved for remote control. A Mac may ask; in API version 1 the answer is always "nothing".
            guard let token = r.bearer, store.hostID(forToken: token) != nil else { throw HubError.unauthorized }
            return ok([String](), t)

        default:
            throw HubError.notFound
        }
    }

    private func requireReader(_ r: HubRequest) throws {
        guard let token = r.bearer, store.isReader(token) else { throw HubError.unauthorized }
    }

    private func ok<T: Codable>(_ data: T, _ t: Int64) -> HubResponse {
        HubResponse(status: 200, body: FleetAPI.encode(FleetReply(serverTime: t, data: data)))
    }

    private func fail(_ status: Int, _ message: String, _ t: Int64) -> HubResponse {
        HubResponse(status: status, body: FleetAPI.encode(FleetReply<Empty>(serverTime: t, error: message)))
    }
}
