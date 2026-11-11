import Foundation
import SwiftUI
import UTMWatchCore
import UTMWatchStore

/// Series colors: a fixed order validated for colorblind separation, one step per appearance.
enum SeriesPalette {
    static let light: [UInt32] = [0x2a78d6, 0xeb6834, 0x1baf7a, 0xeda100, 0xe87ba4, 0x008300, 0x6250d6, 0xe34948]
    static let dark: [UInt32] = [0x3987e5, 0xd95926, 0x199e70, 0xc98500, 0xd55181, 0x008300, 0x9085e9, 0xe66767]

    static func color(index: Int, scheme: ColorScheme) -> Color {
        let hex = (scheme == .dark ? dark : light)[max(0, index) % 8]
        return Color(red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255)
    }
}

/// What the table and tiles show for one moment.
struct Readout {
    struct Row: Identifiable {
        var id: String
        var name: String
        var colorIndex: Int
        var state: String
        var backend: String
        var cpu: String
        var mem: String
        var down: String
        var up: String
        var total: String
        var ping: String = "—"
        var cpuWarning: String?
    }

    var kind: String
    var time: Date
    var rows: [Row]
    var host: HostSummary?
    var link: LinkInfo?

    /// The point closest to `t`, if one lies within `tolerance` milliseconds.
    static func nearest<P>(_ points: [P], t: Int64, tolerance: Double, time: (P) -> Int64) -> P? {
        guard !points.isEmpty else { return nil }
        var lo = 0, hi = points.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if time(points[mid]) < t { lo = mid + 1 } else { hi = mid }
        }
        var best = points[lo]
        if lo > 0, abs(time(points[lo - 1]) - t) < abs(time(best) - t) { best = points[lo - 1] }
        return Double(abs(time(best) - t)) <= tolerance ? best : nil
    }

    static func tolerance(_ h: History) -> Double { max(h.bucketMs * 1.5, 6000) }

    /// Live with nothing pinned or hovered: exactly what the engine just measured, including stopped VMs.
    static func ms(_ v: Double) -> String { v < 10 ? String(format: "%.1f ms", v) : "\(Int(v.rounded())) ms" }

    private static func pingText(_ points: [ProbePoint]?, t: Int64) -> String {
        guard let p = nearest(points ?? [], t: t, tolerance: 25_000, time: { $0.t }) else { return "—" }
        return p.rtt.map(ms) ?? "no reply"
    }

    static func now(snapshot: Snapshot, link: LinkInfo?, probes: [String: [ProbePoint]], order: [String], units: RateUnits) -> Readout {
        let nowMs = snapshot.timestamp.msSince1970
        let rows = snapshot.rows.map { r -> Row in
            let active = r.pid != nil
            var row = Row(id: r.id, name: r.name, colorIndex: order.firstIndex(of: r.id) ?? 0, state: r.status.rawValue, backend: r.backend.rawValue,
                       cpu: active ? Format.cores(r.cpuCores, r.cpuAllocated) : (r.cpuAllocated.map { "— / \($0) cores" } ?? "—"),
                       mem: active ? Format.memoryPair(r.memoryBytes, r.memoryAllocatedBytes) : (r.memoryAllocatedBytes.map { "— / \(Format.memory($0))" } ?? "—"),
                       down: active && r.identified ? Format.rate(r.downRate, units: units) : "—",
                       up: active && r.identified ? Format.rate(r.upRate, units: units) : "—",
                       total: totals(r.downTotal.map { Double($0) }, r.upTotal.map { Double($0) }),
                       cpuWarning: Explain.cpu(r))
            if active { row.ping = pingText(probes[ProbeTarget.vm(r.id)], t: nowMs) }
            return row
        }
        return Readout(kind: "Now", time: snapshot.timestamp, rows: rows, host: snapshot.host, link: link)
    }

    /// A past (or hovered) moment, read from the loaded history.
    static func at(_ date: Date, kind: String, history h: History, order: [String], units: RateUnits) -> Readout {
        let t = date.msSince1970
        let tol = tolerance(h)
        let rows = h.vms.map { vm -> Row in
            let cfg = h.config(for: vm.key, at: t)
            let idx = order.firstIndex(of: vm.key) ?? 0
            guard let p = nearest(h.series[vm.key] ?? [], t: t, tolerance: tol, time: { $0.t }) else {
                return Row(id: vm.key, name: vm.name, colorIndex: idx, state: "not running", backend: vm.backend,
                           cpu: cfg?.cores.map { "— / \($0) cores" } ?? "—", mem: "—", down: "—", up: "—", total: "—", cpuWarning: nil)
            }
            var warning: String?
            if let used = p.cpu, let limit = cfg?.cores, limit > 0, used >= 0.9 * Double(limit) {
                warning = "\(vm.name) was using \(String(format: "%.1f", used)) of its \(limit) cores: at its CPU limit, so work inside it was waiting for processor time."
            }
            return Row(id: vm.key, name: vm.name, colorIndex: idx, state: "running", backend: vm.backend,
                       cpu: Format.cores(p.cpu, cfg?.cores),
                       mem: Format.memoryPair(p.mem.map { UInt64(max(0, $0)) }, cfg?.memBytes.map { UInt64(max(0, $0)) }),
                       down: Format.rate(p.down, units: units), up: Format.rate(p.up, units: units),
                       total: totals(p.downTotal, p.upTotal), ping: pingText(h.probes[ProbeTarget.vm(vm.key)], t: t), cpuWarning: warning)
        }
        let host = nearest(h.host, t: t, tolerance: tol, time: { $0.t }).map { p in
            HostSummary(totalMemory: HostStats.totalMemory, hostUsed: UInt64(max(0, p.used)), hostOtherUsed: UInt64(max(0, p.other)),
                        freeNow: UInt64(max(0, Double(HostStats.totalMemory) - p.used)), allocatable: UInt64(max(0, p.allocatable)),
                        pressure: p.pressure == 2 ? .critical : p.pressure == 1 ? .warning : .normal,
                        swapUsed: UInt64(max(0, p.swapUsed)), swapTotal: UInt64(max(0, p.swapTotal)),
                        physicalCores: HostStats.physicalCores, allocatedCores: p.cores, macOSRunning: 0)
        }
        let link = nearest(h.link, t: t, tolerance: max(tol, 25_000), time: { $0.t }).map { p -> LinkInfo in
            var l = LinkInfo(kind: p.kind, interface: p.interface)
            l.rssi = p.rssi.map { Int($0.rounded()) }; l.noise = p.noise.map { Int($0.rounded()) }
            l.txRateMbps = p.txRate; l.channel = p.channel; l.speedMbps = p.speed
            return l
        }
        return Readout(kind: kind, time: date, rows: rows, host: host, link: link)
    }

    private static func totals(_ down: Double?, _ up: Double?) -> String {
        guard let down, let up else { return "—" }
        return "\(Format.bytes(UInt64(max(0, down)))) / \(Format.bytes(UInt64(max(0, up))))"
    }
}
