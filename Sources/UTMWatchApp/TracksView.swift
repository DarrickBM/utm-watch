import SwiftUI
import UTMWatchCore
import UTMWatchStore

/// Stacked trend tracks on one shared time axis: events, CPU, memory, host swap, network down and up, and ping.
/// Each track carries its own readings beside the plot, and periods of memory pressure, weak Wi-Fi and
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
    /// Height the whole stack may use; the plots share what is left after the fixed lanes.
    var availableHeight: CGFloat = 0
    /// VM key to emphasize; lines of the other VMs are drawn faint.
    var focus: String? = nil
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
    }

    private struct LegendItem {
        var key: String? = nil
        var name: String
        var color: Color
        var value: String
        var warning: String? = nil
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
                 }),
            Spec(title: "Memory", unit: "used / limit", value: { $0.mem }, peak: { $0.mem }, yMax: memMax,
                 label: { Format.memory(UInt64(max(0, $0))) },
                 text: { p, cfg in Format.memoryPair(p.mem.map { UInt64(max(0, $0)) }, cfg?.memBytes.map { UInt64(max(0, $0)) }) }),
            Spec(title: "Network ↓", unit: "into the VM", value: { $0.down }, peak: { $0.downMax }, yMax: downMax,
                 label: { Format.rate($0, units: u) }, text: { p, _ in Format.rate(p.down, units: u) }),
            Spec(title: "Network ↑", unit: "out of the VM", value: { $0.up }, peak: { $0.upMax }, yMax: upMax,
                 label: { Format.rate($0, units: u) }, text: { p, _ in Format.rate(p.up, units: u) }),
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
                    Text(history.events.isEmpty ? "none in this range" : "\(history.events.count) in this range")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(width: labelWidth - labelGap, alignment: .leading).padding(.trailing, labelGap)
                eventsLane.frame(height: layout.events).padding(.trailing, gutter)
            }
            vmTrack(s[0], height: height(0))
            vmTrack(s[1], height: height(1))
            swapTrack(height: height(2))
            vmTrack(s[2], height: height(3))
            vmTrack(s[3], height: height(4))
            probeTrack(title: "Responsiveness", unit: "VM ping", height: height(5),
                       series: history.vms.map { ProbeSeries(key: $0.key, name: $0.name, color: color($0.key), points: history.probes[ProbeTarget.vm($0.key)] ?? []) })
            probeTrack(title: "Network path", unit: "from the Mac", height: height(6), series: [
                ProbeSeries(name: "Router", color: SeriesPalette.color(index: 2, scheme: scheme), points: history.probes[ProbeTarget.gateway] ?? []),
                ProbeSeries(name: "Internet", color: SeriesPalette.color(index: 6, scheme: scheme), points: history.probes[ProbeTarget.internet] ?? []),
            ])
            HStack(spacing: 0) {
                Color.clear.frame(width: labelWidth, height: axisHeight)
                axis.frame(height: axisHeight)
            }
        }
        .overlay { GeometryReader { geo in scrubber(size: geo.size) } }
        .overlay {
            if history.series.isEmpty {
                Text("No data recorded in this time frame").foregroundStyle(.secondary)
                    .padding(.leading, labelWidth)
            }
        }
    }

    // MARK: Labels with readings

    /// Title, unit and one line per series with its value at the readout moment.
    private func label(title: String, unit: String, items: [LegendItem], height: CGFloat) -> some View {
        var ordered = items
        if let focus, let i = ordered.firstIndex(where: { $0.key == focus }) { ordered.insert(ordered.remove(at: i), at: 0) }
        let fit = max(1, Int((height - 20) / 16))
        let shown = ordered.count > fit ? Array(ordered.prefix(fit - 1)) : ordered
        return VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.system(size: 13, weight: .semibold)).fixedSize()
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
                .help(item.warning ?? "")
            }
            if shown.count < ordered.count {
                Text("+\(ordered.count - shown.count) more").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .frame(width: labelWidth - labelGap, alignment: .leading).padding(.trailing, labelGap)
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

    private func vmTrack(_ spec: Spec, height: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 0) {
            label(title: spec.title, unit: spec.unit, items: vmItems(spec), height: height)
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
                    if showPeaks { ctx.stroke(path(spec.peak), with: .color(c.opacity(0.35 * k)), style: StrokeStyle(lineWidth: 1, lineJoin: .round)) }
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
        var item = LegendItem(name: "This Mac", color: line, value: "—")
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
            label(title: "Host swap", unit: unit, items: [item], height: height)
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

    private func probeTrack(title: String, unit: String, height: CGFloat, series: [ProbeSeries]) -> some View {
        let yMax = Self.niceMs(series.flatMap { $0.points.compactMap(\.rttMax) }.max() ?? 1)
        let tolerance = max(Readout.tolerance(history), 15_000)
        let items = series.map { s -> LegendItem in
            let p = Readout.nearest(s.points, t: readoutT, tolerance: tolerance, time: { $0.t })
            return LegendItem(key: s.key, name: s.name, color: s.color, value: p.map { $0.rtt.map(Self.ms) ?? "no reply" } ?? "—")
        }
        return HStack(alignment: .top, spacing: 0) {
            label(title: title, unit: unit, items: items, height: height)
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
                if pinX.map({ abs($0 - x) < 46 }) != true {
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

    static let pressureTint = Color.orange
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

        // Memory pressure, one band per unbroken run at the same level.
        var run: (from: Int64, to: Int64, level: Int)?
        func closePressure() {
            if let r = run { out.append(Band(from: r.from - half, to: r.to + half, color: (r.level == 2 ? Color.red : Self.pressureTint).opacity(0.17))) }
            run = nil
        }
        for p in history.host {
            if let r = run, r.level == p.pressure, Double(p.t - r.to) <= gap { run = (r.from, p.t, r.level); continue }
            closePressure()
            if p.pressure > 0 { run = (p.t, p.t, p.pressure) }
        }
        closePressure()

        // Weak Wi-Fi or no network at all, from the first bad reading to the next good one.
        var weakFrom: Int64?
        var weakLast: Int64 = 0
        let tint = Self.linkTint(scheme).opacity(0.15)
        for l in history.link {
            let weak = l.kind == "none" || (l.kind == "wifi" && (l.rssi ?? 0) <= -75)
            if weak {
                if weakFrom == nil { weakFrom = l.t }
                weakLast = l.t
            } else if let from = weakFrom {
                out.append(Band(from: from, to: l.t, color: tint))
                weakFrom = nil
            }
        }
        if let from = weakFrom { out.append(Band(from: from, to: max(weakLast + half, min(history.to, weakLast + Int64(gap))), color: tint)) }
        return out
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
