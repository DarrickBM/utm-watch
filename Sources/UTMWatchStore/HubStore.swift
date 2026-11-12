import Foundation
import UTMWatchModel

public enum HubError: Error, Equatable {
    case unauthorized
    case notFound
    case badRequest(String)
}

/// The fleet's data pool: the history of every enrolled Mac in one SQLite file.
/// The tables mirror `HistoryStore` with a host dimension, and reads go through the same `HistoryReader`,
/// so a host's history read from the hub equals what that Mac reads from its own database.
/// All access is serialized on an internal queue; every method is synchronous.
public final class HubStore {
    public let path: String
    private let db: Database
    private let queue = DispatchQueue(label: "utmwatch.hub")

    public static let schemaVersion: Int64 = 3
    /// A Mac that has not uploaded for this long is shown as offline.
    public static let offlineAfterMs: Int64 = 60_000
    /// Rows stamped further ahead of the hub's clock than this are dropped: a badly wrong clock must not plant "future" history.
    public static let maxFutureMs: Int64 = 600_000

    public init(path: String) throws {
        self.path = path
        db = try Database(path: path)
        try db.exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")
        let found: Int64 = try {
            let version = try db.prepare("PRAGMA user_version")
            let v = version.step() ? version.int(0) : 0
            version.reset()
            return v
        }()
        guard found <= HubStore.schemaVersion else {
            throw SQLiteError(message: "hub database has schema \(found), newer than this hub (\(HubStore.schemaVersion)); update the hub")
        }
        // Unlike the local store, the hub migrates step by step and never drops history.
        if found < 1 { try createV1() }
        // 2: remembers whether a Mac's going offline has been put on the timeline, so it is written once.
        if found < 2 { try db.exec("ALTER TABLE host ADD COLUMN noted_offline INTEGER NOT NULL DEFAULT 0") }
        // 3: seeing the fleet is no longer given to every Mac that joins. A pairing code says whether its Mac may
        // view; Macs that joined before lose the view (the hub Mac gives it back to itself).
        if found < 3 {
            try db.exec("ALTER TABLE enroll_token ADD COLUMN view INTEGER NOT NULL DEFAULT 0")
            if found >= 1 { try db.exec("DELETE FROM reader_token WHERE label LIKE 'host:%'") }
        }
        try db.exec("PRAGMA user_version = \(HubStore.schemaVersion)")
    }

