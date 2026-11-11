import Foundation
import UTMWatchModel

/// Turns consecutive snapshots into timeline events: VM starts and stops, memory pressure changes,
/// swap crossing 80%, and a VM held at its CPU limit. Pure state machine, no I/O.
public struct EventDetector {
    public var swapHighFraction = 0.8
    public var swapClearFraction = 0.75
    public var cpuLimitFraction = 0.9
    public var cpuLimitSeconds: Double = 60

    private var running: [String: String]?        // key -> name; nil until the first snapshot
    private var pressure: Int?
    private var swapHigh = false
    private var cpuHighSince: [String: Date] = [:]
    private var cpuFlagged: Set<String> = []

    private var linkKind: String?
    private var weakCount = 0
    private var linkWeak = false

    public init() {}

    /// Tells the detector what was already true when recording last stopped, so a restart while a
    /// condition is still active does not log it a second time.
    public mutating func seed(pressure level: Int, swapHigh high: Bool) {
        pressure = level
        swapHigh = high
    }

    /// Link events from a probe round: the link going away or changing type, and Wi-Fi turning weak.
    public mutating func ingest(_ p: ProbeResult) -> [HistoryEvent] {
        var out: [HistoryEvent] = []
        let ts = p.timestamp.msSince1970
        let kind = p.link.kind
        if let old = linkKind, old != kind {
            func name(_ k: String) -> String { k == "wifi" ? "Wi-Fi" : k == "ethernet" ? "Ethernet" : k == "none" ? "no network" : k }
            if kind == "none" {
                out.append(HistoryEvent(ts: ts, kind: "link_down", vmKey: nil, label: "Network link down"))
            } else {
                out.append(HistoryEvent(ts: ts, kind: "link_changed", vmKey: nil, label: "Network link: \(name(old)) to \(name(kind))"))
            }
            weakCount = 0; linkWeak = false
        }
        linkKind = kind
        if kind == "wifi", let rssi = p.link.rssi {
            // Two readings in a row, and a 5 dB gap to clear, so a single dip does not raise an event.
            if Double(rssi) <= Diagnostics.weakWiFiRSSI { weakCount += 1 } else { weakCount = 0 }
            if !linkWeak, weakCount >= 2 {
                linkWeak = true
                out.append(HistoryEvent(ts: ts, kind: "link_weak", vmKey: nil, label: "Wi-Fi signal weak (\(rssi) dBm)"))
            } else if linkWeak, Double(rssi) > Diagnostics.weakWiFiRSSI + 5 {
                linkWeak = false
                out.append(HistoryEvent(ts: ts, kind: "link_recovered", vmKey: nil, label: "Wi-Fi signal recovered"))
            }
        }
        return out
    }

    public mutating func ingest(_ s: Snapshot) -> [HistoryEvent] {
        var out: [HistoryEvent] = []
        let ts = s.timestamp.msSince1970
        let now = Dictionary(s.rows.filter { $0.pid != nil }.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })

        // VM starts and stops. The first snapshot only establishes the baseline.
        if let before = running {
            for (key, name) in now where before[key] == nil {
                out.append(HistoryEvent(ts: ts, kind: "vm_started", vmKey: key, label: "\(name) started"))
            }
            for (key, name) in before where now[key] == nil {
                out.append(HistoryEvent(ts: ts, kind: "vm_stopped", vmKey: key, label: "\(name) stopped"))
                cpuHighSince[key] = nil; cpuFlagged.remove(key)
            }
        }
        running = now

        // Memory pressure level changes.
        let level = HostPoint.code(s.host.pressure)
        if let old = pressure, old != level {
            switch level {
            case 2: out.append(HistoryEvent(ts: ts, kind: "pressure_critical", vmKey: nil, label: "Memory pressure: critical"))
            case 1: out.append(HistoryEvent(ts: ts, kind: "pressure_warning", vmKey: nil, label: "Memory pressure: warning"))
            default: out.append(HistoryEvent(ts: ts, kind: "pressure_normal", vmKey: nil, label: "Memory pressure: normal"))
            }
        } else if pressure == nil, level > 0 {
            out.append(HistoryEvent(ts: ts, kind: level == 2 ? "pressure_critical" : "pressure_warning", vmKey: nil,
                                    label: "Memory pressure: \(level == 2 ? "critical" : "warning")"))
        }
        pressure = level

        // Swap, with hysteresis so it does not flap around the threshold.
        if s.host.swapTotal > 0 {
            let used = Double(s.host.swapUsed) / Double(s.host.swapTotal)
            if !swapHigh, used >= swapHighFraction {
                swapHigh = true
                out.append(HistoryEvent(ts: ts, kind: "swap_high", vmKey: nil, label: "Swap above 80%"))
            } else if swapHigh, used < swapClearFraction {
                swapHigh = false
                out.append(HistoryEvent(ts: ts, kind: "swap_normal", vmKey: nil, label: "Swap back under 80%"))
            }
        }

        // A VM held at 90% of its cores for a minute.
        for row in s.rows where row.pid != nil {
            guard let used = row.cpuCores, let limit = row.cpuAllocated, limit > 0 else { continue }
            if used >= cpuLimitFraction * Double(limit) {
                let since = cpuHighSince[row.id] ?? s.timestamp
                cpuHighSince[row.id] = since
                if !cpuFlagged.contains(row.id), s.timestamp.timeIntervalSince(since) >= cpuLimitSeconds {
                    cpuFlagged.insert(row.id)
                    out.append(HistoryEvent(ts: ts, kind: "cpu_limit", vmKey: row.id, label: "\(row.name) at CPU limit"))
                }
            } else {
                cpuHighSince[row.id] = nil
                cpuFlagged.remove(row.id)
            }
        }
        return out
    }
}
