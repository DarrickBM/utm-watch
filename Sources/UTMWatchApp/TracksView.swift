import SwiftUI
import UTMWatchCore
import UTMWatchStore

/// Stacked trend tracks on one shared time axis: events, CPU, memory, host swap, network down and up, and ping.
/// Each track carries its own readings beside the plot, and periods of weak Wi-Fi and
/// missing data are shaded through every track so cause and effect line up by eye.
struct TracksView: View {
    let history: History
    let order: [String]
    let units: RateUnits
    /// Moment whose values are shown beside each track (nil = latest point).
    let readout: Int64?
    let pin: Int64?
    let hover: Int64?
    var onHover: (Int64?) -> Void
    var onPin: (Int64) -> Void

    @Environment(\.colorScheme) private var scheme
    /// The track whose label is under the pointer (-1 = Events), and its explanation.
    @State private var explainedIndex: Int?
    @State private var explainedText = ""
    /// Which title or legend entry asked for it, so leaving a different one does not close it.
    @State private var explainedKey: String?
    /// Height the whole stack may use; the plots share what is left after the fixed lanes.
    var availableHeight: CGFloat = 0
    /// VM key to emphasize; lines of the other VMs are drawn faint.
    var focus: String? = nil
    /// What the host's own lines are called: "This Mac", or another Mac's name in the fleet window.
    var hostName = "This Mac"
    private func strength(_ key: String) -> Double { focus == nil || focus == key ? 1 : 0.16 }

    /// Title, unit and per-series readings.
    private let labelWidth: CGFloat = 200
    private let labelGap: CGFloat = 16
    /// Axis labels sit to the right of the plot so they never cover data.
    private let gutter: CGFloat = 72
    private let axisHeight: CGFloat = 20
    /// Relative heights: CPU, memory, host swap, network down, network up, responsiveness, network path.
    private static let weights: [CGFloat] = [1.3, 1, 0.75, 1, 1, 1.1, 1]

    private struct Layout {
        var unit: CGFloat
        var spacing: CGFloat
        var events: CGFloat
        var compact: Bool
    }

    /// Roomy when the window allows it, otherwise tighter gaps and no unit captions.
    private var layout: Layout {
        let rows: CGFloat = history.events.count <= 1 ? 1 : (history.events.count <= 4 ? 2 : 3)
        guard availableHeight > 0 else { return Layout(unit: 84, spacing: 12, events: rows * 18, compact: false) }
        let total = Self.weights.reduce(0, +)
        let count = CGFloat(Self.weights.count)
        func unit(spacing: CGFloat, events: CGFloat) -> CGFloat {
            (availableHeight - events - axisHeight - spacing * (count + 1)) / total
        }
        let roomy = unit(spacing: 12, events: rows * 18)
        if roomy >= 58 { return Layout(unit: min(roomy, 150), spacing: 12, events: rows * 18, compact: false) }
        let events = min(rows, 2) * 18
        return Layout(unit: max(34, unit(spacing: 6, events: events)), spacing: 6, events: events, compact: true)
    }
    private func height(_ index: Int) -> CGFloat { (layout.unit * Self.weights[index]).rounded() }

    private struct Spec {
        var title: String
        var unit: String
        var value: (VMPoint) -> Double?
        var peak: (VMPoint) -> Double?
        var yMax: Double
        var label: (Double) -> String
        /// The reading shown beside the track for one VM.
        var text: (VMPoint, VMConfig?) -> String
        var warning: (VMPoint, VMConfig?, String) -> String? = { _, _, _ in nil }
        /// A second, dashed line per VM drawn behind the main one.
        var secondary: ((VMPoint) -> Double?)? = nil
        /// What the track shows, in plain words; appears when hovering its label.
        var explanation: String = ""
    }

    private struct LegendItem {
        var key: String? = nil
        var name: String
        var color: Color
        var value: String
        var warning: String? = nil
        /// What this one line means; shown while the pointer rests on it.
        var explanation: String? = nil
    }

    private var span: Double { Double(max(1, history.to - history.from)) }
    private func fraction(_ t: Int64) -> CGFloat { CGFloat(Double(t - history.from) / span) }
    private func color(_ key: String) -> Color { SeriesPalette.color(index: order.firstIndex(of: key) ?? 0, scheme: scheme) }
    private var readoutT: Int64 { readout ?? history.to }