    private func createV1() throws {
        try db.exec("""
        CREATE TABLE IF NOT EXISTS host(id INTEGER PRIMARY KEY, uuid TEXT UNIQUE NOT NULL, name TEXT NOT NULL, token_hash TEXT NOT NULL,
            enrolled_at INTEGER, last_seen INTEGER, skew_ms INTEGER, app_version TEXT, interval_s REAL,
            rolled_sample INTEGER, rolled_probe INTEGER, snapshot TEXT, link TEXT, revoked INTEGER NOT NULL DEFAULT 0);
        CREATE INDEX IF NOT EXISTS host_token ON host(token_hash);
        CREATE TABLE IF NOT EXISTS enroll_token(hash TEXT PRIMARY KEY, created INTEGER, expires INTEGER, used_by INTEGER);
        CREATE TABLE IF NOT EXISTS reader_token(hash TEXT PRIMARY KEY, label TEXT, created INTEGER);
        CREATE TABLE IF NOT EXISTS vm(id INTEGER PRIMARY KEY, host_id INTEGER NOT NULL, key TEXT NOT NULL, name TEXT NOT NULL, backend TEXT NOT NULL,
            UNIQUE(host_id, key));
        CREATE TABLE IF NOT EXISTS target(id INTEGER PRIMARY KEY, host_id INTEGER NOT NULL, name TEXT NOT NULL, UNIQUE(host_id, name));
        CREATE TABLE IF NOT EXISTS vm_config(vm_id INTEGER NOT NULL, ts INTEGER NOT NULL, cores INTEGER, mem REAL, PRIMARY KEY(vm_id, ts)) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS sample(vm_id INTEGER NOT NULL, ts INTEGER NOT NULL, cpu REAL, mem REAL, down REAL, up REAL,
            down_total REAL, up_total REAL, disk_read REAL, disk_write REAL, res REAL, PRIMARY KEY(vm_id, ts)) WITHOUT ROWID;
        CREATE INDEX IF NOT EXISTS sample_ts ON sample(ts);
        CREATE TABLE IF NOT EXISTS host_sample(host_id INTEGER NOT NULL, ts INTEGER NOT NULL, used REAL, other REAL, allocatable REAL, pressure INTEGER,
            swap_used REAL, swap_total REAL, cores INTEGER, cpu REAL, PRIMARY KEY(host_id, ts)) WITHOUT ROWID;
        CREATE INDEX IF NOT EXISTS host_sample_ts ON host_sample(ts);
        CREATE TABLE IF NOT EXISTS sample_1m(vm_id INTEGER NOT NULL, minute INTEGER NOT NULL, cpu_avg REAL, cpu_max REAL, mem_avg REAL,
            down_avg REAL, down_max REAL, up_avg REAL, up_max REAL, down_total REAL, up_total REAL, disk_read REAL, disk_write REAL, res_avg REAL,
            PRIMARY KEY(vm_id, minute)) WITHOUT ROWID;
        CREATE INDEX IF NOT EXISTS sample_1m_minute ON sample_1m(minute);
        CREATE TABLE IF NOT EXISTS host_1m(host_id INTEGER NOT NULL, minute INTEGER NOT NULL, used REAL, other REAL, allocatable REAL, pressure INTEGER,
            swap_used REAL, swap_total REAL, cores INTEGER, cpu REAL, PRIMARY KEY(host_id, minute)) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS probe(target_id INTEGER NOT NULL, ts INTEGER NOT NULL, rtt REAL, ok INTEGER NOT NULL, PRIMARY KEY(target_id, ts)) WITHOUT ROWID;
        CREATE INDEX IF NOT EXISTS probe_ts ON probe(ts);
        CREATE TABLE IF NOT EXISTS probe_1m(target_id INTEGER NOT NULL, minute INTEGER NOT NULL, rtt_avg REAL, rtt_max REAL, sent INTEGER, lost INTEGER,
            PRIMARY KEY(target_id, minute)) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS link_sample(host_id INTEGER NOT NULL, ts INTEGER NOT NULL, kind TEXT NOT NULL, iface TEXT, rssi REAL, noise REAL,
            tx_rate REAL, channel INTEGER, speed REAL, PRIMARY KEY(host_id, ts)) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS event(id INTEGER PRIMARY KEY, host_id INTEGER NOT NULL, ts INTEGER NOT NULL, kind TEXT NOT NULL,
            vm_key TEXT NOT NULL DEFAULT '', label TEXT NOT NULL, detail TEXT, origin TEXT NOT NULL DEFAULT 'agent',
            UNIQUE(host_id, ts, kind, vm_key));
        CREATE INDEX IF NOT EXISTS event_ts ON event(ts);
        """)
    }

    // MARK: Tokens

    /// A single-use code a Mac presents to join the fleet. `view` lets that Mac see the whole fleet as well as report
    /// to it; without it the Mac only reports, and learns nothing about the others.
    public func createEnrollToken(now: Int64, ttlMs: Int64 = 24 * 3600 * 1000, view: Bool = false) -> String {
        let token = FleetToken.make(prefix: "e_")
        queue.sync {
            _ = try? db.prepare("INSERT INTO enroll_token(hash, created, expires, view) VALUES(?,?,?,?)")
                .bind(1, FleetToken.hash(token)).bind(2, now).bind(3, now + ttlMs).bind(4, Int64(view ? 1 : 0)).run()
        }
        return token
    }

