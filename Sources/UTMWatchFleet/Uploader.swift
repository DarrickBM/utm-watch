import Foundation
import UTMWatchModel
import UTMWatchStore

/// Sends this Mac's recorded history to its hub. The local database is the queue: the uploader only remembers
/// how far it got, so after an outage (hub down, Mac asleep, no network) it continues from there and fills the gap.
public final class Uploader {
    public enum State: Equatable {
        /// Nothing sent yet.
        case starting
        /// Everything recorded so far is on the hub.
        case upToDate
        /// The hub is reachable and older history is still being sent.
        case catchingUp
        /// The hub did not answer; the Mac keeps recording and will catch up.
        case unreachable
        /// The hub refused this Mac (revoked, or enrolled elsewhere). Enrolling again fixes it.
        case rejected(String)
    }

    public struct Status: Equatable {
        public var state: State = .starting
        /// When the hub last accepted an upload, by this Mac's clock.
        public var lastSuccess: Int64?
    }

    private let store: HistoryStore
    private let client: HubClient
    private let token: String
    private let appVersion: String
    private let backfillMs: Int64
    private let sliceMs: Int64
    private let now: () -> Int64
    private let queue = DispatchQueue(label: "utmwatch.uploader", qos: .utility)
    private var timer: DispatchSourceTimer?
    private let lock = NSLock()
    private var live: (snapshot: Snapshot?, link: LinkInfo?) = (nil, nil)
    private var current = Status()
    private var failures = 0
    private var skipUntil: Int64 = 0

    /// Called on the uploader's queue whenever the status changes.
    public var onStatus: ((Status) -> Void)?

    /// `backfillMs`: how much existing history a first upload carries. `sliceMs`: how much one request carries while catching up.
    public init(store: HistoryStore, client: HubClient, token: String, appVersion: String, backfillMs: Int64 = 24 * 3600 * 1000,
                sliceMs: Int64 = 300_000, now: @escaping () -> Int64 = { Date().msSince1970 }) {
        self.store = store; self.client = client; self.token = token; self.appVersion = appVersion
        self.backfillMs = backfillMs; self.sliceMs = sliceMs; self.now = now
    }

    public var status: Status { lock.lock(); defer { lock.unlock() }; return current }

    /// The Mac's state right now; sent along with every upload so the fleet overview is current.
    public func setLive(snapshot: Snapshot?) { lock.lock(); live.snapshot = snapshot; lock.unlock() }
    public func setLive(link: LinkInfo?) { lock.lock(); live.link = link; lock.unlock() }

    public func start(every seconds: Double = 10) {
        stop()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 2, repeating: seconds, leeway: .seconds(1))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            // After failures, wait longer between attempts (up to five minutes) instead of knocking every ten seconds.
            guard self.now() >= self.skipUntil else { return }
            self.runOnce()
        }
        t.resume()
        timer = t
    }

    public func stop() { timer?.cancel(); timer = nil }

    /// One round: sends slices until the hub has everything, or stops at the first failure. Returns the resulting status.
    @discardableResult public func runOnce(maxSlices: Int = 60) -> Status {
        var cursor: UploadCursor
        if let saved = store.uploadCursor() { cursor = saved } else {
            cursor = store.uploadCursor(startingAt: now() - backfillMs)
            store.setUploadCursor(cursor)
        }
        var next = Status(state: .upToDate, lastSuccess: status.lastSuccess)
        var batch = store.exportBatch(after: cursor, limitMs: sliceMs)
        for slice in 0..<maxSlices {
            lock.lock(); let (snapshot, link) = live; lock.unlock()
            batch.sentAt = now(); batch.appVersion = appVersion
            batch.intervalS = snapshot?.intervalSeconds ?? 2
            batch.snapshot = snapshot; batch.linkNow = link
            switch client.ingest(batch, token: token) {
            case .success(let reply):
                cursor = reply.accepted
                store.setUploadCursor(cursor)
                next.lastSuccess = now()
                failures = 0; skipUntil = 0
            case .failure(.unreachable):
                next.state = .unreachable
                backOff()
                return publish(next)
            case .failure(.rejected(let status, let message)):
                // 401 and 403 mean this Mac is no longer welcome; anything else is the hub's trouble and worth retrying.
                next.state = status == 401 || status == 403 ? .rejected(message) : .unreachable
                backOff()
                return publish(next)
            }
            batch = store.exportBatch(after: cursor, limitMs: sliceMs)
            if batch.hasNoHistory { break }
            if slice == maxSlices - 1 { next.state = .catchingUp }
        }
        return publish(next)
    }

    private func backOff() {
        failures += 1
        skipUntil = now() + min(300_000, Int64(10_000) << Int64(min(failures, 5)))
    }

    private func publish(_ status: Status) -> Status {
        lock.lock(); let changed = current != status; current = status; lock.unlock()
        if changed { onStatus?(status) }
        return status
    }
}
