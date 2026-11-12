// utmwatch-hub: the fleet's data pool.
//   utmwatch-hub serve [--db PATH] [--host 127.0.0.1] [--port 8787] [--raw-hours 48] [--keep-days 90]
//   utmwatch-hub token create --enroll | --reader [LABEL]   [--db PATH]
//   utmwatch-hub hosts [--db PATH]
//   utmwatch-hub revoke HOST-UUID [--db PATH]
import Foundation
import Hummingbird
import UTMWatchFleet
import UTMWatchModel
import UTMWatchStore

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

var args = Array(CommandLine.arguments.dropFirst())
/// Removes `--name value` from the arguments and returns the value.
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let value = args[i + 1]
    args.removeSubrange(i...i + 1)
    return value
}
func flag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}

let dbPath = option("--db") ?? ProcessInfo.processInfo.environment["UTMWATCH_HUB_DB"] ?? "hub.sqlite"
let store: HubStore
do { store = try HubStore(path: dbPath) } catch { fail("cannot open the hub database at \(dbPath): \(error)") }
func nowMs() -> Int64 { Date().msSince1970 }

let usage = """
usage:
  utmwatch-hub serve [--db PATH] [--host 127.0.0.1] [--port 8787] [--raw-hours 48] [--keep-days 90]
  utmwatch-hub token create --enroll | --reader [LABEL] [--db PATH]
  utmwatch-hub hosts [--db PATH]
  utmwatch-hub revoke HOST-UUID [--db PATH]
"""

switch args.first {
case "token":
    guard args.dropFirst().first == "create" else { fail(usage) }
    if flag("--enroll") {
        print(store.createEnrollToken(now: nowMs(), view: flag("--view")))
    } else if flag("--reader") {
        print(store.createReaderToken(label: args.dropFirst(2).first ?? "reader", now: nowMs()))
    } else { fail(usage) }

case "hosts":
    let hosts = store.hosts(now: nowMs())
    if hosts.isEmpty { print("No Macs enrolled.") }
    for h in hosts {
        let seen = h.lastSeen.map { "\((nowMs() - $0) / 1000) s ago" } ?? "never"
        print("\(h.uuid)  \(h.state.padding(toLength: 7, withPad: " ", startingAt: 0))  \(h.name)  (last seen \(seen), app \(h.appVersion ?? "?"))")
    }

case "revoke":
    guard args.count == 2 else { fail(usage) }
    guard store.revoke(hostUUID: args[1]) else { fail("no Mac with UUID \(args[1])") }
    print("Revoked \(args[1]).")

case "serve":
    let host = option("--host") ?? "127.0.0.1"
    let port = option("--port").flatMap(Int.init) ?? 8787
    let rawHours = option("--raw-hours").flatMap(Int64.init) ?? 48
    let keepDays = option("--keep-days").flatMap(Int64.init) ?? 90
    let service = HubService(store: store)

    @Sendable func handle(_ request: Request, _ context: BasicRequestContext) async throws -> Response {
        // Uploads are a few kilobytes; a catch-up slice of five minutes stays far under this.
        let body = try await request.body.collect(upTo: 16 * 1024 * 1024)
        var query: [String: String] = [:]
        for (key, value) in request.uri.queryParameters { query[String(key)] = String(value) }
        var bearer: String?
        if let auth = request.headers[.authorization], auth.lowercased().hasPrefix("bearer ") { bearer = String(auth.dropFirst(7)) }
        let reply = service.handle(HubRequest(method: request.method.rawValue, path: request.uri.path, query: query, bearer: bearer,
                                              body: Data(body.readableBytesView)))
        return Response(status: .init(code: reply.status), headers: [.contentType: "application/json"],
                        body: .init(byteBuffer: ByteBuffer(bytes: [UInt8](reply.body))))
    }

    let router = Router()
    router.get("v1/health", use: handle)
    router.post("v1/enroll", use: handle)
    router.post("v1/ingest", use: handle)
    router.get("v1/hosts", use: handle)
    router.get("v1/hosts/{uuid}/history", use: handle)
    router.get("v1/hosts/{uuid}/commands", use: handle)
    router.get("v1/events", use: handle)

    // Retention: at start, then hourly.
    let pruner = Task {
        while !Task.isCancelled {
            let now = nowMs()
            store.prune(rawOlderThan: now - rawHours * 3600_000, rollupsOlderThan: now - keepDays * 86_400_000)
            try? await Task.sleep(for: .seconds(3600))
        }
    }
    defer { pruner.cancel() }
    // Macs going silent and coming back go on the timeline; only the hub can see that.
    let watcher = Task {
        while !Task.isCancelled {
            for event in store.noteOfflineChanges(now: nowMs()) { print("utmwatch-hub: \(event.label)") }
            try? await Task.sleep(for: .seconds(15))
        }
    }
    defer { watcher.cancel() }

    print("utmwatch-hub: serving \(dbPath) on http://\(host):\(port) (raw \(rawHours) h, rollups \(keepDays) days)")
    let app = Application(router: router, configuration: .init(address: .hostname(host, port: port)))
    do { try await app.runService() } catch { fail("the hub stopped: \(error)") }

default:
    fail(usage)
}