    /// Lets an enrolled Mac see the fleet, replacing any view token it had. nil if the Mac is unknown or revoked.
    public func grantView(hostUUID: String, now: Int64) -> String? {
        queue.sync {
            guard let q = try? db.prepare("SELECT 1 FROM host WHERE uuid = ? AND revoked = 0").bind(1, hostUUID), q.step() else { return nil }
            let token = FleetToken.make(prefix: "r_"), label = "host:" + hostUUID
            _ = try? db.prepare("DELETE FROM reader_token WHERE label = ?").bind(1, label).run()
            guard (try? db.prepare("INSERT INTO reader_token(hash, label, created) VALUES(?,?,?)")
                .bind(1, FleetToken.hash(token)).bind(2, label).bind(3, now).run()) != nil else { return nil }
            return token
        }
    }

    /// A token that may read the fleet (the fleet view, later a phone).
    public func createReaderToken(label: String, now: Int64) -> String {
        let token = FleetToken.make(prefix: "r_")
        queue.sync {
            _ = try? db.prepare("INSERT INTO reader_token(hash, label, created) VALUES(?,?,?)")
                .bind(1, FleetToken.hash(token)).bind(2, label).bind(3, now).run()
        }
        return token
    }

    public func isReader(_ token: String) -> Bool {
        queue.sync {
            guard let q = try? db.prepare("SELECT 1 FROM reader_token WHERE hash = ?").bind(1, FleetToken.hash(token)) else { return false }
            return q.step()
        }
    }

    /// The internal id of the Mac this token belongs to, or nil if it is unknown or revoked.
    public func hostID(forToken token: String) -> Int64? {
        queue.sync {
            guard let q = try? db.prepare("SELECT id FROM host WHERE token_hash = ? AND revoked = 0").bind(1, FleetToken.hash(token)), q.step() else { return nil }
            return q.int(0)
        }
    }

    /// Trades an enrolment code for the Mac's own token. Enrolling a known UUID again replaces its token and keeps its history.
    public func enroll(token: String, request r: EnrollRequest, now: Int64) throws -> EnrollReply {
        guard !r.hostUUID.isEmpty, r.hostUUID.count <= 64, !r.name.isEmpty, r.name.count <= 200 else { throw HubError.badRequest("host UUID and name are required") }
        return try queue.sync {
            let hash = FleetToken.hash(token)
            let q = try db.prepare("SELECT view FROM enroll_token WHERE hash = ? AND used_by IS NULL AND expires > ?").bind(1, hash).bind(2, now)
            guard q.step() else { throw HubError.unauthorized }
            let mayView = q.int(0) != 0
            q.reset()
            let hostToken = FleetToken.make(prefix: "h_")
            let readerToken = FleetToken.make(prefix: "r_")
            let readerLabel = "host:" + r.hostUUID
            try db.exec("BEGIN")
            do {
                try db.prepare("""
                    INSERT INTO host(uuid, name, token_hash, enrolled_at, app_version) VALUES(?1, ?2, ?3, ?4, ?5)
                    ON CONFLICT(uuid) DO UPDATE SET name = ?2, token_hash = ?3, app_version = ?5, revoked = 0
                    """).bind(1, r.hostUUID).bind(2, r.name).bind(3, FleetToken.hash(hostToken)).bind(4, now).bind(5, r.appVersion).run()
                let id = try db.prepare("SELECT id FROM host WHERE uuid = ?").bind(1, r.hostUUID)
                guard id.step() else { throw HubError.badRequest("could not store the host") }
                try db.prepare("UPDATE enroll_token SET used_by = ? WHERE hash = ?").bind(1, id.int(0)).bind(2, hash).run()
                // The Mac's own reader token, if its code allows it: one per Mac, replaced or withdrawn when it enrols again.
                try db.prepare("DELETE FROM reader_token WHERE label = ?").bind(1, readerLabel).run()
                if mayView {
                    try db.prepare("INSERT INTO reader_token(hash, label, created) VALUES(?,?,?)").bind(1, FleetToken.hash(readerToken)).bind(2, readerLabel).bind(3, now).run()
                }
                id.reset()
                try db.exec("COMMIT")
            } catch {
                try? db.exec("ROLLBACK")
                throw error
            }
            return EnrollReply(hostToken: hostToken, readerToken: mayView ? readerToken : nil)
        }
    }

