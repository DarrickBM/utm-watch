import Foundation
import UTMWatchModel

/// The SQL differences between one Mac's own database and one host inside the hub's database.
/// Every fragment is built from an integer id the store owns, never from outside text.
struct StoreScope {
    var vmWhere = ""               // which rows of `vm` belong
    var sampleAnd = ""             // which `vm_id`s belong (sample, sample_1m, vm_config)
    var hostAnd = ""               // which rows of host_sample, host_1m, link_sample and event belong
    var hostCols = ""              // leading key columns of host_1m
    var probeKey = "target"        // key column of probe and probe_1m
    var probeName = "target"       // expression giving the target's name
    var probeAnd = ""              // which probe rows belong
    var eventKey = "vm_key"        // expression giving an event's VM key, NULL when it has none
    /// Width of one raw sample in milliseconds.
    var rawMs: Double = 2000

    static let local = StoreScope()

    static func host(_ id: Int64, rawMs: Double) -> StoreScope {
        StoreScope(vmWhere: "WHERE host_id = \(id)",
                   sampleAnd: " AND vm_id IN (SELECT id FROM vm WHERE host_id = \(id))",
                   hostAnd: " AND host_id = \(id)",
                   hostCols: "host_id, ",
                   probeKey: "target_id",
                   probeName: "(SELECT name FROM target WHERE id = target_id)",
                   probeAnd: " AND target_id IN (SELECT id FROM target WHERE host_id = \(id))",
                   eventKey: "NULLIF(vm_key, '')",
                   rawMs: rawMs)
    }
}

/// Reads and rolls up history the same way for the local store and the hub, so both give identical answers.
enum HistoryReader {
    /// Frames longer than this read the 1-minute rollups instead of raw samples.
    static let rollupThresholdMs: Int64 = 2 * 3600 * 1000

