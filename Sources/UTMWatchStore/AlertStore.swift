import Foundation
import UTMWatchModel

/// Alerts live in the history database, in a table of their own that the MCP helper can read.
public extension HistoryStore {
    internal func createAlertTable() throws {
        try db.exec("""
        CREATE TABLE IF NOT EXISTS alert(id INTEGER PRIMARY KEY, rule TEXT NOT NULL, level TEXT NOT NULL, subject TEXT NOT NULL, vm_key TEXT,
            title TEXT NOT NULL, what TEXT NOT NULL, todo TEXT NOT NULL, opened INTEGER NOT NULL, closed INTEGER, finding TEXT, finding_ts INTEGER);
        CREATE INDEX IF NOT EXISTS alert_opened ON alert(opened);
        """)
    }

    /// Stores a newly opened alert and returns its id (0 if it could not be stored).
    func insertAlert(_ a: Alert) -> Int64 {
        queue.sync {
            do {
                try db.prepare("INSERT INTO alert(rule, level, subject, vm_key, title, what, todo, opened, closed, finding, finding_ts) VALUES(?,?,?,?,?,?,?,?,?,?,?)")
                    .bind(1, a.rule).bind(2, a.level.rawValue).bind(3, a.subject).bind(4, a.vmKey).bind(5, a.title).bind(6, a.what).bind(7, a.todo)
                    .bind(8, a.opened).bind(9, a.closed).bind(10, a.finding).bind(11, a.findingAt).run()
                return db.lastInsertRowID
            } catch { FileLog.shared.log("alert insert failed: \(error)"); return 0 }
        }
    }

    func updateAlert(_ a: Alert) {
        guard a.id > 0 else { return }
        queue.sync {
            do {
                try db.prepare("UPDATE alert SET level = ?, title = ?, what = ?, todo = ?, closed = ?, finding = ?, finding_ts = ? WHERE id = ?")
                    .bind(1, a.level.rawValue).bind(2, a.title).bind(3, a.what).bind(4, a.todo).bind(5, a.closed).bind(6, a.finding).bind(7, a.findingAt).bind(8, a.id).run()
            } catch { FileLog.shared.log("alert update failed: \(error)") }
        }
    }

    func closeAlert(id: Int64, at t: Int64) {
        guard id > 0 else { return }
        queue.sync {
            do { try db.prepare("UPDATE alert SET closed = ? WHERE id = ? AND closed IS NULL").bind(1, t).bind(2, id).run() }
            catch { FileLog.shared.log("alert close failed: \(error)") }
        }
    }

    /// Open alerts first (newest first), then those that ended at or after `since`, newest first.
    func alerts(since: Int64, limit: Int = 200) -> [Alert] {
        queue.sync {
            var out: [Alert] = []
            // An older database, read by the helper before the app has added the table, simply has no alerts yet.
            guard let q = try? db.prepare("""
                SELECT id, rule, level, subject, vm_key, title, what, todo, opened, closed, finding, finding_ts FROM alert
                WHERE closed IS NULL OR closed >= ? ORDER BY closed IS NOT NULL, opened DESC LIMIT ?
                """).bind(1, since).bind(2, Int64(limit)) else { return out }
            while q.step() {
                var a = Alert(rule: q.text(1), level: AlertLevel(rawValue: q.text(2)) ?? .risk, subject: q.text(3), vmKey: q.textOrNil(4),
                              title: q.text(5), what: q.text(6), todo: q.text(7), opened: q.int(8))
                a.id = q.int(0); a.closed = q.intOrNil(9); a.finding = q.textOrNil(10); a.findingAt = q.intOrNil(11)
                out.append(a)
            }
            return out
        }
    }

    func pruneAlerts(olderThan cutoff: Int64) {
        queue.sync {
            do { try db.prepare("DELETE FROM alert WHERE closed IS NOT NULL AND closed < ?").bind(1, cutoff).run() }
            catch { FileLog.shared.log("alert prune failed: \(error)") }
        }
    }

    func clearAlerts() {
        queue.sync { try? db.exec("DELETE FROM alert") }
    }
}