    /// Stops a Mac from uploading. Its history stays until it ages out.
    @discardableResult public func revoke(hostUUID: String) -> Bool {
        queue.sync {
            guard let q = try? db.prepare("UPDATE host SET revoked = 1 WHERE uuid = ? RETURNING id").bind(1, hostUUID) else { return false }
            let found = q.step()
            q.reset()
            // A revoked Mac loses its view of the fleet as well.
            _ = try? db.prepare("DELETE FROM reader_token WHERE label = ?").bind(1, "host:" + hostUUID).run()
            return found
        }
    }

    // MARK: Writing

    private static func int(_ d: Double?) -> Int64? {
        guard let d, d.isFinite, abs(d) < 9e15 else { return nil }
        return Int64(d)
    }

    /// Stores one upload. Safe to repeat: every row is keyed, so the same batch twice changes nothing.
    public func ingest(_ b: IngestBatch, hostID: Int64, now: Int64) throws {
        try queue.sync {
            try db.exec("BEGIN")
            do {
                let limit = now + HubStore.maxFutureMs
                var vmIDs: [Int64] = []
                for vm in b.vms {
                    try db.prepare("""
                        INSERT INTO vm(host_id, key, name, backend) VALUES(?1, ?2, ?3, ?4)
                        ON CONFLICT(host_id, key) DO UPDATE SET name = ?3, backend = ?4
                        """).bind(1, hostID).bind(2, vm.key).bind(3, vm.name).bind(4, vm.backend).run()
                    let q = try db.prepare("SELECT id FROM vm WHERE host_id = ? AND key = ?").bind(1, hostID).bind(2, vm.key)
                    guard q.step() else { throw HubError.badRequest("could not store a VM") }
                    vmIDs.append(q.int(0))
                }
                let insConfig = try db.prepare("INSERT OR REPLACE INTO vm_config VALUES(?,?,?,?)")
                for c in b.configs where vmIDs.indices.contains(c.vm) && c.ts <= limit {
                    insConfig.bind(1, vmIDs[c.vm]).bind(2, c.ts).bind(3, c.cores.map(Int64.init)).bind(4, c.mem).run()
                }

                var sampleMin = Int64.max, sampleMax = Int64.min
                let insSample = try db.prepare("INSERT OR REPLACE INTO sample VALUES(?,?,?,?,?,?,?,?,?,?,?)")
                for r in b.samples where r.count == 11 {
                    guard let i = HubStore.int(r[0]).map(Int.init), vmIDs.indices.contains(i), let ts = HubStore.int(r[1]), ts <= limit else { continue }
                    insSample.bind(1, vmIDs[i]).bind(2, ts)
                    for col in 2..<11 { insSample.bind(Int32(col + 1), r[col]) }
                    insSample.run()
                }
                let insHost = try db.prepare("INSERT OR REPLACE INTO host_sample VALUES(?,?,?,?,?,?,?,?,?,?)")
                for r in b.host where r.count == 9 {
                    guard let ts = HubStore.int(r[0]), ts <= limit else { continue }
                    insHost.bind(1, hostID).bind(2, ts).bind(3, r[1]).bind(4, r[2]).bind(5, r[3]).bind(6, HubStore.int(r[4]))
                        .bind(7, r[5]).bind(8, r[6]).bind(9, HubStore.int(r[7])).bind(10, r[8]).run()
                    sampleMin = min(sampleMin, ts); sampleMax = max(sampleMax, ts)
                }

                var targetIDs: [Int64] = []
                for name in b.targets {
                    try db.prepare("INSERT OR IGNORE INTO target(host_id, name) VALUES(?, ?)").bind(1, hostID).bind(2, name).run()
                    let q = try db.prepare("SELECT id FROM target WHERE host_id = ? AND name = ?").bind(1, hostID).bind(2, name)
                    guard q.step() else { throw HubError.badRequest("could not store a ping target") }
                    targetIDs.append(q.int(0))
                }
                var probeMin = Int64.max, probeMax = Int64.min
                let insProbe = try db.prepare("INSERT OR REPLACE INTO probe VALUES(?,?,?,?)")
                for r in b.probes where r.count == 4 {
                    guard let i = HubStore.int(r[0]).map(Int.init), targetIDs.indices.contains(i), let ts = HubStore.int(r[1]), ts <= limit else { continue }
                    insProbe.bind(1, targetIDs[i]).bind(2, ts).bind(3, r[2]).bind(4, HubStore.int(r[3]) ?? 0).run()
                    probeMin = min(probeMin, ts); probeMax = max(probeMax, ts)
                }
                let insLink = try db.prepare("INSERT OR REPLACE INTO link_sample VALUES(?,?,?,?,?,?,?,?,?)")
                for l in b.link where l.ts <= limit {
                    insLink.bind(1, hostID).bind(2, l.ts).bind(3, l.kind).bind(4, l.iface).bind(5, l.rssi).bind(6, l.noise).bind(7, l.txRate)
                        .bind(8, l.channel.map(Int64.init)).bind(9, l.speed).run()
                }
                let insEvent = try db.prepare("INSERT OR IGNORE INTO event(host_id, ts, kind, vm_key, label, detail) VALUES(?,?,?,?,?,?)")
                for e in b.events where e.ts <= limit {
                    insEvent.bind(1, hostID).bind(2, e.ts).bind(3, e.kind).bind(4, e.vmKey ?? "").bind(5, e.label).bind(6, e.detail).run()
                }

                // Rollups advance per host and per stream: a Mac catching up after an outage sends old minutes,
                // and its samples and pings do not arrive in step.
                let state = try db.prepare("SELECT rolled_sample, rolled_probe, interval_s FROM host WHERE id = ?").bind(1, hostID)
                guard state.step() else { throw HubError.unauthorized }
                var rolledSample = state.intOrNil(0), rolledProbe = state.intOrNil(1)
                state.reset()
                let scope = StoreScope.host(hostID, rawMs: b.intervalS * 1000)
                if sampleMax > Int64.min {
                    let from = rolledSample ?? sampleMin / 60000, to = sampleMax / 60000
                    if to > from { try HistoryReader.rollSamples(db, scope: scope, fromMinute: from, toMinute: to); rolledSample = to }
                    else if rolledSample == nil { rolledSample = from }
                }
                if probeMax > Int64.min {
                    let from = rolledProbe ?? probeMin / 60000, to = probeMax / 60000
                    if to > from { try HistoryReader.rollProbes(db, scope: scope, fromMinute: from, toMinute: to); rolledProbe = to }
                    else if rolledProbe == nil { rolledProbe = from }
                }

                let snapshot = b.snapshot.map { String(decoding: FleetAPI.encode($0), as: UTF8.self) }
                let link = b.linkNow.map { String(decoding: FleetAPI.encode($0), as: UTF8.self) }
                try db.prepare("""
                    UPDATE host SET last_seen = ?2, skew_ms = ?3, app_version = ?4, interval_s = ?5, rolled_sample = ?6, rolled_probe = ?7,
                        snapshot = coalesce(?8, snapshot), link = coalesce(?9, link) WHERE id = ?1
                    """).bind(1, hostID).bind(2, now).bind(3, now - b.sentAt).bind(4, b.appVersion).bind(5, b.intervalS)
                    .bind(6, rolledSample).bind(7, rolledProbe).bind(8, snapshot).bind(9, link).run()
                try db.exec("COMMIT")
            } catch {
                try? db.exec("ROLLBACK")
                throw error
            }
        }
    }