    private var specs: [Spec] {
        let keys = history.vms.map(\.key)
        let cores = keys.compactMap { history.config(for: $0, at: history.to)?.cores }.max()
        let memLimit = keys.compactMap { history.config(for: $0, at: history.to)?.memBytes }.max()
        func dataMax(_ f: (VMPoint) -> Double?) -> Double { history.series.values.flatMap { $0.compactMap(f) }.max() ?? 0 }
        let cpuMax = Double(cores ?? Int(max(1, dataMax { $0.cpuMax }.rounded(.up))))
        let memMax: Double = memLimit ?? max(1_073_741_824.0, dataMax { $0.mem })
        let downMax = Self.nice(dataMax { $0.downMax }), upMax = Self.nice(dataMax { $0.upMax })
        let u = units
        return [
            Spec(title: "CPU", unit: "cores busy / limit", value: { $0.cpu }, peak: { $0.cpuMax }, yMax: cpuMax,
                 label: { Format.trimmed($0) },
                 text: { p, cfg in Format.cores(p.cpu, cfg?.cores) },
                 warning: { p, cfg, name in
                     guard let used = p.cpu, let limit = cfg?.cores, limit > 0, used >= 0.9 * Double(limit) else { return nil }
                     return "\(name) is using \(String(format: "%.1f", used)) of its \(limit) cores: at its CPU limit, so work inside it is waiting for processor time."
                 },
                 explanation: "Cores each VM is keeping busy, then the number it is allowed to use.\n\nHow it is measured: every sample, the CPU time the VM's process has used (user plus system) is compared with the previous sample and divided by the real time between them. 1.0 means one core fully busy. The limit is the CPU count in the VM's UTM configuration. Over long time frames each point is the average of its interval and the faint line is the peak."),
            // A VM's footprint stops moving once the guest has touched all its memory, so the line that
            // carries information is how much of it is in RAM right now; the footprint is the dashed line.
            // The footprint is the whole VM process, so it can read higher than the guest's configured memory.
            Spec(title: "Memory", unit: "in RAM / held (dashed)", value: { $0.res }, peak: { $0.res }, yMax: memMax,
                 label: { Format.memory(UInt64(max(0, $0))) },
                 text: { p, _ in
                     let held = p.mem.map { Format.memory(UInt64(max(0, $0))) } ?? "—"
                     // History recorded before the in-RAM figure was measured has only the footprint.
                     guard let inRAM = p.res else { return "held \(held)" }
                     return "\(String(format: "%.1f", inRAM / 1_073_741_824)) / \(held)"
                 },
                 secondary: { $0.mem },
                 explanation: "Solid line: how much of the VM's memory is in this Mac's RAM right now. Dashed line: how much the VM holds in total.\n\nHow it is measured: \"held\" is the physical footprint of the VM's process, including pages macOS has compressed or moved to swap; it matches Activity Monitor's Memory column. \"In RAM\" is the process's resident size, which leaves those pages out. Once a guest has touched all its memory the dashed line is usually flat. The gap between the two lines is memory the VM must wait for when it needs it again.\n\nWhy held can be more than the VM's memory size: held covers everything macOS charges to the VM's process, not only the guest's own memory. Memory the Mac uses on the VM's behalf, such as for its display, is counted too, so held can read higher than the memory size set in UTM."),
            Spec(title: "Network ↓", unit: "into the VM", value: { $0.down }, peak: { $0.downMax }, yMax: downMax,
                 label: { Format.rate($0, units: u) }, text: { p, _ in Format.rate(p.down, units: u) },
                 explanation: "Data arriving in each VM per second.\n\nHow it is measured: each VM has its own virtual network interface on this Mac (vmenetN), found by looking up the VM's MAC address in the bridge's address table. The interface's byte counters are read every sample and the change is divided by the time between samples. Directions are from the VM's point of view: down is into the VM. Units are decimal: 1 MB/s is 1,000,000 bytes per second. VMs on bridged networking show nothing here."),
            Spec(title: "Network ↑", unit: "out of the VM", value: { $0.up }, peak: { $0.upMax }, yMax: upMax,
                 label: { Format.rate($0, units: u) }, text: { p, _ in Format.rate(p.up, units: u) },
                 explanation: "Data each VM sends out per second.\n\nHow it is measured: the same way as Network ↓, from the byte counters of the VM's virtual network interface, read every sample. Up is out of the VM. A remote session streams the VM's screen, so this rises while someone is connected and the screen is changing."),
        ]
    }

