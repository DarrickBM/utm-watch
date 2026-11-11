import AppKit
import SwiftUI
import UTMWatchCore
import UTMWatchStore

/// The detail window: time-frame controls, the indicator table, host tiles and the trend tracks.
struct DetailView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var detail: DetailModel
    var onSettings: () -> Void

    private var readout: Readout? {
        let order = model.ring.order
        if let t = detail.readoutTime {
            let kind = detail.pin != nil ? "Pinned moment" : (detail.hover != nil ? "Under cursor" : "End of range")
            return Readout.at(t, kind: kind, history: detail.history, order: order, units: settings.rateUnits)
        }
        return model.snapshot.map { Readout.now(snapshot: $0, link: model.link, probes: model.ring.probes, order: order, units: settings.rateUnits) }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            // VM cards on the left (they scroll on their own when there are many); host tiles and the
            // tracks on the right, where the tracks adapt to whatever height is left. Nothing else scrolls.
            HStack(alignment: .top, spacing: 14) {
                sidebar(readout)
                VStack(alignment: .leading, spacing: 12) {
                    if let readout { tiles(readout) }
                    GeometryReader { geo in
                        TracksView(history: detail.history, order: model.ring.order, units: settings.rateUnits,
                                   readout: detail.readoutTime?.msSince1970, pin: detail.pin?.msSince1970, hover: detail.hover?.msSince1970,
                                   onHover: { ms in
                                       let d = ms.map { Date(ms: $0) }
                                       if d != detail.hover { detail.hover = d }
                                   },
                                   onPin: { detail.pin = Date(ms: $0) },
                                   availableHeight: geo.size.height, focus: detail.focus)
                    }
                    .frame(minHeight: 380)
                }
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
            Divider()
            footer
        }
        .frame(minWidth: 1180, minHeight: 720)
    }

    // MARK: Time frame controls

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("Time frame", selection: Binding(get: { detail.lengthSeconds }, set: { detail.select(length: $0) })) {
                ForEach(DetailModel.lengths, id: \.seconds) { Text($0.label).tag($0.seconds) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()

            HStack(spacing: 4) {
                Button { detail.stepBack() } label: { Image(systemName: "chevron.left") }.help("Earlier")
                Text(rangeLabel).font(.system(size: 13, weight: .semibold)).monospacedDigit().frame(minWidth: 210)
                Button { detail.stepForward() } label: { Image(systemName: "chevron.right") }.help("Later").disabled(detail.isLive)
            }

            HStack(spacing: 6) {
                Text("Jump to").foregroundStyle(.secondary).fixedSize()
                DatePicker("Jump to", selection: Binding(get: { detail.pin ?? detail.frameEnd }, set: { detail.jump(to: $0) }),
                           in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden().datePickerStyle(.compact)
            }

            Spacer(minLength: 8)

            if detail.isLive {
                HStack(spacing: 6) {
                    Circle().fill(Color.green).frame(width: 8, height: 8)
                    Text("Live").fontWeight(.semibold)
                }
            } else {
                Button("Back to live") { detail.goLive() }.buttonStyle(.borderedProminent)
            }
            Button { onSettings() } label: { Label("Settings", systemImage: "slider.horizontal.3") }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var rangeLabel: String {
        let from = detail.frameStart, to = detail.frameEnd
        let day = DateFormatter(); day.dateFormat = "EEE d MMM"
        let time = DateFormatter(); time.dateFormat = "HH:mm"
        if Calendar.current.isDate(from, inSameDayAs: to) {
            return "\(day.string(from: from)), \(time.string(from: from)) – \(time.string(from: to))"
        }
        let short = DateFormatter(); short.dateFormat = "EEE d HH:mm"
        return "\(short.string(from: from)) – \(short.string(from: to))"
    }

    // MARK: Readout

    // MARK: Sidebar

    private func sidebar(_ r: Readout?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let r {
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.kind.uppercased()).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    Text(Self.stamp.string(from: r.time)).font(.system(size: 17, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
                }
                // Reserved even when nothing is pinned, so pinning does not push the cards down.
                HStack(spacing: 6) {
                    Button("Unpin") { detail.pin = nil; promptCopied = false }
                    Button(promptCopied ? "Prompt copied" : "Ask AI about this moment") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Self.prompt(for: r.time), forType: .string)
                        promptCopied = true
                    }
                    .help("Copies a question you can paste to an AI agent connected to UTM Watch")
                }
                .controlSize(.small)
                .opacity(detail.pin == nil ? 0 : 1).disabled(detail.pin == nil)

                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(r.rows) { row in card(row) }
                        if r.rows.isEmpty { Text("No VM recorded at this moment").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
                    }
                    .padding(.trailing, 2)
                }
                Text(detail.focus == nil ? "Click a VM to focus its lines in the tracks." : "Showing one VM in the tracks. Click its card again to show all.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Collecting first sample…").foregroundStyle(.secondary)
                Spacer()
            }
        }
        .frame(width: 262, alignment: .leading)
    }

    private func card(_ row: Readout.Row) -> some View {
        let selected = detail.focus == row.id
        let dimmed = detail.focus != nil && !selected
        return Button {
            detail.focus = selected ? nil : row.id
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 3).fill(SeriesPalette.color(index: row.colorIndex, scheme: scheme)).frame(width: 10, height: 10)
                    Text(row.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(row.state).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                cardLine("CPU", row.cpu, warning: row.cpuWarning)
                cardLine("Memory", row.mem)
                cardLine("↓ Down", row.down)
                cardLine("↑ Up", row.up)
                cardLine("Ping", row.ping)
                cardLine("Total ↓ / ↑", row.total)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(selected ? 0.07 : 0.0)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Color.primary.opacity(0.75) : Color.primary.opacity(0.12), lineWidth: selected ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .opacity(dimmed ? 0.55 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(row.name), \(row.state). \(selected ? "Focused. Click to show all VMs." : "Click to focus this VM in the tracks.")")
    }

    private func cardLine(_ label: String, _ value: String, warning: String? = nil) -> some View {
        HStack(spacing: 5) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 6)
            if warning != nil {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityLabel("Warning")
            }
            Text(value).monospacedDigit().lineLimit(1)
        }
        .font(.system(size: 12))
        .help(warning ?? "")
    }

    @State private var promptCopied = false

    static func prompt(for date: Date) -> String {
        let f = ISO8601DateFormatter(); f.timeZone = .current; f.formatOptions = [.withInternetDateTime]
        return "Use the utm-watch tools to investigate what was happening on this Mac around \(f.string(from: date)). "
            + "Start with get_moment for that time and find_incidents for the hour around it, then explain the most likely cause and what I should change."
    }

    private static let stamp: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE d MMM, HH:mm:ss"; return f }()

    @Environment(\.colorScheme) private var scheme

    /// Always the same five tiles at the same size, so the layout does not move while scrubbing
    /// across moments that have no data.
    private func tiles(_ r: Readout) -> some View {
        HStack(spacing: 10) {
            if let h = r.host {
                tile("Allocatable memory", Format.memory(h.allocatable), "actually free: \(Format.memory(h.freeNow))", Explain.allocatable(h))
                tile("Cores allocated", "\(h.allocatedCores) / \(h.physicalCores)",
                     h.overcommitted ? "overcommitted" : "\(h.physicalCores - h.allocatedCores) not allocated", Explain.cores(h))
                tile("Host memory pressure", h.pressure.rawValue.capitalized, h.pressure == .normal ? "no alert" : "macOS is short of memory",
                     Explain.pressure(h), okMark: h.pressure == .normal)
                tile("Swap used", h.swapTotal > 0 ? "\(Format.memory(h.swapUsed)) / \(Format.memory(h.swapTotal))" : "off",
                     h.swapTotal > 0 ? "\(Int((Double(h.swapUsed) / Double(h.swapTotal) * 100).rounded()))% of swap in use" : "no swap file",
                     Explain.swap(h))
            } else {
                tile("Allocatable memory", "—", "nothing recorded then", nil)
                tile("Cores allocated", "—", "nothing recorded then", nil)
                tile("Host memory pressure", "—", "nothing recorded then", nil)
                tile("Swap used", "—", "nothing recorded then", nil)
            }
            if let l = r.link { linkTile(l) } else { tile("Network link", "—", "nothing recorded then", nil) }
        }
    }

    private func linkTile(_ l: LinkInfo) -> some View {
        let warning = Explain.link(l)
        switch l.kind {
        case "wifi":
            let detail = [l.txRateMbps.map { "\(Int($0.rounded())) Mbps" }, l.channel.map { "channel \($0)" }].compactMap { $0 }.joined(separator: ", ")
            return tile("Network link", l.rssi.map { "Wi-Fi, \($0) dBm" } ?? "Wi-Fi", warning != nil ? "weak signal" : (detail.isEmpty ? "connected" : detail), warning)
        case "ethernet":
            return tile("Network link", "Ethernet", l.speedMbps.map { "\(Int($0.rounded())) Mbps" } ?? "connected", warning)
        case "none":
            return tile("Network link", "Offline", "no default route", warning)
        default:
            return tile("Network link", l.interface ?? "Other", "connected", warning)
        }
    }

    private func tile(_ label: String, _ value: String, _ sub: String, _ warning: String?, okMark: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                if warning != nil {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityLabel("Warning")
                } else if okMark {
                    Image(systemName: "checkmark").foregroundStyle(.green)
                }
                Text(value).font(.system(size: 20, weight: .semibold)).monospacedDigit().minimumScaleFactor(0.6)
            }
            Text(sub).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).strokeBorder(warning == nil ? Color.primary.opacity(0.12) : Color.orange.opacity(0.6)))
        .help(warning ?? "")
    }

    private var footer: some View {
        HStack {
            Text(storageText)
            Spacer()
            if detail.history.bucketMs > 5000 {
                Text("Each point averages \(Self.duration(detail.history.bucketMs)); the faint line is the peak")
            }
        }
        .font(.system(size: 12)).foregroundStyle(.secondary)
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private var storageText: String {
        guard model.store != nil else { return "History recording is unavailable" }
        guard let s = detail.stats, let oldest = s.oldest else { return "Recording started; no history yet" }
        let f = DateFormatter(); f.dateFormat = "EEE d MMM, HH:mm"
        return "Recording since \(f.string(from: Date(ms: oldest))) · \(Format.bytes(UInt64(s.bytes))) on disk · kept for \(settings.retentionDays) day\(settings.retentionDays == 1 ? "" : "s")"
    }

    private static func duration(_ ms: Double) -> String {
        let s = ms / 1000
        return s >= 90 ? "\(Int((s / 60).rounded())) min" : "\(Int(s.rounded())) s"
    }
}