    // MARK: Reading

    /// Every enrolled Mac with its latest state. Revoked Macs are left out.
    public func hosts(now: Int64) -> [HostStatus] {
        queue.sync {
            var out: [HostStatus] = []
            guard let q = try? db.prepare("""
                SELECT uuid, name, last_seen, skew_ms, app_version, snapshot, link,
                       (SELECT kind FROM event WHERE host_id = host.id AND kind IN ('sleep', 'wake') ORDER BY ts DESC, id DESC LIMIT 1)
                FROM host WHERE revoked = 0 ORDER BY name COLLATE NOCASE, id
                """) else { return out }
            while q.step() {
                let seen = q.intOrNil(2)
                let online = seen.map { now - $0 < HubStore.offlineAfterMs } ?? false
                let state = online ? "online" : (q.textOrNil(7) == "sleep" ? "asleep" : "offline")
                out.append(HostStatus(uuid: q.text(0), name: q.text(1), state: state, lastSeen: seen, skewMs: q.intOrNil(3),
                                      appVersion: q.textOrNil(4),
                                      snapshot: q.textOrNil(5).flatMap { FleetAPI.decode(Snapshot.self, from: Data($0.utf8)) },
                                      link: q.textOrNil(6).flatMap { FleetAPI.decode(LinkInfo.self, from: Data($0.utf8)) }))
            }
            return out
        }
    }

