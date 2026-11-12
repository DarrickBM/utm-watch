import Foundation
import UTMWatchModel

/// Reading the local history out for upload to a hub. The local database is the spool: nothing is queued anywhere else,
/// so a Mac that was offline simply continues from its cursors.
public extension HistoryStore {
    /// The upload cursors, or nil if this Mac has never uploaded (or its history was cleared).
    func uploadCursor() -> UploadCursor? {
        queue.sync {
            guard let s = meta("up_sample_ts"), let p = meta("up_probe_ts"), let e = meta("up_event_id") else { return nil }
            return UploadCursor(sampleTs: s, probeTs: p, eventId: e)
        }
    }

    func setUploadCursor(_ c: UploadCursor) {
        queue.sync {
            do {
                let put = try db.prepare("INSERT OR REPLACE INTO meta VALUES(?, ?)")
                put.bind(1, "up_sample_ts").bind(2, c.sampleTs).run()
                put.bind(1, "up_probe_ts").bind(2, c.probeTs).run()
                put.bind(1, "up_event_id").bind(2, c.eventId).run()
            } catch { FileLog.shared.log("saving upload cursor failed: \(error)") }
        }
    }

    /// Cursors for a first upload that should carry history from `since` onwards and nothing older.
    func uploadCursor(startingAt since: Int64) -> UploadCursor {
        queue.sync {
            var c = UploadCursor(sampleTs: since - 1, probeTs: since - 1, eventId: 0)
            if let q = try? db.prepare("SELECT max(id) FROM event WHERE ts < ?").bind(1, since), q.step() { c.eventId = q.intOrNil(0) ?? 0 }
            return c
        }
    }

