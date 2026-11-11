import Foundation
import UTMWatchCore

enum SortKey: String, CaseIterable {
    case name, cpu, mem, net
    var next: SortKey { let all = Self.allCases; return all[(all.firstIndex(of: self)! + 1) % all.count] }
}

struct UIState {
    var interval: RefreshInterval
    var sort: SortKey = .name
    var showStopped = true
    var units: RateUnits = .bytes
}

/// Turns a snapshot into terminal lines. Pure, so it is easy to test and to reuse for --once.
enum Renderer {
    private static let clock: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()

    static func sortedRows(_ rows: [VMRow], state: UIState) -> [VMRow] {
        let visible = state.showStopped ? rows : rows.filter { $0.pid != nil || $0.status.isActive }
        // Running VMs first, then by the chosen key; unidentified ones after identified ones within a tie.
        return visible.sorted { a, b in
            let aRun = a.pid != nil, bRun = b.pid != nil
            if aRun != bRun { return aRun }
            switch state.sort {
            case .name: break
            case .cpu: if (a.cpuCores ?? -1) != (b.cpuCores ?? -1) { return (a.cpuCores ?? -1) > (b.cpuCores ?? -1) }
            case .mem: if (a.memoryBytes ?? 0) != (b.memoryBytes ?? 0) { return (a.memoryBytes ?? 0) > (b.memoryBytes ?? 0) }
            case .net:
                let an = (a.downRate ?? -1) + (a.upRate ?? 0), bn = (b.downRate ?? -1) + (b.upRate ?? 0)
                if an != bn { return an > bn }
            }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    struct Column { var title: String; var width: Int; var align: Format.Align }

    static func render(_ snap: Snapshot, state: UIState, width: Int, interactive: Bool) -> [String] {
        let rows = sortedRows(snap.rows, state: state)
        let running = snap.rows.filter { $0.pid != nil }
        let totalCores = running.reduce(0.0) { $0 + ($1.cpuCores ?? 0) }
        var lines: [String] = []

        // Header
        let left = "utmwatch · \(running.count) VM · \(String(format: "%.1f", totalCores)) cores · refresh \(Int(snap.intervalSeconds))s"
        let right = clock.string(from: snap.timestamp)
        lines.append(Format.pad(left, max(0, width - right.count - 1)) + " " + right)
        lines.append("")

        // Columns, dropping the rightmost ones on narrow terminals.
        let gap = 2
        let nameNeeded = max(2, rows.map { Format.displayWidth($0.name) }.max() ?? 2)
        var cols: [Column] = [
            Column(title: "VM", width: 0, align: .left),
            Column(title: "State", width: 8, align: .left),
            Column(title: "Backend", width: 7, align: .left),
            Column(title: "CPU", width: 14, align: .right),
            Column(title: "Memory", width: 14, align: .right),
            Column(title: "↓ Down", width: 11, align: .right),
            Column(title: "↑ Up", width: 11, align: .right),
            Column(title: "Total ↓/↑", width: 16, align: .right),
        ]
        func fixedWidth() -> Int { cols.dropFirst().reduce(0) { $0 + $1.width } + gap * (cols.count - 1) }
        while cols.count > 4 && fixedWidth() + 12 > width { cols.removeLast() }
        cols[0].width = max(4, min(nameNeeded, width - fixedWidth()))

        func line(_ cells: [String]) -> String {
            zip(cells, cols).map { Format.pad($0, $1.width, $1.align) }.joined(separator: String(repeating: " ", count: gap))
        }
        lines.append(line(cols.map(\.title)))
        if rows.isEmpty {
            lines.append("  (no virtual machines found)")
        }
        for r in rows {
            let active = r.pid != nil
            let cpu = active ? Format.cores(r.cpuCores, r.cpuAllocated) : (r.cpuAllocated.map { "— / \($0) cores" } ?? "—")
            let mem = active ? Format.memoryPair(r.memoryBytes, r.memoryAllocatedBytes) : (r.memoryAllocatedBytes.map { "— / \(Format.memory($0))" } ?? "—")
            let down = active && r.identified ? Format.rate(r.downRate, units: state.units) : "—"
            let up = active && r.identified ? Format.rate(r.upRate, units: state.units) : "—"
            let total: String
            if let d = r.downTotal, let u = r.upTotal { total = "\(Format.bytes(d)) / \(Format.bytes(u))" } else { total = "—" }
            lines.append(line([r.name, r.status.rawValue, r.backend.rawValue, cpu, mem, down, up, total]))
        }

        // Footer
        lines.append(String(repeating: "─", count: width))
        let h = snap.host
        let full = h.macOSRunning >= h.macOSLimit ? " (full)" : ""
        let over = h.overcommitted ? " (overcommitted: VMs will compete for CPU under full load)" : ""
        lines.append("Headroom  macOS VMs \(h.macOSRunning)/\(h.macOSLimit)\(full)  ·  Allocatable \(Format.memory(h.allocatable)) (free now \(Format.memory(h.freeNow)))  ·  Cores allocated \(h.allocatedCores)/\(h.physicalCores)\(over)")
        let swap = h.swapTotal > 0 ? "Swap \(Format.memory(h.swapUsed)) / \(Format.memory(h.swapTotal))" : "Swap off"
        lines.append("Host      Memory pressure \(h.pressure.rawValue)  ·  \(swap)  ·  Used \(Format.memory(h.hostUsed)) of \(Format.memory(h.totalMemory)) (\(Format.memory(h.hostOtherUsed)) outside VMs)")
        for n in snap.notices { lines.append("Note      \(n)") }
        if interactive {
            lines.append("")
            let stopped = state.showStopped ? "shown" : "hidden"
            let units = state.units == .bytes ? "MB/s" : "Mbps"
            lines.append("1/2/5 interval  s sort: \(state.sort.rawValue)  h stopped: \(stopped)  u units: \(units)  r refresh  q quit")
        }
        return lines.map { Format.displayWidth($0) > width ? Format.pad($0, width) : $0 }
    }
}