    /// One Mac's history for a time frame, exactly as `HistoryStore.load` would give it on that Mac. nil for an unknown Mac.
    public func load(hostUUID: String, from: Int64, to: Int64, maxPoints: Int?) -> History? {
        queue.sync {
            guard let q = try? db.prepare("SELECT id, interval_s FROM host WHERE uuid = ? AND revoked = 0").bind(1, hostUUID), q.step() else { return nil }
            let id = q.int(0), interval = q.doubleOrNil(1) ?? 2
            q.reset()
            var h = History(from: from, to: to)
            do {
                try HistoryReader.fill(&h, db: db, scope: .host(id, rawMs: interval * 1000), maxPoints: maxPoints)
            } catch {
                FileLog.shared.log("hub load failed: \(error)")
            }
            return h
        }
    }

    /// Events across the fleet, oldest first. `after` is a hub event id: pass the last one seen to get only newer events.
    public func events(from: Int64? = nil, to: Int64? = nil, hostUUID: String? = nil, after: Int64? = nil, limit: Int = 1000) -> [FleetEvent] {
        queue.sync {
            var out: [FleetEvent] = []
            guard let q = try? db.prepare("""
                SELECT e.id, h.uuid, h.name, e.ts, e.kind, NULLIF(e.vm_key, ''), e.label, e.detail, e.origin
                FROM event e JOIN host h ON h.id = e.host_id
                WHERE h.revoked = 0 AND e.ts >= ?1 AND e.ts <= ?2 AND e.id > ?3 AND (?4 IS NULL OR h.uuid = ?4)
                ORDER BY e.id LIMIT ?5
                """).bind(1, from ?? 0).bind(2, to ?? Int64.max).bind(3, after ?? 0).bind(4, hostUUID).bind(5, Int64(limit)) else { return out }
            while q.step() {
                out.append(FleetEvent(id: q.int(0), hostUUID: q.text(1), hostName: q.text(2), ts: q.int(3), kind: q.text(4), vmKey: q.textOrNil(5),
                                      label: q.text(6), detail: q.textOrNil(7), origin: q.text(8)))
            }
            return out
        }
    }