    /// The next slice of history after `cursor`: at most `limitMs` of samples and of pings, and `maxEvents` events.
    /// The returned batch's `cursor` is where the cursors stand once the hub has stored it.
    func exportBatch(after cursor: UploadCursor, limitMs: Int64 = 300_000, maxEvents: Int = 500) -> IngestBatch {
        queue.sync {
            var b = IngestBatch(cursor: cursor)
            do {
                var vmIndex: [Int64: Int] = [:]
                var vmRows: [Int64: IngestBatch.VM] = [:]
                let vms = try db.prepare("SELECT id, key, name, backend FROM vm ORDER BY id")
                while vms.step() { vmRows[vms.int(0)] = .init(key: vms.text(1), name: vms.text(2), backend: vms.text(3)) }

                // Samples: start at the first one after the cursor, so a long gap (the Mac was asleep) is skipped in one step.
                let first = try db.prepare("SELECT min(ts) FROM host_sample WHERE ts > ?").bind(1, cursor.sampleTs)
                if first.step(), let start = first.intOrNil(0) {
                    let upper = start + limitMs
                    let hq = try db.prepare("""
                        SELECT ts, used, other, allocatable, pressure, swap_used, swap_total, cores, cpu
                        FROM host_sample WHERE ts > ? AND ts <= ? ORDER BY ts
                        """).bind(1, cursor.sampleTs).bind(2, upper)
                    while hq.step() {
                        b.host.append([Double(hq.int(0)), hq.doubleOrNil(1), hq.doubleOrNil(2), hq.doubleOrNil(3), hq.doubleOrNil(4),
                                       hq.doubleOrNil(5), hq.doubleOrNil(6), hq.doubleOrNil(7), hq.doubleOrNil(8)])
                        b.cursor.sampleTs = hq.int(0)
                    }
                    let sq = try db.prepare("""
                        SELECT vm_id, ts, cpu, mem, down, up, down_total, up_total, disk_read, disk_write, res, disk_used, disk_size
                        FROM sample WHERE ts > ? AND ts <= ? ORDER BY ts, vm_id
                        """).bind(1, cursor.sampleTs).bind(2, b.cursor.sampleTs)
                    while sq.step() {
                        let id = sq.int(0)
                        guard let info = vmRows[id] else { continue }
                        let index: Int
                        if let known = vmIndex[id] { index = known } else {
                            index = b.vms.count; vmIndex[id] = index; b.vms.append(info)
                        }
                        b.samples.append([Double(index), Double(sq.int(1)), sq.doubleOrNil(2), sq.doubleOrNil(3), sq.doubleOrNil(4), sq.doubleOrNil(5),
                                          sq.doubleOrNil(6), sq.doubleOrNil(7), sq.doubleOrNil(8), sq.doubleOrNil(9), sq.doubleOrNil(10)])
                        if let used = sq.doubleOrNil(11) {
                            b.disks = (b.disks ?? []) + [[Double(index), Double(sq.int(1)), used, sq.doubleOrNil(12)]]
                        }
                    }
                    // Limits: those that changed in this slice, plus the one already in force when it began.
                    for (id, index) in vmIndex.sorted(by: { $0.value < $1.value }) {
                        let cq = try db.prepare("""
                            SELECT ts, cores, mem FROM vm_config WHERE vm_id = ?1 AND ts <= ?3
                              AND ts >= coalesce((SELECT max(ts) FROM vm_config WHERE vm_id = ?1 AND ts <= ?2), 0) ORDER BY ts
                            """).bind(1, id).bind(2, cursor.sampleTs).bind(3, b.cursor.sampleTs)
                        while cq.step() { b.configs.append(.init(vm: index, ts: cq.int(0), cores: cq.intOrNil(1).map(Int.init), mem: cq.doubleOrNil(2))) }
                    }
                }

                let firstProbe = try db.prepare("""
                    SELECT min(ts) FROM (SELECT min(ts) AS ts FROM probe WHERE ts > ?1 UNION ALL SELECT min(ts) FROM link_sample WHERE ts > ?1)
                    """).bind(1, cursor.probeTs)
                if firstProbe.step(), let start = firstProbe.intOrNil(0) {
                    let upper = start + limitMs
                    var targetIndex: [String: Int] = [:]
                    let pq = try db.prepare("SELECT target, ts, rtt, ok FROM probe WHERE ts > ? AND ts <= ? ORDER BY ts, target").bind(1, cursor.probeTs).bind(2, upper)
                    while pq.step() {
                        let name = pq.text(0)
                        let index: Int
                        if let known = targetIndex[name] { index = known } else {
                            index = b.targets.count; targetIndex[name] = index; b.targets.append(name)
                        }
                        b.probes.append([Double(index), Double(pq.int(1)), pq.doubleOrNil(2), Double(pq.int(3))])
                        b.cursor.probeTs = max(b.cursor.probeTs, pq.int(1))
                    }
                    let lq = try db.prepare("SELECT ts, kind, iface, rssi, noise, tx_rate, channel, speed FROM link_sample WHERE ts > ? AND ts <= ? ORDER BY ts")
                        .bind(1, cursor.probeTs).bind(2, upper)
                    while lq.step() {
                        b.link.append(.init(ts: lq.int(0), kind: lq.text(1), iface: lq.textOrNil(2), rssi: lq.doubleOrNil(3), noise: lq.doubleOrNil(4),
                                            txRate: lq.doubleOrNil(5), channel: lq.intOrNil(6).map(Int.init), speed: lq.doubleOrNil(7)))
                        b.cursor.probeTs = max(b.cursor.probeTs, lq.int(0))
                    }
                }

                let eq = try db.prepare("SELECT id, ts, kind, vm_key, label, detail FROM event WHERE id > ? ORDER BY id LIMIT ?")
                    .bind(1, cursor.eventId).bind(2, Int64(maxEvents))
                while eq.step() {
                    b.events.append(.init(ts: eq.int(1), kind: eq.text(2), vmKey: eq.textOrNil(3), label: eq.text(4), detail: eq.textOrNil(5)))
                    b.cursor.eventId = eq.int(0)
                }
            } catch {
                FileLog.shared.log("history export failed: \(error)")
                return IngestBatch(cursor: cursor)
            }
            return b
        }
    }

    private func meta(_ key: String) -> Int64? {
        guard let q = try? db.prepare("SELECT v FROM meta WHERE k = ?").bind(1, key), q.step() else { return nil }
        return q.intOrNil(0)
    }
}