    /// Fills `h` for its time frame, reduced to at most `maxPoints` points per series (nil = every raw sample).
    static func fill(_ h: inout History, db: Database, scope s: StoreScope, maxPoints: Int?) throws {
        let from = h.from, to = h.to
        let span = max(1, to - from)
        let useRollup = maxPoints != nil && span > rollupThresholdMs
        // With no cap, 1-second buckets are finer than any sample interval, i.e. raw data.
        let buckets = Int64(maxPoints ?? Int(max(1, span / 1000)))
        let source: Double = useRollup ? 60000 : s.rawMs
        h.bucketMs = max(source, Double(span) / Double(buckets))

        let vms = try db.prepare("SELECT id, key, name, backend FROM vm \(s.vmWhere) ORDER BY id")
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
                   avg(disk_read), avg(disk_write), avg(res_avg)
            FROM sample_1m WHERE minute >= ?1 / 60000 AND minute <= ?2 / 60000\(s.sampleAnd) GROUP BY vm_id, b ORDER BY vm_id, b
            """ : """
            SELECT vm_id, (ts - ?1) * ?3 / ?4 AS b, CAST(avg(ts) AS INTEGER),
                   avg(cpu), max(cpu), avg(mem), avg(down), max(down), avg(up), max(up), max(down_total), max(up_total),
                   avg(disk_read), avg(disk_write), avg(res)
            FROM sample WHERE ts >= ?1 AND ts <= ?2\(s.sampleAnd) GROUP BY vm_id, b ORDER BY vm_id, b
            """
        let q = try db.prepare(sql).bind(1, from).bind(2, to).bind(3, buckets).bind(4, span)
        while q.step() {
            guard let key = keyByID[q.int(0)] else { continue }
            h.series[key, default: []].append(VMPoint(
                t: q.int(2), cpu: q.doubleOrNil(3), cpuMax: q.doubleOrNil(4), mem: q.doubleOrNil(5),
                down: q.doubleOrNil(6), downMax: q.doubleOrNil(7), up: q.doubleOrNil(8), upMax: q.doubleOrNil(9),
                downTotal: q.doubleOrNil(10), upTotal: q.doubleOrNil(11), diskRead: q.doubleOrNil(12), diskWrite: q.doubleOrNil(13), res: q.doubleOrNil(14)))
        }
        h.vms = order.filter { h.series[$0] != nil }.compactMap { infos[$0] }

        let hostSQL = useRollup ? """
            SELECT (minute * 60000 + 30000 - ?1) * ?3 / ?4 AS b, CAST(avg(minute * 60000 + 30000) AS INTEGER), avg(used), avg(other),
                   min(allocatable), max(pressure), max(swap_used), max(swap_total), max(cores), max(cpu)
            FROM host_1m WHERE minute >= ?1 / 60000 AND minute <= ?2 / 60000\(s.hostAnd) GROUP BY b ORDER BY b
            """ : """
            SELECT (ts - ?1) * ?3 / ?4 AS b, CAST(avg(ts) AS INTEGER), avg(used), avg(other),
                   min(allocatable), max(pressure), max(swap_used), max(swap_total), max(cores), max(cpu)
            FROM host_sample WHERE ts >= ?1 AND ts <= ?2\(s.hostAnd) GROUP BY b ORDER BY b
            """
        let hq = try db.prepare(hostSQL).bind(1, from).bind(2, to).bind(3, buckets).bind(4, span)
        while hq.step() {
            h.host.append(HostPoint(t: hq.int(1), used: hq.double(2), other: hq.double(3), allocatable: hq.double(4),
                                    pressure: Int(hq.int(5)), swapUsed: hq.double(6), swapTotal: hq.double(7), cores: Int(hq.int(8)), cpu: hq.doubleOrNil(9)))
        }

        let probeSQL = useRollup ? """
            SELECT \(s.probeName), (minute * 60000 + 30000 - ?1) * ?3 / ?4 AS b, CAST(avg(minute * 60000 + 30000) AS INTEGER),
                   avg(rtt_avg), max(rtt_max), sum(sent), sum(lost)
            FROM probe_1m WHERE minute >= ?1 / 60000 AND minute <= ?2 / 60000\(s.probeAnd) GROUP BY \(s.probeKey), b ORDER BY 1, b
            """ : """
            SELECT \(s.probeName), (ts - ?1) * ?3 / ?4 AS b, CAST(avg(ts) AS INTEGER), avg(rtt), max(rtt), count(*), sum(1 - ok)
            FROM probe WHERE ts >= ?1 AND ts <= ?2\(s.probeAnd) GROUP BY \(s.probeKey), b ORDER BY 1, b
            """
        let pq = try db.prepare(probeSQL).bind(1, from).bind(2, to).bind(3, buckets).bind(4, span)
        while pq.step() {
            h.probes[pq.text(0), default: []].append(ProbePoint(t: pq.int(2), rtt: pq.doubleOrNil(3), rttMax: pq.doubleOrNil(4),
                                                                sent: Int(pq.int(5)), lost: Int(pq.int(6))))
        }
        let lq = try db.prepare("""
            SELECT (ts - ?1) * ?3 / ?4 AS b, CAST(avg(ts) AS INTEGER), max(kind), max(iface), avg(rssi), avg(noise), avg(tx_rate), max(channel), avg(speed)
            FROM link_sample WHERE ts >= ?1 AND ts <= ?2\(s.hostAnd) GROUP BY b ORDER BY b
            """).bind(1, from).bind(2, to).bind(3, buckets).bind(4, span)
        while lq.step() {
            h.link.append(LinkPoint(t: lq.int(1), kind: lq.text(2), interface: lq.textOrNil(3), rssi: lq.doubleOrNil(4), noise: lq.doubleOrNil(5),
                                    txRate: lq.doubleOrNil(6), channel: lq.intOrNil(7).map { Int($0) }, speed: lq.doubleOrNil(8)))
        }

        let ev = try db.prepare("SELECT ts, kind, \(s.eventKey), label, detail FROM event WHERE ts >= ? AND ts <= ?\(s.hostAnd) ORDER BY ts, id").bind(1, from).bind(2, to)
        while ev.step() { h.events.append(HistoryEvent(ts: ev.int(0), kind: ev.text(1), vmKey: ev.textOrNil(2), label: ev.text(3), detail: ev.textOrNil(4))) }

        let cfg = try db.prepare("SELECT vm_id, ts, cores, mem FROM vm_config WHERE 1 = 1\(s.sampleAnd) ORDER BY vm_id, ts")
        while cfg.step() {
            guard let key = keyByID[cfg.int(0)] else { continue }
            h.configs[key, default: []].append(VMConfig(ts: cfg.int(1), cores: cfg.intOrNil(2).map(Int.init), memBytes: cfg.doubleOrNil(3)))
        }
    }

    /// Rolls VM and host samples of the minutes in `fromMinute..<toMinute` into the 1-minute tables.
    static func rollSamples(_ db: Database, scope s: StoreScope, fromMinute: Int64, toMinute: Int64) throws {
        try db.prepare("""
            INSERT OR REPLACE INTO sample_1m
            SELECT vm_id, ts / 60000, avg(cpu), max(cpu), avg(mem), avg(down), max(down), avg(up), max(up), max(down_total), max(up_total),
                   avg(disk_read), avg(disk_write), avg(res)
            FROM sample WHERE ts >= ? AND ts < ?\(s.sampleAnd) GROUP BY vm_id, ts / 60000
            """).bind(1, fromMinute * 60000).bind(2, toMinute * 60000).run()
        try db.prepare("""
            INSERT OR REPLACE INTO host_1m
            SELECT \(s.hostCols)ts / 60000, avg(used), avg(other), min(allocatable), max(pressure), max(swap_used), max(swap_total), max(cores), max(cpu)
            FROM host_sample WHERE ts >= ? AND ts < ?\(s.hostAnd) GROUP BY \(s.hostCols)ts / 60000
            """).bind(1, fromMinute * 60000).bind(2, toMinute * 60000).run()
    }

    /// Rolls ping results of the minutes in `fromMinute..<toMinute` into `probe_1m`.
    static func rollProbes(_ db: Database, scope s: StoreScope, fromMinute: Int64, toMinute: Int64) throws {
        try db.prepare("""
            INSERT OR REPLACE INTO probe_1m
            SELECT \(s.probeKey), ts / 60000, avg(rtt), max(rtt), count(*), sum(1 - ok)
            FROM probe WHERE ts >= ? AND ts < ?\(s.probeAnd) GROUP BY \(s.probeKey), ts / 60000
            """).bind(1, fromMinute * 60000).bind(2, toMinute * 60000).run()
    }
}