    /// Puts Macs going silent and coming back on the fleet timeline. Only the hub can see this: a Mac that is off
    /// cannot say so. Call it every few seconds; each change is written once. Times are the hub's own.
    @discardableResult public func noteOfflineChanges(now: Int64) -> [FleetEvent] {
        queue.sync {
            var changes: [(id: Int64, name: String, offline: Bool, asleep: Bool)] = []
            guard let q = try? db.prepare("""
                SELECT id, name, last_seen, noted_offline,
                       (SELECT kind FROM event WHERE host_id = host.id AND kind IN ('sleep', 'wake') ORDER BY ts DESC, id DESC LIMIT 1)
                FROM host WHERE revoked = 0 AND last_seen IS NOT NULL
                """) else { return [] }
            while q.step() {
                let offline = now - q.int(2) >= HubStore.offlineAfterMs
                if offline != (q.int(3) != 0) { changes.append((q.int(0), q.text(1), offline, q.textOrNil(4) == "sleep")) }
            }
            var firstID: Int64?
            for c in changes {
                let kind = c.offline ? (c.asleep ? "host_asleep" : "host_offline") : "host_online"
                let label = c.offline ? (c.asleep ? "\(c.name) went to sleep" : "\(c.name) stopped reporting") : "\(c.name) is reporting again"
                _ = try? db.prepare("INSERT OR IGNORE INTO event(host_id, ts, kind, vm_key, label, origin) VALUES(?,?,?,'',?,'hub')")
                    .bind(1, c.id).bind(2, now).bind(3, kind).bind(4, label).run()
                if firstID == nil { firstID = db.lastInsertRowID }
                _ = try? db.prepare("UPDATE host SET noted_offline = ? WHERE id = ?").bind(1, Int64(c.offline ? 1 : 0)).bind(2, c.id).run()
            }
            guard let firstID else { return [] }
            var out: [FleetEvent] = []
            if let e = try? db.prepare("""
                SELECT e.id, h.uuid, h.name, e.ts, e.kind, e.label FROM event e JOIN host h ON h.id = e.host_id
                WHERE e.id >= ? AND e.origin = 'hub' ORDER BY e.id
                """).bind(1, firstID) {
                while e.step() {
                    out.append(FleetEvent(id: e.int(0), hostUUID: e.text(1), hostName: e.text(2), ts: e.int(3), kind: e.text(4), vmKey: nil, label: e.text(5), detail: nil, origin: "hub"))
                }
            }
            return out
        }
    }

    // MARK: Maintenance

    /// Deletes raw samples older than `rawCutoff` and rollups and events older than `rollupCutoff`.
    public func prune(rawOlderThan rawCutoff: Int64, rollupsOlderThan rollupCutoff: Int64) {
        queue.sync {
            do {
                try db.exec("BEGIN")
                for table in ["sample", "host_sample", "probe", "link_sample"] {
                    try db.prepare("DELETE FROM \(table) WHERE ts < ?").bind(1, rawCutoff).run()
                }
                for table in ["sample_1m", "host_1m", "probe_1m"] {
                    try db.prepare("DELETE FROM \(table) WHERE minute < ?").bind(1, rollupCutoff / 60000).run()
                }
                try db.prepare("DELETE FROM event WHERE ts < ?").bind(1, rollupCutoff).run()
                try db.prepare("DELETE FROM enroll_token WHERE expires < ?").bind(1, rawCutoff).run()
                // VM processes that were never matched to a UTM bundle get a new key on every start; drop the ones with no history left.
                try db.exec("""
                    DELETE FROM vm WHERE key LIKE 'pid:%' AND id NOT IN (SELECT DISTINCT vm_id FROM sample)
                        AND id NOT IN (SELECT DISTINCT vm_id FROM sample_1m)
                    """)
                try db.exec("DELETE FROM vm_config WHERE vm_id NOT IN (SELECT id FROM vm)")
                try db.exec("COMMIT")
            } catch {
                try? db.exec("ROLLBACK")
                FileLog.shared.log("hub prune failed: \(error)")
            }
        }
    }
}
