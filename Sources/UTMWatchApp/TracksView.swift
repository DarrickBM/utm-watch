import SwiftUI
import UTMWatchCore
import UTMWatchStore

/// Stacked trend tracks on one shared time axis: events, host pressure, CPU, memory, network down and up.
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
    /// Height the whole stack may use; the six plots share what is left after the fixed lanes.
    var availableHeight: CGFloat = 0
    /// VM key to emphasize; lines of the other VMs are drawn faint.
    var focus: String? = nil
    private func strength(_ key: String) -> Double { focus == nil || focus == key ? 1 : 0.16 }

    private let labelWidth: CGFloat = 150
    private let axisHeight: CGFloat = 18
    private let pressureHeight: CGFloat = 12
    private static let plotCount: CGFloat = 6

    /// Roomy when the window allows it, otherwise tighter gaps, a two-row events lane and no unit captions.
    private var layout: (plot: CGFloat, spacing: CGFloat, events: CGFloat, compact: Bool) {
        guard availableHeight > 0 else { return (92, 10, 54, false) }
        func plot(spacing: CGFloat, events: CGFloat) -> CGFloat {
            (availableHeight - events - pressureHeight - axisHeight - spacing * (Self.plotCount + 2)) / Self.plotCount
        }
        let roomy = plot(spacing: 10, events: 54)
        if roomy >= 64 { return (min(roomy, 170), 10, 54, false) }
        return (max(36, plot(spacing: 6, events: 36)), 6, 36, true)
    }
    private var plotHeight: CGFloat { layout.plot }

    private struct Spec {
        var title: String
        var unit: String
        var value: (VMPoint) -> Double?
        var peak: (VMPoint) -> Double?
        var yMax: Double
        var label: (Double) -> String
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
            Spec(title: "CPU", unit: "cores busy", value: { $0.cpu }, peak: { $0.cpuMax }, yMax: cpuMax, label: { String(format: "%.1f", $0) }),
            Spec(title: "Memory", unit: "footprint", value: { $0.mem }, peak: { $0.mem }, yMax: memMax, label: { Format.memory(UInt64(max(0, $0))) }),
            Spec(title: "Network ↓", unit: "download into the VM", value: { $0.down }, peak: { $0.downMax }, yMax: downMax, label: { Format.rate($0, units: u) }),
            Spec(title: "Network ↑", unit: "upload from the VM", value: { $0.up }, peak: { $0.upMax }, yMax: upMax, label: { Format.rate($0, units: u) }),
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
        VStack(alignment: .leading, spacing: layout.spacing) {
            row(title: "Events", unit: "starts, stops, alerts") { eventsLane.frame(height: layout.events) }
            HStack(alignment: .center, spacing: 0) {
                HStack {
                    Text("Host pressure").font(.system(size: 12, weight: .semibold))
                    Spacer()
                }.frame(width: labelWidth - 12).padding(.trailing, 12)
                pressureLane.frame(height: pressureHeight)
            }
            ForEach(Array(specs.enumerated()), id: \.offset) { _, spec in
                HStack(alignment: .top, spacing: 0) {
                    trackLabel(spec).frame(width: labelWidth - 12, alignment: .leading).padding(.trailing, 12)
                    plot(spec).frame(height: plotHeight)
                }
            }
            probeTrack(title: "Responsiveness", unit: "ping from the Mac to the VM", legend: false,
                       series: history.vms.map { ProbeSeries(key: $0.key, name: $0.name, color: color($0.key), points: history.probes[ProbeTarget.vm($0.key)] ?? []) })
            probeTrack(title: "Network path", unit: "ping from the Mac", legend: true, series: [
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

    private func row<Content: View>(title: String, unit: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                if !layout.compact { Text(unit).font(.system(size: 11)).foregroundStyle(.secondary) }
            }.frame(width: labelWidth - 12, alignment: .leading).padding(.trailing, 12)
            content()
        }
    }

    /// Per-VM values live in the sidebar cards, so a track only needs its title.
    private func trackLabel(_ spec: Spec) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(spec.title).font(.system(size: 13, weight: .semibold))
            if !layout.compact { Text(spec.unit).font(.system(size: 11)).foregroundStyle(.secondary) }
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

    private func probeTrack(title: String, unit: String, legend: Bool, series: [ProbeSeries]) -> some View {
        let yMax = Self.niceMs(series.flatMap { $0.points.compactMap(\.rttMax) }.max() ?? 1)
        let tolerance = max(Readout.tolerance(history), 15_000)
        return HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                if !layout.compact { Text(unit).font(.system(size: 11)).foregroundStyle(.secondary).padding(.bottom, 3) }
                ForEach(Array((legend ? series : []).enumerated()), id: \.offset) { _, s in
                    let p = Readout.nearest(s.points, t: readoutT, tolerance: tolerance, time: { $0.t })
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 1.5).fill(s.color).frame(width: 10, height: 3)
                        Text(s.name).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 4)
                        Text(p.map { $0.rtt.map(Self.ms) ?? "no reply" } ?? "—").monospacedDigit().fixedSize()
                    }.font(.system(size: 12))
                }
            }
            .frame(width: labelWidth - 12, alignment: .leading).padding(.trailing, 12)

            Canvas { ctx, size in
                func y(_ v: Double) -> CGFloat { size.height - CGFloat(min(1.08, v / yMax)) * size.height * 0.92 }
                for v in [yMax, yMax / 2] {
                    var line = Path(); line.move(to: CGPoint(x: 0, y: y(v))); line.addLine(to: CGPoint(x: size.width, y: y(v)))
                    ctx.stroke(line, with: .color(Color.primary.opacity(0.10)), lineWidth: 1)
                }
                var base = Path(); base.move(to: CGPoint(x: 0, y: size.height - 0.5)); base.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
                ctx.stroke(base, with: .color(Color.primary.opacity(0.25)), lineWidth: 1)
                let gap = max(history.bucketMs * 3, 35_000)
                for s in series {
                    let bucketed = s.points.contains { $0.sent > 1 }
                    func path(_ f: (ProbePoint) -> Double?) -> Path {
                        var p = Path()
                        var last: Int64?
                        for pt in s.points {
                            guard let v = f(pt) else { last = nil; continue }
                            let pos = CGPoint(x: fraction(pt.t) * size.width, y: y(v))
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
                        let x = fraction(pt.t) * size.width
                        ctx.fill(Path(CGRect(x: x - 1, y: size.height - 8, width: 2, height: 8)), with: .color(.red))
                    }
                    if readout != nil, k == 1, let p = Readout.nearest(s.points, t: readoutT, tolerance: tolerance, time: { $0.t }), let v = p.rtt {
                        let c = CGPoint(x: fraction(p.t) * size.width, y: y(v))
                        ctx.fill(Path(ellipseIn: CGRect(x: c.x - 6, y: c.y - 6, width: 12, height: 12)), with: .color(Color(nsColor: .windowBackgroundColor)))
                        ctx.fill(Path(ellipseIn: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)), with: .color(s.color))
                    }
                }
                for v in [yMax, yMax / 2] {
                    ctx.draw(Text(Self.ms(v)).font(.system(size: 10)).foregroundStyle(.secondary), at: CGPoint(x: 4, y: y(v) + 8), anchor: .leading)
                }
            }
            .frame(height: plotHeight)
            .accessibilityLabel("\(title): ping time over the selected time frame; red ticks mark lost pings")
        }
    }

    // MARK: Drawing

    private func plot(_ spec: Spec) -> some View {
        Canvas { ctx, size in
            let grid = Color.primary.opacity(0.10)
            func y(_ v: Double) -> CGFloat { size.height - CGFloat(min(1.08, v / spec.yMax)) * size.height * 0.92 }
            for v in [spec.yMax, spec.yMax / 2] {
                var line = Path(); line.move(to: CGPoint(x: 0, y: y(v))); line.addLine(to: CGPoint(x: size.width, y: y(v)))
                ctx.stroke(line, with: .color(grid), lineWidth: 1)
            }
            var base = Path(); base.move(to: CGPoint(x: 0, y: size.height - 0.5)); base.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
            ctx.stroke(base, with: .color(Color.primary.opacity(0.25)), lineWidth: 1)

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
                        let pos = CGPoint(x: fraction(pt.t) * size.width, y: y(v))
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
                    let center = CGPoint(x: fraction(p.t) * size.width, y: y(v))
                    let ring = Path(ellipseIn: CGRect(x: center.x - 6, y: center.y - 6, width: 12, height: 12))
                    ctx.fill(ring, with: .color(Color(nsColor: .windowBackgroundColor)))
                    ctx.fill(Path(ellipseIn: CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8)), with: .color(color(vm.key)))
                }
            }

            for v in [spec.yMax, spec.yMax / 2] {
                ctx.draw(Text(spec.label(v)).font(.system(size: 10)).foregroundStyle(.secondary), at: CGPoint(x: 4, y: y(v) + 8), anchor: .leading)
            }
        }
        .accessibilityLabel("\(spec.title) trend for each VM over the selected time frame")
    }

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
    }

    private var pressureLane: some View {
        Canvas { ctx, size in
            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 4), with: .color(Color.primary.opacity(0.08)))
            let step = CGFloat(history.bucketMs / span) * size.width
            for p in history.host where p.pressure > 0 {
                let x = fraction(p.t) * size.width
                let rect = CGRect(x: x - step / 2, y: 0, width: max(1.5, step + 0.5), height: size.height)
                ctx.fill(Path(rect), with: .color(p.pressure == 2 ? .red : .orange))
            }
        }
        .accessibilityLabel("Host memory pressure over the selected time frame")
    }

    private var axis: some View {
        Canvas { ctx, size in
            let f = DateFormatter()
            f.dateFormat = span >= 86_400_000 ? "EEE d HH:mm" : (span <= 900_000 ? "HH:mm:ss" : "HH:mm")
            for i in 0...6 {
                let t = history.from + Int64(span * Double(i) / 6)
                let text = Text(f.string(from: Date(ms: t))).font(.system(size: 11)).foregroundStyle(.secondary)
                let anchor: UnitPoint = i == 0 ? .leading : (i == 6 ? .trailing : .center)
                ctx.draw(text, at: CGPoint(x: size.width * CGFloat(i) / 6, y: size.height / 2), anchor: anchor)
            }
        }
    }

    // MARK: Crosshair, pin and pointer handling

    private func scrubber(size: CGSize) -> some View {
        let plotWidth = max(1, size.width - labelWidth)
        let height = size.height - axisHeight
        func time(_ x: CGFloat) -> Int64 { history.from + Int64(Double(min(max(0, x), plotWidth) / plotWidth) * span) }
        return ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in
                func vertical(_ t: Int64, from top: CGFloat = 0) -> Path {
                    let x = labelWidth + fraction(t) * plotWidth
                    var p = Path(); p.move(to: CGPoint(x: x, y: top)); p.addLine(to: CGPoint(x: x, y: height)); return p
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
                    let label = ctx.resolve(Text(f.string(from: Date(ms: pin))).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color(nsColor: .windowBackgroundColor)))
                    let w = label.measure(in: CGSize(width: 200, height: 20)).width + 12
                    let left = min(max(labelWidth, x - w / 2), size.width - w)
                    ctx.fill(Path(roundedRect: CGRect(x: left, y: height + 1, width: w, height: 16), cornerRadius: 4), with: .color(.primary))
                    ctx.draw(label, at: CGPoint(x: left + w / 2, y: height + 9), anchor: .center)
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
                .gesture(SpatialTapGesture().onEnded { onPin(time($0.location.x)) })
                .offset(x: labelWidth)
                .accessibilityLabel("Time scrubber: hover to read a moment, click to pin it")
        }
    }
}