    /// Smallest 1/2/5 x 10^k at or above `v` (at least 1 KB/s) so axis labels are round numbers.
    static func nice(_ v: Double) -> Double {
        var step = 1000.0
        while true {
            for m in [1.0, 2.0, 5.0] where step * m >= v { return step * m }
            step *= 10
        }
    }

    var body: some View {
        let s = specs
        return VStack(alignment: .leading, spacing: layout.spacing) {
            HStack(alignment: .top, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Events").font(.system(size: 13, weight: .semibold))
                        .contentShape(Rectangle())
                        .onHover { inside in
                            explain(-1, key: "title -1", "Things UTM Watch noticed in this time frame. Click a marker to pin that moment.\n\nWhat is recorded: a VM starting or stopping; macOS changing its memory pressure level; swap going above 80%; a VM held at 90% of its cores or more for a minute; the Wi-Fi signal weak for two readings in a row, or recovering; the network link going down or changing; and the Mac going to sleep or waking. Warnings are orange triangles, everything else is a circle.", inside)
                        }
                    Text(history.events.isEmpty ? "none in this range" : "\(history.events.count) in this range")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(width: labelWidth - labelGap, alignment: .leading).padding(.trailing, labelGap)
                eventsLane.frame(height: layout.events).padding(.trailing, gutter)
            }
            vmTrack(0, s[0], height: height(0))
            vmTrack(1, s[1], height: height(1))
            swapTrack(height: height(2))
            vmTrack(3, s[2], height: height(3))
            vmTrack(4, s[3], height: height(4))
            probeTrack(5, title: "Responsiveness", unit: "VM ping", height: height(5),
                       explanation: "How long each VM takes to answer a ping from this Mac.\n\nHow it is measured: every 10 seconds UTM Watch sends one ping (an ICMP echo) to the VM's address on the Mac's internal network and times the reply, waiting up to 1 second. The address comes from the Mac's ARP table, matched by the VM's MAC address. The reply never leaves the Mac, so it normally takes under 1 ms; a higher value means the VM itself was slow to react. A red tick is a ping with no reply. Over long time frames each point is the average and the faint line is the worst.",
                       series: history.vms.map { ProbeSeries(key: $0.key, name: $0.name, color: color($0.key), points: history.probes[ProbeTarget.vm($0.key)] ?? []) })
            probeTrack(6, title: "Network path", unit: "from the Mac", height: height(6),
                       explanation: "How long it takes to reach your router and the internet from this Mac. It separates network trouble from VM trouble: when a remote session lags while Responsiveness stays flat, the cause is on this path.\n\nHow it is measured: every 10 seconds, one ping to the router and one to the internet, each waiting up to 1 second. A red tick is a ping with no reply. Hover Router or Internet to see what each one covers.",
                       series: [
                ProbeSeries(name: "Router", color: SeriesPalette.color(index: 2, scheme: scheme), points: history.probes[ProbeTarget.gateway] ?? [],
                            explanation: "Router: the first stop for anything leaving this Mac, also called the default gateway. UTM Watch finds it from the Mac's routing table.\n\nThe time covers only the Mac's own link to the router, over Wi-Fi or cable. High values or lost pings mean that link was poor: weak Wi-Fi signal, interference, or a busy router. A short spike on its own can also be the router being slow to answer pings while it still passes traffic normally. If Internet stays flat at the same moment, traffic was not affected."),
                ProbeSeries(name: "Internet", color: SeriesPalette.color(index: 6, scheme: scheme), points: history.probes[ProbeTarget.internet] ?? [],
                            explanation: "Internet: a public server outside your network. UTM Watch pings two (1.1.1.1 and 223.5.5.5) and keeps the faster reply, so one server being unreachable does not look like an outage.\n\nThe time covers the whole way out: the Mac's link, your router, and your internet provider. If this rises while Router stays flat, the trouble is beyond your router. If both rise together, it is the Mac's own link. A remote user reaches a VM over this same path, so trouble here feels like lag even when the VM is fine."),
            ])
            HStack(spacing: 0) {
                Color.clear.frame(width: labelWidth, height: axisHeight)
                axis.frame(height: axisHeight)
            }
        }
        .overlay { GeometryReader { geo in scrubber(size: geo.size) } }
        .overlay(alignment: .topLeading) {
            if let index = explainedIndex {
                Text(explainedText).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .frame(width: 440, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.18)))
                    .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
                    .offset(x: labelWidth + 6, y: rowTop(index))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .overlay {
            if history.series.isEmpty {
                Text("No data recorded in this time frame").foregroundStyle(.secondary)
                    .padding(.leading, labelWidth)
            }
        }
    }

