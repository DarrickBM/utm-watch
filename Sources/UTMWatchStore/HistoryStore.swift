import Foundation
import UTMWatchCore

/// Recorded history in one SQLite file. All access is serialized on an internal queue;
/// every public method is synchronous, so call the slow ones off the main thread.
public final class HistoryStore {
    public let path: String
    private let db: Database
    private let queue = DispatchQueue(label: "utmwatch.store")
    private var vmIDs: [String: Int64] = [:]
    private var vmNames: [String: String] = [:]
    private var lastConfig: [String: VMConfig] = [:]

    /// Frames longer than this read the 1-minute rollups instead of raw samples.
    public static let rollupThresholdMs: Int64 = 2 * 3600 * 1000

    public static var defaultPath: String {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("UTM Watch", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.sqlite").path
    }

    public static let schemaVersion: Int64 = 2

    /// `readOnly` is for other processes (the MCP helper): it never creates, migrates or writes.
    public init(path: String = HistoryStore.defaultPath, readOnly: Bool = false) throws {
        self.path = path
        db = try Database(path: path, readOnly: readOnly)
        // Read and finish this statement before anything else: an unfinished read keeps a transaction open.
        let found: Int64 = try {
            let version = try db.prepare("PRAGMA user_version")
            let v = version.step() ? version.int(0) : 0
            version.reset()
            return v
        }()
        if readOnly {
            guard found == HistoryStore.schemaVersion else {
                throw SQLiteError(message: "history database has schema \(found), expected \(HistoryStore.schemaVersion); open UTM Watch once to update it")
            }
        } else {
            try db.exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")
            if found != HistoryStore.schemaVersion {
                // History from an older layout is dropped rather than migrated: it is a few days of samples at most.
                for t in ["meta", "vm", "vm_config", "sample", "host_sample", "sample_1m", "host_1m", "event", "probe", "probe_1m", "link_sample"] {
                    try db.exec("DROP TABLE IF EXISTS \(t)")
                }
                if found != 0 { FileLog.shared.log("history schema changed (\(found) -> \(HistoryStore.schemaVersion)); old history dropped") }
            }
            try createSchema()
            try db.exec("PRAGMA user_version = \(HistoryStore.schemaVersion)")
        }
        try loadCaches()
    }

    private func createSchema() throws {
        try db.exec("""
        CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v INTEGER);
        CREATE TABLE IF NOT EXISTS vm(id INTEGER PRIMARY KEY, key TEXT UNIQUE NOT NULL, name TEXT NOT NULL, backend TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS vm_config(vm_id INTEGER NOT NULL, ts INTEGER NOT NULL, cores INTEGER, mem REAL, PRIMARY KEY(vm_id, ts)) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS sample(vm_id INTEGER NOT NULL, ts INTEGER NOT NULL, cpu REAL, mem REAL, down REAL, up REAL,
            down_total REAL, up_total REAL, disk_read REAL, disk_write REAL, PRIMARY KEY(vm_id, ts)) WITHOUT ROWID;
        CREATE INDEX IF NOT EXISTS sample_ts ON sample(ts);
        CREATE TABLE IF NOT EXISTS host_sample(ts INTEGER PRIMARY KEY, used REAL, other REAL, allocatable REAL, pressure INTEGER,
            swap_used REAL, swap_total REAL, cores INTEGER, cpu REAL) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS sample_1m(vm_id INTEGER NOT NULL, minute INTEGER NOT NULL, cpu_avg REAL, cpu_max REAL, mem_avg REAL,
            down_avg REAL, down_max REAL, up_avg REAL, up_max REAL, down_total REAL, up_total REAL, disk_read REAL, disk_write REAL,
            PRIMARY KEY(vm_id, minute)) WITHOUT ROWID;
        CREATE INDEX IF NOT EXISTS sample_1m_minute ON sample_1m(minute);
        CREATE TABLE IF NOT EXISTS host_1m(minute INTEGER PRIMARY KEY, used REAL, other REAL, allocatable REAL, pressure INTEGER,
            swap_used REAL, swap_total REAL, cores INTEGER, cpu REAL) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS event(id INTEGER PRIMARY KEY, ts INTEGER NOT NULL, kind TEXT NOT NULL, vm_key TEXT, label TEXT NOT NULL, detail TEXT);
        CREATE TABLE IF NOT EXISTS probe(target TEXT NOT NULL, ts INTEGER NOT NULL, rtt REAL, ok INTEGER NOT NULL, PRIMARY KEY(target, ts)) WITHOUT ROWID;
        CREATE INDEX IF NOT EXISTS probe_ts ON probe(ts);
        CREATE TABLE IF NOT EXISTS probe_1m(target TEXT NOT NULL, minute INTEGER NOT NULL, rtt_avg REAL, rtt_max REAL, sent INTEGER, lost INTEGER,
            PRIMARY KEY(target, minute)) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS link_sample(ts INTEGER PRIMARY KEY, kind TEXT NOT NULL, iface TEXT, rssi REAL, noise REAL, tx_rate REAL,
            channel INTEGER, speed REAL) WITHOUT ROWID;
        CREATE INDEX IF NOT EXISTS event_ts ON event(ts);
        """)
    }

    private func loadCaches() throws {
        vmIDs = [:]; vmNames = [:]; lastConfig = [:]
        let vms = try db.prepare("SELECT id, key, name FROM vm")
        var keyByID: [Int64: String] = [:]
        while vms.step() { vmIDs[vms.text(1)] = vms.int(0); vmNames[vms.text(1)] = vms.text(2); keyByID[vms.int(0)] = vms.text(1) }
        let cfg = try db.prepare("SELECT vm_id, ts, cores, mem FROM vm_config ORDER BY vm_id, ts")
        while cfg.step() {
            guard let key = keyByID[cfg.int(0)] else { continue }
            lastConfig[key] = VMConfig(ts: cfg.int(1), cores: cfg.intOrNil(2).map(Int.init), memBytes: cfg.doubleOrNil(3))
        }
    }

    // MARK: Writing

    /// Appends a batch of snapshots and events in one transaction, then rolls up any completed minutes.
    public func write(snapshots: [Snapshot], events: [HistoryEvent] = [], probes: [ProbeResult] = []) {
        guard !snapshots.isEmpty || !events.isEmpty || !probes.isEmpty else { return }
        queue.sync {
            do {
                try db.exec("BEGIN")
                let insSample = try db.prepare("INSERT OR REPLACE INTO sample VALUES(?,?,?,?,?,?,?,?,?,?)")
                let insHost = try db.prepare("INSERT OR REPLACE INTO host_sample VALUES(?,?,?,?,?,?,?,?,?)")
                let insProbe = try db.prepare("INSERT OR REPLACE INTO probe VALUES(?,?,?,?)")
                let insLink = try db.prepare("INSERT OR REPLACE INTO link_sample VALUES(?,?,?,?,?,?,?,?)")
                let insConfig = try db.prepare("INSERT OR REPLACE INTO vm_config VALUES(?,?,?,?)")
                let insEvent = try db.prepare("INSERT INTO event(ts, kind, vm_key, label, detail) VALUES(?,?,?,?,?)")
                for snap in snapshots {
                    let ts = snap.timestamp.msSince1970
                    for row in snap.rows where row.pid != nil {
                        let id = try vmID(for: row)
                        let cfg = VMConfig(ts: ts, cores: row.cpuAllocated, memBytes: row.memoryAllocatedBytes.map { Double($0) })
                        let last = lastConfig[row.id]
                        if (cfg.cores != nil || cfg.memBytes != nil), last?.cores != cfg.cores || last?.memBytes != cfg.memBytes {
                            insConfig.bind(1, id).bind(2, ts).bind(3, cfg.cores.map(Int64.init)).bind(4, cfg.memBytes).run()
                            lastConfig[row.id] = cfg
                        }
                        let p = VMPoint(row: row, ts: ts)
                        insSample.bind(1, id).bind(2, ts).bind(3, p.cpu).bind(4, p.mem).bind(5, p.down).bind(6, p.up)
                            .bind(7, p.downTotal).bind(8, p.upTotal).bind(9, p.diskRead).bind(10, p.diskWrite).run()
                    }
                    let h = HostPoint(snapshot: snap)
                    insHost.bind(1, h.t).bind(2, h.used).bind(3, h.other).bind(4, h.allocatable).bind(5, Int64(h.pressure))
                        .bind(6, h.swapUsed).bind(7, h.swapTotal).bind(8, Int64(h.cores)).bind(9, h.cpu).run()
                }
                for e in events { insEvent.bind(1, e.ts).bind(2, e.kind).bind(3, e.vmKey).bind(4, e.label).bind(5, e.detail).run() }
                for p in probes {
                    let ts = p.timestamp.msSince1970
                    for (key, rtt) in p.vmPing {
                        insProbe.bind(1, ProbeTarget.vm(key)).bind(2, ts).bind(3, rtt).bind(4, Int64(rtt == nil ? 0 : 1)).run()
                    }
                    if p.gatewayTried { insProbe.bind(1, ProbeTarget.gateway).bind(2, ts).bind(3, p.gatewayMs).bind(4, Int64(p.gatewayMs == nil ? 0 : 1)).run() }
                    if p.internetTried { insProbe.bind(1, ProbeTarget.internet).bind(2, ts).bind(3, p.internetMs).bind(4, Int64(p.internetMs == nil ? 0 : 1)).run() }
                    for (address, rtt) in p.anchorMs {
                        insProbe.bind(1, ProbeTarget.anchor(address)).bind(2, ts).bind(3, rtt).bind(4, Int64(rtt == nil ? 0 : 1)).run()
                    }
                    let l = LinkPoint(p.link, ts: ts)
                    insLink.bind(1, ts).bind(2, l.kind).bind(3, l.interface).bind(4, l.rssi).bind(5, l.noise).bind(6, l.txRate)
                        .bind(7, l.channel.map { Int64($0) }).bind(8, l.speed).run()
                }
                let lastTs = max(snapshots.last?.timestamp.msSince1970 ?? 0, probes.last?.timestamp.msSince1970 ?? 0)
                if lastTs > 0 { try rollUp(before: lastTs / 60000) }
                try db.exec("COMMIT")
            } catch {
                try? db.exec("ROLLBACK")
                FileLog.shared.log("history write failed: \(error)")
            }
        }
    }

    private func vmID(for row: VMRow) throws -> Int64 {
        if let id = vmIDs[row.id] {
            if vmNames[row.id] != row.name {
                try db.prepare("UPDATE vm SET name = ? WHERE id = ?").bind(1, row.name).bind(2, id).run()
                vmNames[row.id] = row.name
            }
            return id
        }
        try db.prepare("INSERT INTO vm(key, name, backend) VALUES(?,?,?)").bind(1, row.id).bind(2, row.name).bind(3, row.backend.rawValue).run()
        let id = db.lastInsertRowID
        vmIDs[row.id] = id; vmNames[row.id] = row.name
        return id
    }

    /// Writes 1-minute rollups for every completed minute that has not been rolled up yet.
    private func rollUp(before currentMinute: Int64) throws {
        let get = try db.prepare("SELECT v FROM meta WHERE k = 'rolled_until'")
        var from: Int64
        if get.step() { from = get.int(0) } else {
            let first = try db.prepare("SELECT min(ts) FROM (SELECT min(ts) AS ts FROM host_sample UNION ALL SELECT min(ts) FROM probe)")
            guard first.step(), let ts = first.intOrNil(0) else { return }
            from = ts / 60000
        }
        guard currentMinute > from else { return }
        try db.prepare("""
            INSERT OR REPLACE INTO sample_1m
            SELECT vm_id, ts / 60000, avg(cpu), max(cpu), avg(mem), avg(down), max(down), avg(up), max(up), max(down_total), max(up_total),
                   avg(disk_read), avg(disk_write)
            FROM sample WHERE ts >= ? AND ts < ? GROUP BY vm_id, ts / 60000
            """).bind(1, from * 60000).bind(2, currentMinute * 60000).run()
        try db.prepare("""
            INSERT OR REPLACE INTO host_1m
            SELECT ts / 60000, avg(used), avg(other), min(allocatable), max(pressure), max(swap_used), max(swap_total), max(cores), max(cpu)
            FROM host_sample WHERE ts >= ? AND ts < ? GROUP BY ts / 60000
            """).bind(1, from * 60000).bind(2, currentMinute * 60000).run()
        try db.prepare("""
            INSERT OR REPLACE INTO probe_1m
            SELECT target, ts / 60000, avg(rtt), max(rtt), count(*), sum(1 - ok)
            FROM probe WHERE ts >= ? AND ts < ? GROUP BY target, ts / 60000
            """).bind(1, from * 60000).bind(2, currentMinute * 60000).run()
        try db.prepare("INSERT OR REPLACE INTO meta VALUES('rolled_until', ?)").bind(1, currentMinute).run()
    }

    // MARK: Reading

    /// Loads a time frame reduced to at most `maxPoints` points per series.
    /// Pass `maxPoints: nil` for every raw sample (only sensible for short frames).
    public func load(from: Int64, to: Int64, maxPoints: Int?) -> History {
        queue.sync {
            var h = History(from: from, to: to)
            let span = max(1, to - from)
            let useRollup = maxPoints != nil && span > HistoryStore.rollupThresholdMs
            // With no cap, 1-second buckets are finer than any sample interval, i.e. raw data.
            let buckets = Int64(maxPoints ?? Int(max(1, span / 1000)))
            let source: Double = useRollup ? 60000 : 2000
            h.bucketMs = max(source, Double(span) / Double(buckets))
            do {
                let vms = try db.prepare("SELECT id, key, name, backend FROM vm ORDER BY id")
                var keyByID: [Int64: String] = [:]
                var infos: [String: VMInfo] = [:]
                var order: [String] = []
                while vms.step() {
                    keyByID[vms.int(0)] = vms.text(1)
                    infos[vms.text(1)] = VMInfo(key: vms.text(1), name: vms.text(2), backend: vms.text(3))
                    order.append(vms.text(1))
                }

                let sql = useRollup ? """
                    SELECT vm_id, (minute * 60000 + 30000 - ?1) * ?3 / ?4 AS b, CAST(avg(minute * 60000 + 30000) AS INTEGER),
                           avg(cpu_avg), max(cpu_max), avg(mem_avg), avg(down_avg), max(down_max), avg(up_avg), max(up_max), max(down_total), max(up_total),
                           avg(disk_read), avg(disk_write)
                    FROM sample_1m WHERE minute >= ?1 / 60000 AND minute <= ?2 / 60000 GROUP BY vm_id, b ORDER BY vm_id, b
                    """ : """
                    SELECT vm_id, (ts - ?1) * ?3 / ?4 AS b, CAST(avg(ts) AS INTEGER),
                           avg(cpu), max(cpu), avg(mem), avg(down), max(down), avg(up), max(up), max(down_total), max(up_total),
                           avg(disk_read), avg(disk_write)
                    FROM sample WHERE ts >= ?1 AND ts <= ?2 GROUP BY vm_id, b ORDER BY vm_id, b
                    """
                let q = try db.prepare(sql).bind(1, from).bind(2, to).bind(3, buckets).bind(4, span)
                while q.step() {
                    guard let key = keyByID[q.int(0)] else { continue }
                    h.series[key, default: []].append(VMPoint(
                        t: q.int(2), cpu: q.doubleOrNil(3), cpuMax: q.doubleOrNil(4), mem: q.doubleOrNil(5),
                        down: q.doubleOrNil(6), downMax: q.doubleOrNil(7), up: q.doubleOrNil(8), upMax: q.doubleOrNil(9),
                        downTotal: q.doubleOrNil(10), upTotal: q.doubleOrNil(11), diskRead: q.doubleOrNil(12), diskWrite: q.doubleOrNil(13)))
                }
                h.vms = order.filter { h.series[$0] != nil }.compactMap { infos[$0] }

                let hostSQL = useRollup ? """
                    SELECT (minute * 60000 + 30000 - ?1) * ?3 / ?4 AS b, CAST(avg(minute * 60000 + 30000) AS INTEGER), avg(used), avg(other),
                           min(allocatable), max(pressure), max(swap_used), max(swap_total), max(cores), max(cpu)
                    FROM host_1m WHERE minute >= ?1 / 60000 AND minute <= ?2 / 60000 GROUP BY b ORDER BY b
                    """ : """
                    SELECT (ts - ?1) * ?3 / ?4 AS b, CAST(avg(ts) AS INTEGER), avg(used), avg(other),
                           min(allocatable), max(pressure), max(swap_used), max(swap_total), max(cores), max(cpu)
                    FROM host_sample WHERE ts >= ?1 AND ts <= ?2 GROUP BY b ORDER BY b
                    """
                let hq = try db.prepare(hostSQL).bind(1, from).bind(2, to).bind(3, buckets).bind(4, span)
                while hq.step() {
                    h.host.append(HostPoint(t: hq.int(1), used: hq.double(2), other: hq.double(3), allocatable: hq.double(4),
                                            pressure: Int(hq.int(5)), swapUsed: hq.double(6), swapTotal: hq.double(7), cores: Int(hq.int(8)), cpu: hq.doubleOrNil(9)))
                }

                let probeSQL = useRollup ? """
                    SELECT target, (minute * 60000 + 30000 - ?1) * ?3 / ?4 AS b, CAST(avg(minute * 60000 + 30000) AS INTEGER),
                           avg(rtt_avg), max(rtt_max), sum(sent), sum(lost)
                    FROM probe_1m WHERE minute >= ?1 / 60000 AND minute <= ?2 / 60000 GROUP BY target, b ORDER BY target, b
                    """ : """
                    SELECT target, (ts - ?1) * ?3 / ?4 AS b, CAST(avg(ts) AS INTEGER), avg(rtt), max(rtt), count(*), sum(1 - ok)
                    FROM probe WHERE ts >= ?1 AND ts <= ?2 GROUP BY target, b ORDER BY target, b
                    """
                let pq = try db.prepare(probeSQL).bind(1, from).bind(2, to).bind(3, buckets).bind(4, span)
                while pq.step() {
                    h.probes[pq.text(0), default: []].append(ProbePoint(t: pq.int(2), rtt: pq.doubleOrNil(3), rttMax: pq.doubleOrNil(4),
                                                                        sent: Int(pq.int(5)), lost: Int(pq.int(6))))
                }
                let lq = try db.prepare("""
                    SELECT (ts - ?1) * ?3 / ?4 AS b, CAST(avg(ts) AS INTEGER), max(kind), max(iface), avg(rssi), avg(noise), avg(tx_rate), max(channel), avg(speed)
                    FROM link_sample WHERE ts >= ?1 AND ts <= ?2 GROUP BY b ORDER BY b
                    """).bind(1, from).bind(2, to).bind(3, buckets).bind(4, span)
                while lq.step() {
                    h.link.append(LinkPoint(t: lq.int(1), kind: lq.text(2), interface: lq.textOrNil(3), rssi: lq.doubleOrNil(4), noise: lq.doubleOrNil(5),
                                            txRate: lq.doubleOrNil(6), channel: lq.intOrNil(7).map { Int($0) }, speed: lq.doubleOrNil(8)))
                }

                let ev = try db.prepare("SELECT ts, kind, vm_key, label, detail FROM event WHERE ts >= ? AND ts <= ? ORDER BY ts").bind(1, from).bind(2, to)
                while ev.step() { h.events.append(HistoryEvent(ts: ev.int(0), kind: ev.text(1), vmKey: ev.textOrNil(2), label: ev.text(3), detail: ev.textOrNil(4))) }

                let cfg = try db.prepare("SELECT vm_id, ts, cores, mem FROM vm_config ORDER BY vm_id, ts")
                while cfg.step() {
                    guard let key = keyByID[cfg.int(0)] else { continue }
                    h.configs[key, default: []].append(VMConfig(ts: cfg.int(1), cores: cfg.intOrNil(2).map(Int.init), memBytes: cfg.doubleOrNil(3)))
                }
            } catch {
                FileLog.shared.log("history load failed: \(error)")
            }
            return h
        }
    }

    /// Every VM ever recorded, in the order first seen.
    public func knownVMs() -> [VMInfo] {
        queue.sync {
            var out: [VMInfo] = []
            if let q = try? db.prepare("SELECT key, name, backend FROM vm ORDER BY id") {
                while q.step() { out.append(VMInfo(key: q.text(0), name: q.text(1), backend: q.text(2))) }
            }
            return out
        }
    }

    // MARK: Maintenance

    /// Deletes everything older than `cutoff` (milliseconds since 1970).
    public func prune(olderThan cutoff: Int64) {
        queue.sync {
            do {
                try db.exec("BEGIN")
                for table in ["sample", "host_sample", "event", "probe", "link_sample"] {
                    try db.prepare("DELETE FROM \(table) WHERE ts < ?").bind(1, cutoff).run()
                }
                for table in ["sample_1m", "host_1m", "probe_1m"] {
                    try db.prepare("DELETE FROM \(table) WHERE minute < ?").bind(1, cutoff / 60000).run()
                }
                try db.exec("COMMIT")
            } catch {
                try? db.exec("ROLLBACK")
                FileLog.shared.log("history prune failed: \(error)")
            }
        }
    }

    /// Removes all recorded history and returns the disk space.
    public func clear() {
        queue.sync {
            do {
                try db.exec("DELETE FROM sample; DELETE FROM host_sample; DELETE FROM sample_1m; DELETE FROM host_1m; DELETE FROM event; DELETE FROM vm_config; DELETE FROM vm; DELETE FROM meta; DELETE FROM probe; DELETE FROM probe_1m; DELETE FROM link_sample;")
                try db.exec("VACUUM; PRAGMA wal_checkpoint(TRUNCATE);")
                try loadCaches()
            } catch {
                FileLog.shared.log("history clear failed: \(error)")
            }
        }
    }

    public struct Stats: Equatable {
        public var oldest: Int64?
        public var sampleCount: Int64
        public var bytes: Int64
    }

    public func stats() -> Stats {
        queue.sync {
            var oldest: Int64?
            var count: Int64 = 0
            if let q = try? db.prepare("SELECT min(ts), count(*) FROM host_sample"), q.step() { oldest = q.intOrNil(0); count = q.int(1) }
            var bytes: Int64 = 0
            for suffix in ["", "-wal"] {
                let attrs = try? FileManager.default.attributesOfItem(atPath: path + suffix)
                bytes += (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            }
            return Stats(oldest: oldest, sampleCount: count, bytes: bytes)
        }
    }
}
