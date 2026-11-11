import Foundation
import UTMWatchCore

/// A period where some signal was outside its normal range.
public struct Incident: Equatable {
    public var from: Int64
    public var to: Int64
    /// memory_pressure, swap_high, vm_cpu_limit, vm_slow_response, local_network, internet_path, wifi_weak, no_data
    public var kind: String
    /// Which part was affected: "mac", "vm:<name>", "wifi", "lan", "internet".
    public var segment: String
    public var summary: String
    public var severity: Double
    /// More than 1 when many short, similar spikes were folded into this one entry.
    public var occurrences: Int = 1
    /// A VM was uploading steadily (screen streaming), so someone was probably connected. A heuristic.
    public var remoteSessionLikely: Bool
}

/// Pure analysis over a loaded `History`: used by the MCP helper, testable without a database.
public enum Diagnostics {
    public static let weakWiFiRSSI = -75.0
    public static let sessionUploadBytesPerSecond = 100_000.0

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// Groups consecutive "bad" points into runs; points further apart than `maxGap` start a new run.
    static func runs<P>(_ points: [P], time: (P) -> Int64, maxGap: Double, bad: (P) -> Bool) -> [[P]] {
        var out: [[P]] = []
        var current: [P] = []
        var lastBad: Int64?
        for p in points where bad(p) {
            if let l = lastBad, Double(time(p) - l) > maxGap, !current.isEmpty { out.append(current); current = [] }
            current.append(p)
            lastBad = time(p)
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    static func duration(_ ms: Int64) -> String {
        let s = max(0, ms / 1000)
        if s >= 3600 { return "\(s / 3600) h \(s % 3600 / 60) min" }
        if s >= 60 { return "\(s / 60) min" }
        return "\(s) s"
    }

    public static func incidents(_ h: History, limit: Int = 25) -> [Incident] {
        var out: [Incident] = []
        let bucket = h.bucketMs
        let gap = max(bucket * 2.5, 30_000)
        let half = Int64(bucket / 2)
        func add(_ from: Int64, _ to: Int64, _ kind: String, _ segment: String, _ base: Double, _ summary: String,
                 occurrences: Int = 1, severity fixed: Double? = nil) {
            let lo = from - half, hi = max(to + half, from + Int64(bucket))
            let minutes = Double(hi - lo) / 60_000
            let session = h.series.values.contains { points in
                let ups = points.filter { $0.t >= lo - 60_000 && $0.t <= hi + 60_000 }.compactMap(\.up)
                return !ups.isEmpty && ups.reduce(0, +) / Double(ups.count) >= sessionUploadBytesPerSecond
            }
            out.append(Incident(from: lo, to: hi, kind: kind, segment: segment, summary: summary,
                                severity: fixed ?? (base + min(3, minutes / 5)), occurrences: occurrences, remoteSessionLikely: session))
        }
        let nameOf = Dictionary(h.vms.map { ($0.key, $0.name) }, uniquingKeysWith: { a, _ in a })

        // Memory pressure and swap.
        for run in runs(h.host, time: { $0.t }, maxGap: gap, bad: { $0.pressure > 0 }) {
            let critical = run.contains { $0.pressure >= 2 }
            let swap = run.map { $0.swapTotal > 0 ? $0.swapUsed / $0.swapTotal : 0 }.max() ?? 0
            let other = run.map(\.other).max() ?? 0
            add(run.first!.t, run.last!.t, "memory_pressure", "mac", critical ? 5 : 3,
                "Memory pressure \(critical ? "critical" : "warning") for \(duration(run.last!.t - run.first!.t + Int64(bucket))). Swap peaked at \(Int((swap * 100).rounded()))%. Memory used outside the VMs peaked at \(Format.memory(UInt64(max(0, other)))).")
        }
        for run in runs(h.host, time: { $0.t }, maxGap: gap, bad: { $0.pressure == 0 && $0.swapTotal > 0 && $0.swapUsed / $0.swapTotal >= 0.8 }) {
            let swap = run.map { $0.swapUsed / $0.swapTotal }.max() ?? 0
            add(run.first!.t, run.last!.t, "swap_high", "mac", 2, "Swap stayed above 80% (peak \(Int((swap * 100).rounded()))%) without a pressure warning.")
        }

        // A VM at its CPU limit for a minute or more.
        for vm in h.vms {
            let points = h.series[vm.key] ?? []
            for run in runs(points, time: { $0.t }, maxGap: gap, bad: { p in
                guard let cores = h.config(for: vm.key, at: p.t)?.cores, cores > 0, let cpu = p.cpu else { return false }
                return cpu >= 0.9 * Double(cores)
            }) where run.last!.t - run.first!.t + Int64(bucket) >= 60_000 {
                let cores = h.config(for: vm.key, at: run.first!.t)?.cores ?? 0
                add(run.first!.t, run.last!.t, "vm_cpu_limit", "vm:\(vm.name)", 2,
                    "\(vm.name) ran at its \(cores)-core limit for \(duration(run.last!.t - run.first!.t + Int64(bucket))).")
            }
        }

        // Ping-based signals. Thresholds are relative to each target's own normal level.
        func pingIncidents(_ target: String, kind: String, segment: String, base: Double, floorMs: Double, factor: Double, lossFraction: Double, label: String) {
            let points = h.probes[target] ?? []
            let normal = median(points.compactMap(\.rtt)) ?? 0
            let threshold = max(floorMs, normal * factor)
            let found = runs(points, time: { $0.t }, maxGap: gap, bad: { p in
                (p.sent > 0 && Double(p.lost) / Double(p.sent) >= lossFraction) || (p.rttMax ?? 0) > threshold
            }).filter { run in
                // One lost ping with otherwise normal timing is noise, not an incident.
                run.reduce(0) { $0 + $1.lost } >= 2 || (run.compactMap(\.rttMax).max() ?? 0) > threshold
            }
            func describe(_ run: [ProbePoint]) -> String {
                let peak = run.compactMap(\.rttMax).max()
                let sent = run.reduce(0) { $0 + $1.sent }, lost = run.reduce(0) { $0 + $1.lost }
                var text = peak.map { "peaked at \($0 < 10 ? String(format: "%.1f", $0) : String(Int($0.rounded()))) ms (normally \(String(format: "%.1f", normal)) ms)" } ?? "no replies"
                if lost > 0 { text += ", \(lost) of \(sent) pings lost" }
                return text
            }
            // Many brief, similar spikes are one pattern, not many incidents: fold them into a single entry.
            let brief = found.filter { Double($0.last!.t - $0.first!.t) <= bucket * 2 }
            let folded = brief.count >= 4
            for run in found where !(folded && Double(run.last!.t - run.first!.t) <= bucket * 2) {
                let lost = run.reduce(0) { $0 + $1.lost }
                add(run.first!.t, run.last!.t, kind, segment, base + (lost > 0 ? 1 : 0), "\(label): \(describe(run)).")
            }
            if folded {
                let all = brief.flatMap { $0 }
                let lost = all.reduce(0) { $0 + $1.lost }
                let worst = all.compactMap(\.rttMax).max().map { "worst \(Int($0.rounded())) ms" } ?? "no replies"
                add(brief.first!.first!.t, brief.last!.last!.t, kind, segment, base,
                    "\(label): \(brief.count) short spikes above \(Int(threshold.rounded())) ms spread over this period, \(worst) (normally \(String(format: "%.1f", normal)) ms)" + (lost > 0 ? ", \(lost) pings lost in total" : "") + ".",
                    occurrences: brief.count, severity: base + min(2, Double(brief.count) / 10) + (lost > 0 ? 1 : 0))
            }
        }
        for vm in h.vms {
            pingIncidents(ProbeTarget.vm(vm.key), kind: "vm_slow_response", segment: "vm:\(vm.name)", base: 4, floorMs: 50, factor: 20,
                          lossFraction: 0.01, label: "Ping from the Mac to \(vm.name)")
        }
        let linkKind = h.link.last?.kind ?? "lan"
        let localSegment = linkKind == "wifi" ? "wifi" : "lan"

        // A local hop that is uneven all the time. Judged against what a healthy local network looks like
        // (a few milliseconds), not against this network's own, possibly poor, normal level.
        let gw = h.probes[ProbeTarget.gateway] ?? []
        let gwTypical = median(gw.compactMap(\.rtt)) ?? 0
        let gwSpiky = gw.isEmpty ? 0 : Double(gw.filter { ($0.rttMax ?? 0) > 50 }.count) / Double(gw.count)
        let chronic = gw.count >= 10 && (gwTypical > 5 || gwSpiky >= 0.15)
        if chronic, let first = gw.first, let last = gw.last {
            var text = "Ping to the router is uneven throughout this range: typically \(String(format: "%.1f", gwTypical)) ms, where a healthy local network stays under about 3 ms"
            text += ", and above 50 ms in \(Int((gwSpiky * 100).rounded()))% of the \(Int(bucket / 1000))-second intervals"
            if let worst = gw.compactMap(\.rttMax).max() { text += " (worst \(Int(worst.rounded())) ms)" }
            text += "."
            let rssi = h.link.filter { $0.kind == "wifi" }.compactMap(\.rssi)
            if !rssi.isEmpty {
                let avg = rssi.reduce(0, +) / Double(rssi.count)
                text += avg > weakWiFiRSSI + 5
                    ? " Wi-Fi signal averaged \(Int(avg.rounded())) dBm, which is strong, so signal strength is not the cause; interference or channel scanning is more likely."
                    : " Wi-Fi signal averaged \(Int(avg.rounded())) dBm, which is weak enough to explain it."
            }
            // Ranked first: it is always present, so it colors every session, and it is the most actionable.
            add(first.t, last.t, "local_network_jitter", localSegment, 0, text, severity: 9)
        }
        // With chronic jitter already reported, only spikes well beyond it are worth listing separately.
        pingIncidents(ProbeTarget.gateway, kind: "local_network", segment: localSegment, base: 3, floorMs: chronic ? 150 : 50, factor: 8,
                      lossFraction: 0.01, label: "Ping to the router")
        pingIncidents(ProbeTarget.internet, kind: "internet_path", segment: "internet", base: 3, floorMs: 200, factor: 5,
                      lossFraction: 0.34, label: "Ping to the internet")

        // Weak Wi-Fi signal.
        for run in runs(h.link, time: { $0.t }, maxGap: gap, bad: { $0.kind == "wifi" && ($0.rssi ?? 0) <= weakWiFiRSSI }) {
            let worst = run.compactMap(\.rssi).min() ?? 0
            let rate = run.compactMap(\.txRate).min()
            add(run.first!.t, run.last!.t, "wifi_weak", "wifi", 3,
                "Wi-Fi signal fell to \(Int(worst.rounded())) dBm" + (rate.map { ", link speed down to \(Int($0.rounded())) Mbps" } ?? "") + ".")
        }

        // Stretches with no samples at all: the Mac was asleep, or UTM Watch was not running.
        let hostGap = max(bucket * 3, 90_000)
        var previous: Int64? = h.host.first.map { _ in h.from }
        for p in h.host {
            if let prev = previous, Double(p.t - prev) > hostGap, prev > h.from {
                let slept = h.events.contains { $0.kind == "sleep" && $0.ts >= prev - 60_000 && $0.ts <= p.t }
                add(prev, p.t, "no_data", "mac", 4,
                    slept ? "The Mac was asleep for \(duration(p.t - prev)). VMs were paused and nothing could connect until it woke."
                          : "No samples for \(duration(p.t - prev)): the Mac was asleep or shut down, or UTM Watch was not running.")
            }
            previous = p.t
        }

        return Array(out.sorted { $0.severity != $1.severity ? $0.severity > $1.severity : $0.from > $1.from }.prefix(limit))
    }

    /// Compact statistics for a time range, as JSON-ready values.
    public static func summary(_ h: History) -> [String: Any] {
        func stats(_ values: [(Int64, Double)]) -> [String: Any]? {
            guard !values.isEmpty else { return nil }
            let peak = values.max { $0.1 < $1.1 }!
            return ["avg": round3(values.reduce(0) { $0 + $1.1 } / Double(values.count)), "peak": round3(peak.1), "peakAt": iso(peak.0)]
        }
        var vms: [[String: Any]] = []
        for vm in h.vms {
            let pts = h.series[vm.key] ?? []
            var d: [String: Any] = ["name": vm.name, "backend": vm.backend, "samples": pts.count]
            if let c = h.config(for: vm.key, at: h.to) {
                if let cores = c.cores { d["coresAllocated"] = cores }
                if let mem = c.memBytes { d["memoryAllocatedGB"] = round3(mem / 1_073_741_824) }
            }
            d["cpuCores"] = stats(pts.compactMap { p in (p.cpuMax ?? p.cpu).map { (p.t, $0) } })
            d["memoryGB"] = stats(pts.compactMap { p in p.mem.map { (p.t, $0 / 1_073_741_824) } })
            d["downloadMBps"] = stats(pts.compactMap { p in (p.downMax ?? p.down).map { (p.t, $0 / 1e6) } })
            d["uploadMBps"] = stats(pts.compactMap { p in (p.upMax ?? p.up).map { (p.t, $0 / 1e6) } })
            d["diskWriteMBps"] = stats(pts.compactMap { p in p.diskWrite.map { (p.t, $0 / 1e6) } })
            d["diskReadMBps"] = stats(pts.compactMap { p in p.diskRead.map { (p.t, $0 / 1e6) } })
            d["pingMs"] = probeStats(h.probes[ProbeTarget.vm(vm.key)] ?? [])
            vms.append(d.compactMapValues { $0 })
        }
        var host: [String: Any] = ["samples": h.host.count]
        let pressured = h.host.filter { $0.pressure > 0 }.count
        host["secondsUnderMemoryPressure"] = Int(Double(pressured) * h.bucketMs / 1000)
        host["swapUsedFraction"] = stats(h.host.compactMap { $0.swapTotal > 0 ? ($0.t, $0.swapUsed / $0.swapTotal) : nil })
        host["memoryUsedOutsideVMsGB"] = stats(h.host.map { ($0.t, $0.other / 1_073_741_824) })
        host["allocatableMemoryGB"] = h.host.map { $0.allocatable / 1_073_741_824 }.min().map { ["min": round3($0)] }
        host["cpuCoresBusy"] = stats(h.host.compactMap { p in p.cpu.map { (p.t, $0) } })
        var network: [String: Any] = [:]
        network["routerPingMs"] = probeStats(h.probes[ProbeTarget.gateway] ?? [])
        network["internetPingMs"] = probeStats(h.probes[ProbeTarget.internet] ?? [])
        // Per server: the combined figure above keeps the faster reply each round, which hides jitter.
        var servers: [String: Any] = [:]
        for (target, points) in h.probes where target.hasPrefix(ProbeTarget.anchorPrefix) {
            servers[String(target.dropFirst(ProbeTarget.anchorPrefix.count))] = probeStats(points)
        }
        if !servers.isEmpty { network["internetPingMsByServer"] = servers }
        if let last = h.link.last {
            var link: [String: Any] = ["kind": last.kind]
            if last.kind == "wifi" {
                link["signalDbm"] = stats(h.link.compactMap { p in p.rssi.map { (p.t, $0) } }).map { s -> [String: Any] in
                    var s = s; s["weakest"] = h.link.compactMap(\.rssi).min().map { round3($0) }; s["peak"] = nil; s["peakAt"] = nil; return s.compactMapValues { $0 }
                }
                link["linkSpeedMbps"] = h.link.compactMap(\.txRate).min().map { ["min": round3($0)] }
            } else if let speed = last.speed {
                link["speedMbps"] = round3(speed)
            }
            network["link"] = link.compactMapValues { $0 }
        }
        return [
            "from": iso(h.from), "to": iso(h.to), "pointSeconds": Int(h.bucketMs / 1000),
            "vms": vms, "host": host.compactMapValues { $0 }, "network": network.compactMapValues { $0 },
            "eventCount": h.events.count,
        ]
    }

    static func probeStats(_ points: [ProbePoint]) -> [String: Any]? {
        guard !points.isEmpty else { return nil }
        let sent = points.reduce(0) { $0 + $1.sent }, lost = points.reduce(0) { $0 + $1.lost }
        var d: [String: Any] = ["sent": sent, "lost": lost]
        if let m = median(points.compactMap(\.rtt)) { d["median"] = round3(m) }
        if let peak = points.compactMap({ p in p.rttMax.map { (p.t, $0) } }).max(by: { $0.1 < $1.1 }) {
            d["peak"] = round3(peak.1); d["peakAt"] = iso(peak.0)
        }
        return d
    }

    public static func round3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }

    public static func iso(_ ms: Int64) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date(ms: ms))
    }
}