    // MARK: Labels with readings

    /// Title, unit and one line per series with its value at the readout moment.
    private func label(index: Int, title: String, unit: String, items: [LegendItem], height: CGFloat, explanation: String) -> some View {
        var ordered = items
        if let focus, let i = ordered.firstIndex(where: { $0.key == focus }) { ordered.insert(ordered.remove(at: i), at: 0) }
        let fit = max(1, Int((height - 20) / 16))
        let shown = ordered.count > fit ? Array(ordered.prefix(fit - 1)) : ordered
        return VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.system(size: 13, weight: .semibold)).fixedSize()
                    .contentShape(Rectangle())
                    .onHover { inside in explain(index, key: "title \(index)", explanation, inside) }
                if !layout.compact { Text(unit).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
            }
            .padding(.bottom, 2)
            ForEach(Array(shown.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 1.5).fill(item.color).frame(width: 10, height: 3)
                    Text(item.name).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 4)
                    if item.warning != nil {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(.orange)
                            .accessibilityLabel("Warning")
                    }
                    Text(item.value).monospacedDigit().fixedSize()
                }
                .font(.system(size: 12))
                .opacity(item.key.map { strength($0) == 1 ? 1 : 0.45 } ?? 1)
                .contentShape(Rectangle())
                .onHover { inside in
                    // Most lines are just a VM's name and its reading. Only a line with a warning, or a term
                    // that needs explaining (Router, Internet), says something on hover.
                    let text = [item.warning, item.explanation].compactMap { $0 }.joined(separator: "\n\n")
                    // Leaving always closes, even if the warning cleared while the pointer was here.
                    if !inside || !text.isEmpty { explain(index, key: "item \(index) \(item.name)", text, inside) }
                }
            }
            if shown.count < ordered.count {
                Text("+\(ordered.count - shown.count) more").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .frame(width: labelWidth - labelGap, alignment: .leading).padding(.trailing, labelGap)
    }

    /// Shows a track's explanation while the pointer rests on its label.
    private func explain(_ index: Int, key: String, _ text: String, _ inside: Bool) {
        if inside {
            explainedKey = key; explainedText = text; explainedIndex = index
        } else if explainedKey == key {
            explainedKey = nil; explainedIndex = nil
        }
    }

    /// Top of a track's row inside the stack, so the explanation can sit beside the label that asked for it.
    private func rowTop(_ index: Int) -> CGFloat {
        guard index >= 0 else { return 0 }
        var y = layout.events + layout.spacing
        for i in 0..<index { y += height(i) + layout.spacing }
        return availableHeight > 0 ? min(y, max(0, availableHeight - 230)) : y
    }

    private func vmItems(_ spec: Spec) -> [LegendItem] {
        history.vms.map { vm in
            let p = Readout.nearest(history.series[vm.key] ?? [], t: readoutT, tolerance: Readout.tolerance(history), time: { $0.t })
            let cfg = history.config(for: vm.key, at: readoutT)
            return LegendItem(key: vm.key, name: vm.name, color: color(vm.key),
                              value: p.map { spec.text($0, cfg) } ?? "not running",
                              warning: p.flatMap { spec.warning($0, cfg, vm.name) })
        }
    }

    // MARK: Shared drawing

    /// Grid lines, the baseline and the axis labels in the right-hand gutter. Returns the plot width.
    private func drawFrame(_ ctx: inout GraphicsContext, size: CGSize, y: (Double) -> CGFloat, labels: [(Double, String)]) -> CGFloat {
        let w = max(1, size.width - gutter)
        for (v, text) in labels {
            var line = Path(); line.move(to: CGPoint(x: 0, y: y(v))); line.addLine(to: CGPoint(x: w, y: y(v)))
            ctx.stroke(line, with: .color(Color.primary.opacity(0.10)), lineWidth: 1)
            ctx.draw(Text(text).font(.system(size: 11)).foregroundStyle(.secondary), at: CGPoint(x: w + 8, y: y(v)), anchor: .leading)
        }
        var base = Path(); base.move(to: CGPoint(x: 0, y: size.height - 0.5)); base.addLine(to: CGPoint(x: w, y: size.height - 0.5))
        ctx.stroke(base, with: .color(Color.primary.opacity(0.28)), lineWidth: 1)
        return w
    }

    private func dot(_ ctx: inout GraphicsContext, at c: CGPoint, color: Color) {
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - 6, y: c.y - 6, width: 12, height: 12)), with: .color(Color(nsColor: .textBackgroundColor)))
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)), with: .color(color))
    }

    // MARK: Per-VM tracks

    private func vmTrack(_ index: Int, _ spec: Spec, height: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 0) {
            label(index: index, title: spec.title, unit: spec.unit, items: vmItems(spec), height: height, explanation: spec.explanation)
            Canvas { ctx, size in
                func y(_ v: Double) -> CGFloat { size.height - CGFloat(min(1.08, v / spec.yMax)) * size.height * 0.92 }
                let w = drawFrame(&ctx, size: size, y: y, labels: [(spec.yMax, spec.label(spec.yMax)), (spec.yMax / 2, spec.label(spec.yMax / 2))])

                // A line is broken wherever samples are missing (Mac asleep, app not running, VM stopped).
                let gap = max(history.bucketMs * 3, 10_000)
                let showPeaks = history.bucketMs > 5000
                for vm in history.vms {
                    let points = history.series[vm.key] ?? []
                    let c = color(vm.key)
                    func path(_ f: (VMPoint) -> Double?) -> Path {
                        var p = Path()
                        var last: Int64?
                        for pt in points {
                            guard let v = f(pt) else { last = nil; continue }
                            let pos = CGPoint(x: fraction(pt.t) * w, y: y(v))
                            if let l = last, Double(pt.t - l) <= gap { p.addLine(to: pos) } else { p.move(to: pos) }
                            last = pt.t
                        }
                        return p
                    }
                    let k = strength(vm.key)
                    if let secondary = spec.secondary {
                        ctx.stroke(path(secondary), with: .color(c.opacity(0.6 * k)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round, dash: [5, 4]))
                    } else if showPeaks {
                        ctx.stroke(path(spec.peak), with: .color(c.opacity(0.35 * k)), style: StrokeStyle(lineWidth: 1, lineJoin: .round))
                    }
                    ctx.stroke(path(spec.value), with: .color(c.opacity(k)), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }

                // Dots where the readout moment crosses each line.
                if readout != nil {
                    for vm in history.vms where strength(vm.key) == 1 {
                        guard let p = Readout.nearest(history.series[vm.key] ?? [], t: readoutT, tolerance: Readout.tolerance(history), time: { $0.t }),
                              let v = spec.value(p) else { continue }
                        dot(&ctx, at: CGPoint(x: fraction(p.t) * w, y: y(v)), color: color(vm.key))
                    }
                }
            }
            .frame(height: height)
            .accessibilityLabel("\(spec.title) trend for each VM over the selected time frame")
        }
    }

    // MARK: Host swap

    /// Swap is the host-side cause behind most slow spells, so it gets its own history with the alert line.
    private func swapTrack(height: CGFloat) -> some View {
        let total = history.host.map(\.swapTotal).max() ?? 0
        let yMax = total > 0 ? total : max(1_073_741_824.0, history.host.map(\.swapUsed).max() ?? 0)
        let point = Readout.nearest(history.host, t: readoutT, tolerance: Readout.tolerance(history), time: { $0.t })
        let line = Color.primary.opacity(0.72)
        var item = LegendItem(name: hostName, color: line, value: "—")
        if let p = point {
            if p.swapTotal > 0 {
                let used = p.swapUsed / p.swapTotal
                item.value = "\(Format.memory(UInt64(max(0, p.swapUsed)))), \(Int((used * 100).rounded()))%"
                if used >= 0.8 {
                    item.warning = "Swap is \(Int((used * 100).rounded()))% full. Memory that does not fit in RAM is being moved to disk, which is much slower. Above 80% is treated as a warning."
                }
            } else {
                item.value = "off"
            }
        }
        let unit = total > 0 ? "used of \(Format.memory(UInt64(total)))" : "used"
        return HStack(alignment: .top, spacing: 0) {
            label(index: 2, title: "Host swap", unit: unit, items: [item], height: height,
                  explanation: "How much of this Mac's swap space on disk is in use. Swap fills up when what is running does not fit in RAM, and reading it back is much slower than RAM.\n\nHow it is measured: read from macOS (vm.swapusage) every sample: the bytes in use and the current size of the swap file, which macOS grows as needed. The dashed line is 80% of the largest swap size in this time frame. UTM Watch records an event when use goes above 80%.")
            Canvas { ctx, size in
                func y(_ v: Double) -> CGFloat { size.height - CGFloat(min(1.08, v / yMax)) * size.height * 0.92 }
                let w = drawFrame(&ctx, size: size, y: y, labels: [(yMax / 2, Format.memory(UInt64(yMax / 2)))])
                if total > 0 {
                    var limit = Path(); limit.move(to: CGPoint(x: 0, y: y(total * 0.8))); limit.addLine(to: CGPoint(x: w, y: y(total * 0.8)))
                    ctx.stroke(limit, with: .color(Color.primary.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    ctx.draw(Text("80%").font(.system(size: 11)), at: CGPoint(x: w + 8, y: y(total * 0.8)), anchor: .leading)
                }
                let gap = max(history.bucketMs * 3, 10_000)
                var path = Path()
                var last: Int64?
                for pt in history.host {
                    let pos = CGPoint(x: fraction(pt.t) * w, y: y(pt.swapUsed))
                    if let l = last, Double(pt.t - l) <= gap { path.addLine(to: pos) } else { path.move(to: pos) }
                    last = pt.t
                }
                ctx.stroke(path, with: .color(line), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                if readout != nil, let p = point { dot(&ctx, at: CGPoint(x: fraction(p.t) * w, y: y(p.swapUsed)), color: .primary) }
            }
            .frame(height: height)
            .accessibilityLabel("Host swap used over the selected time frame; the dashed line is the 80% alert level")
        }
    }

    // MARK: Ping tracks

    private struct ProbeSeries {
        var key: String? = nil
        var name: String
        var color: Color
        var points: [ProbePoint]
        var explanation: String? = nil
    }

    private static func ms(_ v: Double) -> String { v < 10 ? String(format: "%.1f ms", v) : "\(Int(v.rounded())) ms" }

    /// Smallest 1/2/5 x 10^k milliseconds at or above `v`, at least 1 ms.
    static func niceMs(_ v: Double) -> Double {
        var step = 1.0
        while true {
            for m in [1.0, 2.0, 5.0] where step * m >= v { return step * m }
            step *= 10
        }
    }

    private func probeTrack(_ index: Int, title: String, unit: String, height: CGFloat, explanation: String, series: [ProbeSeries]) -> some View {
        let yMax = Self.niceMs(series.flatMap { $0.points.compactMap(\.rttMax) }.max() ?? 1)
        let tolerance = max(Readout.tolerance(history), 15_000)
        let items = series.map { s -> LegendItem in
            let p = Readout.nearest(s.points, t: readoutT, tolerance: tolerance, time: { $0.t })
            return LegendItem(key: s.key, name: s.name, color: s.color, value: p.map { $0.rtt.map(Self.ms) ?? "no reply" } ?? "—",
                              explanation: s.explanation)
        }
        return HStack(alignment: .top, spacing: 0) {
            label(index: index, title: title, unit: unit, items: items, height: height, explanation: explanation)
            Canvas { ctx, size in
                func y(_ v: Double) -> CGFloat { size.height - CGFloat(min(1.08, v / yMax)) * size.height * 0.92 }
                let w = drawFrame(&ctx, size: size, y: y, labels: [(yMax, Self.ms(yMax)), (yMax / 2, Self.ms(yMax / 2))])
                let gap = max(history.bucketMs * 3, 35_000)
                for s in series {
                    let bucketed = s.points.contains { $0.sent > 1 }
                    func path(_ f: (ProbePoint) -> Double?) -> Path {
                        var p = Path()
                        var last: Int64?
                        for pt in s.points {
                            guard let v = f(pt) else { last = nil; continue }
                            let pos = CGPoint(x: fraction(pt.t) * w, y: y(v))
                            if let l = last, Double(pt.t - l) <= gap { p.addLine(to: pos) } else { p.move(to: pos) }
                            last = pt.t
                        }
                        return p
                    }
                    let k = s.key.map(strength) ?? 1
                    if bucketed { ctx.stroke(path { $0.rttMax }, with: .color(s.color.opacity(0.35 * k)), style: StrokeStyle(lineWidth: 1, lineJoin: .round)) }
                    ctx.stroke(path { $0.rtt }, with: .color(s.color.opacity(k)), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    // Lost pings: a red tick on the baseline, so loss is visible even when the line simply stops.
                    for pt in s.points where pt.lost > 0 {
                        let x = fraction(pt.t) * w
                        ctx.fill(Path(CGRect(x: x - 1, y: size.height - 8, width: 2, height: 8)), with: .color(.red))
                    }
                    if readout != nil, k == 1, let p = Readout.nearest(s.points, t: readoutT, tolerance: tolerance, time: { $0.t }), let v = p.rtt {
                        dot(&ctx, at: CGPoint(x: fraction(p.t) * w, y: y(v)), color: s.color)
                    }
                }
            }
            .frame(height: height)
            .accessibilityLabel("\(title): ping time over the selected time frame; red ticks mark lost pings")
        }
    }

    // MARK: Events and axis

    private var eventsLane: some View {
        Canvas { ctx, size in
            var rowEnd = [CGFloat](repeating: -1000, count: max(1, Int(size.height / 18)))
            for e in history.events {
                let x = fraction(e.ts) * size.width
                let width = CGFloat(e.label.count) * 6.3 + 16
                let flip = x + width > size.width
                let from = flip ? x - width : x - 5
                let row = rowEnd.firstIndex(where: { from >= $0 + 4 })
                let yy = CGFloat(row ?? 0) * 18 + 9
                let marker = CGRect(x: x - 4, y: yy - 4, width: 8, height: 8)
                if e.isWarning {
                    var tri = Path(); tri.move(to: CGPoint(x: x, y: yy - 5)); tri.addLine(to: CGPoint(x: x + 5, y: yy + 4)); tri.addLine(to: CGPoint(x: x - 5, y: yy + 4)); tri.closeSubpath()
                    ctx.fill(tri, with: .color(.orange))
                } else {
                    ctx.stroke(Path(ellipseIn: marker), with: .color(.primary), lineWidth: 1.5)
                }
                if let row {
                    rowEnd[row] = flip ? x + 5 : x + width
                    ctx.draw(Text(e.label).font(.system(size: 11)), at: CGPoint(x: flip ? x - 9 : x + 9, y: yy), anchor: flip ? .trailing : .leading)
                }
            }
        }
        .accessibilityLabel("Events in the selected time frame; click a marker to pin that moment")
    }

    /// Tick labels land on round clock times; the one under the pin flag is left out.
    private var axis: some View {
        Canvas { ctx, size in
            let w = max(1, size.width - gutter)
            let steps: [Double] = [10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200, 10_800, 21_600, 43_200, 86_400].map { $0 * 1000 }
            let step = steps.first { span / $0 <= 8 } ?? 86_400_000
            let f = DateFormatter()
            f.dateFormat = step >= 86_400_000 ? "EEE d MMM" : (span >= 86_400_000 ? "EEE d HH:mm" : (step < 60_000 ? "HH:mm:ss" : "HH:mm"))
            let offset = Double(TimeZone.current.secondsFromGMT(for: Date(ms: history.from))) * 1000
            let pinX: CGFloat? = pin.flatMap { $0 >= history.from && $0 <= history.to ? fraction($0) * w : nil }
            var t = ((Double(history.from) + offset) / step).rounded(.up) * step - offset
            while t <= Double(history.to) {
                let x = fraction(Int64(t)) * w
                if pinX.map({ abs($0 - x) < 62 }) != true {
                    let text = Text(f.string(from: Date(ms: Int64(t)))).font(.system(size: 11)).foregroundStyle(.secondary)
                    let anchor: UnitPoint = x < 24 ? .leading : (x > w - 24 ? .trailing : .center)
                    ctx.draw(text, at: CGPoint(x: x, y: size.height / 2), anchor: anchor)
                }
                t += step
            }
        }
    }

    // MARK: Shaded periods

    private struct Band {
        var from: Int64
        var to: Int64
        var color: Color
    }

    static func linkTint(_ scheme: ColorScheme) -> Color { SeriesPalette.color(index: 6, scheme: scheme) }

    private var bands: [Band] {
        var out: [Band] = []
        let half = Int64(history.bucketMs / 2)
        let gap = max(history.bucketMs * 3, 30_000)

        // Nothing recorded: the Mac was asleep or the app was not running.
        if let first = history.host.first, let last = history.host.last {
            let none = Color.primary.opacity(0.06)
            if Double(first.t - history.from) > gap { out.append(Band(from: history.from, to: first.t, color: none)) }
            for (a, b) in zip(history.host, history.host.dropFirst()) where Double(b.t - a.t) > gap {
                out.append(Band(from: a.t, to: b.t, color: none))
            }
            if Double(history.to - last.t) > gap { out.append(Band(from: last.t, to: history.to, color: none)) }
        }

        // Memory pressure is not shaded: on a Mac that is short of memory it is on most of the time, and the
        // status row and the event markers already report it.

        // Weak Wi-Fi or no network at all, from the first bad reading to the next good one.
        var weakBands: [Band] = []
        var weakFrom: Int64?
        var weakLast: Int64 = 0
        let tint = Self.linkTint(scheme).opacity(0.15)
        for l in history.link {
            let weak = l.kind == "none" || (l.kind == "wifi" && (l.rssi ?? 0) <= -75)
            if weak {
                if weakFrom == nil { weakFrom = l.t }
                weakLast = l.t
            } else if let from = weakFrom {
                weakBands.append(Band(from: from, to: l.t, color: tint))
                weakFrom = nil
            }
        }
        if let from = weakFrom { weakBands.append(Band(from: from, to: max(weakLast + half, min(history.to, weakLast + Int64(gap))), color: tint)) }
        if !covers(weakBands) { out += weakBands }
        return out
    }

    /// True when the bands together fill (nearly) the whole visible frame.
    private func covers(_ bands: [Band]) -> Bool {
        let total = bands.reduce(0.0) { $0 + Double(max(0, min($1.to, history.to) - max($1.from, history.from))) }
        return total >= 0.9 * span
    }

    // MARK: Crosshair, pin and pointer handling

    private func scrubber(size: CGSize) -> some View {
        let plotWidth = max(1, size.width - labelWidth - gutter)
        let height = size.height - axisHeight
        let eventsHeight = layout.events
        func time(_ x: CGFloat) -> Int64 { history.from + Int64(Double(min(max(0, x), plotWidth) / plotWidth) * span) }
        return ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in
                func vertical(_ t: Int64, from top: CGFloat = 0) -> Path {
                    let x = labelWidth + fraction(t) * plotWidth
                    var p = Path(); p.move(to: CGPoint(x: x, y: top)); p.addLine(to: CGPoint(x: x, y: height)); return p
                }
                for b in bands {
                    let from = max(b.from, history.from), to = min(b.to, history.to)
                    guard to > from else { continue }
                    let x = labelWidth + fraction(from) * plotWidth
                    let rect = CGRect(x: x, y: eventsHeight, width: max(1.5, fraction(to) * plotWidth - fraction(from) * plotWidth), height: height - eventsHeight)
                    ctx.fill(Path(rect), with: .color(b.color))
                }
                for e in history.events {
                    ctx.stroke(vertical(e.ts, from: 14), with: .color(Color.primary.opacity(0.22)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                if let hover, hover >= history.from, hover <= history.to {
                    ctx.stroke(vertical(hover), with: .color(Color.primary.opacity(0.4)), lineWidth: 1)
                }
                if let pin, pin >= history.from, pin <= history.to {
                    ctx.stroke(vertical(pin), with: .color(.primary), lineWidth: 2)
                    let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
                    let x = labelWidth + fraction(pin) * plotWidth
                    let label = ctx.resolve(Text(f.string(from: Date(ms: pin))).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color(nsColor: .textBackgroundColor)))
                    let w = label.measure(in: CGSize(width: 200, height: 20)).width + 12
                    let left = min(max(labelWidth, x - w / 2), labelWidth + plotWidth - w)
                    ctx.fill(Path(roundedRect: CGRect(x: left, y: height + 2, width: w, height: 16), cornerRadius: 4), with: .color(.primary))
                    ctx.draw(label, at: CGPoint(x: left + w / 2, y: height + 10), anchor: .center)
                }
            }
            .allowsHitTesting(false)

            Color.clear
                .contentShape(Rectangle())
                .frame(width: plotWidth, height: height)
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p): onHover(time(p.x))
                    case .ended: onHover(nil)
                    }
                }
                .gesture(SpatialTapGesture().onEnded { tap in
                    // A click on an event marker pins exactly that event.
                    if tap.location.y <= eventsHeight + 4,
                       let e = history.events.min(by: { abs(fraction($0.ts) * plotWidth - tap.location.x) < abs(fraction($1.ts) * plotWidth - tap.location.x) }),
                       abs(fraction(e.ts) * plotWidth - tap.location.x) <= 10 {
                        onPin(e.ts)
                    } else {
                        onPin(time(tap.location.x))
                    }
                })
                .offset(x: labelWidth)
                .accessibilityLabel("Time scrubber: hover to read a moment, click to pin it, then use the left and right arrow keys to step and Escape to unpin")
        }
    }
}
