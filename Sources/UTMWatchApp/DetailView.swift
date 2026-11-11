import AppKit
import SwiftUI
import UTMWatchCore
import UTMWatchStore

/// The detail window: time-frame controls, the moment being read, host status, VM chips and the trend tracks.
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
            // The moment being read heads everything below it: the host figures, the VM chips and the
            // tracks, where every reading sits beside its own line. Only the tracks flex with the window.
            VStack(alignment: .leading, spacing: 0) {
                header(readout).padding(.bottom, 12)
                Divider()
                statusRow(readout).padding(.vertical, 10)
                Divider()
                chipsRow(readout).padding(.top, 10).padding(.bottom, 10)
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
            .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 10)
            // White content between the grey toolbar and footer, as in the design.
            .background(Color(nsColor: .textBackgroundColor))
            Divider()
            footer
        }
        .frame(minWidth: 1180, minHeight: 720)
        .onChange(of: detail.pin) { _, _ in promptCopied = false }
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

            if detail.isLive && detail.pin == nil {
                HStack(spacing: 6) {
                    Circle().fill(Color.green).frame(width: 8, height: 8)
                    Text("Live").fontWeight(.semibold)
                }
            } else {
                // The header below names the moment being shown; here the button is enough at the minimum width.
                Button("Back to live") { detail.goLive() }.buttonStyle(.borderedProminent)
            }
            Button { onSettings() } label: { Image(systemName: "slider.horizontal.3") }
                .help("Settings").accessibilityLabel("Settings")
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

    // MARK: Readout header

    private func header(_ r: Readout?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let r {
                Text(Self.stamp.string(from: r.time)).font(.system(size: 20, weight: .semibold)).monospacedDigit().lineLimit(1)
                Text(r.kind.lowercased()).foregroundStyle(.secondary)
            } else {
                Text("Collecting first sample…").font(.system(size: 20, weight: .semibold)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            // Reserved even when nothing is pinned, so pinning does not move the layout.
            HStack(spacing: 6) {
                Button(promptCopied ? "Prompt copied" : "Ask AI about this moment") {
                    guard let pin = detail.pin else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Self.prompt(for: pin), forType: .string)
                    promptCopied = true
                }
                .help("Copies a question you can paste to an AI agent connected to UTM Watch")
                Button("Unpin") { detail.pin = nil }.help("Esc")
            }
            .opacity(detail.pin == nil ? 0 : 1).disabled(detail.pin == nil)
        }
    }

    // MARK: Host status

    /// Always the same five figures in the same places, so nothing moves while scrubbing across
    /// moments that have no data.
    private func statusRow(_ r: Readout?) -> some View {
        HStack(alignment: .top, spacing: 24) {
            if let h = r?.host {
                stat("Memory pressure", h.pressure.rawValue.capitalized, h.pressure == .normal ? "" : "short of memory",
                     Explain.pressure(h), okMark: h.pressure == .normal)
                stat("Swap used", h.swapTotal > 0 ? "\(Format.memory(h.swapUsed)) / \(Format.memory(h.swapTotal))" : "off",
                     h.swapTotal > 0 ? "\(Int((Double(h.swapUsed) / Double(h.swapTotal) * 100).rounded()))%" : "no swap file", Explain.swap(h))
                stat("Allocatable memory", Format.memory(h.allocatable), "free now \(Format.memory(h.freeNow))", Explain.allocatable(h))
                stat("Cores allocated", "\(h.allocatedCores) / \(h.physicalCores)", h.overcommitted ? "overcommitted" : "to running VMs", Explain.cores(h))
            } else {
                stat("Memory pressure", "—", "nothing recorded", nil)
                stat("Swap used", "—", "", nil)
                stat("Allocatable memory", "—", "", nil)
                stat("Cores allocated", "—", "", nil)
            }
            if let l = r?.link { linkStat(l) } else { stat("Network link", "—", "", nil) }
        }
    }

    private func linkStat(_ l: LinkInfo) -> some View {
        let warning = Explain.link(l)
        switch l.kind {
        case "wifi":
            let rate = l.txRateMbps.map { "\(Int($0.rounded())) Mbps" }
            return stat("Network link", l.rssi.map { "Wi-Fi, \($0) dBm" } ?? "Wi-Fi", warning != nil ? "weak signal" : (rate ?? "connected"), warning)
        case "ethernet":
            return stat("Network link", "Ethernet", l.speedMbps.map { "\(Int($0.rounded())) Mbps" } ?? "connected", warning)
        case "none":
            return stat("Network link", "Offline", "no default route", warning)
        default:
            return stat("Network link", l.interface ?? "Other", "connected", warning)
        }
    }

    private func stat(_ label: String, _ value: String, _ sub: String, _ warning: String?, okMark: Bool = false) -> some View {
        let meaning = Self.meanings[label] ?? ""
        return VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if warning != nil {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityLabel("Warning")
                } else if okMark {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(.green)
                }
                Text(value).font(.system(size: 15, weight: .semibold)).monospacedDigit().layoutPriority(1)
                Text(sub).font(.system(size: 12)).foregroundStyle(.secondary).minimumScaleFactor(0.85)
            }
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .help(warning.map { meaning.isEmpty ? $0 : "\($0)\n\n\(meaning)" } ?? meaning)
    }

    /// What each host figure means, shown when hovering it.
    private static let meanings: [String: String] = [
        "Memory pressure": "macOS's own verdict on whether this Mac has enough memory. Normal: enough is free. Warning: it is compressing memory and swapping to disk to keep up, so things may feel slow. Critical: it is nearly out and stalls are likely.",
        "Swap used": "How much of this Mac's swap space on disk is in use. Memory that does not fit in RAM is moved there, and reading it back is much slower than RAM.",
        "Allocatable memory": "How much memory you could still give to another VM: this Mac's RAM, minus what macOS and your apps use, minus the memory limits of the VMs already running. \"Free now\" is what is unused at this moment.",
        "Cores allocated": "The CPU cores given to the running VMs, added up, against the cores this Mac has. Above the Mac's count, VMs compete for processor time when they are all busy.",
        "Network link": "How this Mac is connected to your network. For Wi-Fi, the signal strength in dBm (closer to 0 is stronger; below about -75 is weak) and the link speed.",
    ]

    // MARK: VM chips and the key to the shaded periods

    private func chipsRow(_ r: Readout?) -> some View {
        HStack(spacing: 14) {
            if let r, !r.rows.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) { ForEach(r.rows) { row in chip(row) } }.padding(1)
                }
            } else {
                Text(r == nil ? "" : "No VM recorded at this moment").foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            HStack(spacing: 12) {
                Text("Shaded")
                swatch(TracksView.linkTint(scheme).opacity(0.38), "Weak Wi-Fi")
                    .help("Times when the Wi-Fi signal was weak or the Mac had no network. Not shaded when it lasted the whole time frame.")
                swatch(Color.primary.opacity(0.14), "No data")
                    .help("Times when nothing was recorded: the Mac was asleep, or UTM Watch was not running.")
            }
            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize()
            .help("These periods are shaded through every track, so you can see what else changed while they lasted.")
        }
        .frame(height: 28)
    }

    private func swatch(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 12, height: 12)
                .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.primary.opacity(0.15)))
            Text(label)
        }
    }

    /// One chip per VM: its color, name and state. Clicking it keeps that VM's lines bright and fades the others.
    /// A pencil appears under the pointer; clicking it turns the name into a field.
    private func chip(_ row: Readout.Row) -> some View {
        let selected = detail.focus == row.id
        let dimmed = detail.focus != nil && !selected
        let editing = renaming == row.id
        return HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 3).fill(SeriesPalette.color(index: row.colorIndex, scheme: scheme)).frame(width: 10, height: 10)
            if editing {
                TextField("Name", text: $renameDraft)
                    .textFieldStyle(.plain).font(.system(size: 13, weight: .semibold))
                    .frame(width: 160)
                    .focused($renameFocused)
                    .onAppear { renameFocused = true }
                    .onChange(of: renameDraft) { _, text in
                        // Stop at the limit while typing or pasting, so what is seen is what is saved.
                        if text.count > VMName.maxLength { renameDraft = String(text.prefix(VMName.maxLength)) }
                    }
                    .onSubmit { commitRename() }
                    .onExitCommand { renaming = nil }
                    .onChange(of: renameFocused) { _, focused in if !focused, renaming == row.id { commitRename() } }
                    .accessibilityLabel("Name for \(row.name)")
            } else {
                Button {
                    detail.focus = selected ? nil : row.id
                } label: {
                    HStack(spacing: 7) {
                        Text(row.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text(row.state).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(height: 26).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(selected ? "Click to show all VMs again. Total ↓ / ↑ since it started: \(row.total)"
                               : "Click to show only this VM in the tracks. Total ↓ / ↑ since it started: \(row.total)")
                .accessibilityLabel("\(row.name), \(row.state). \(selected ? "Focused. Click to show all VMs." : "Click to focus this VM in the tracks.")")
                if hoveredChip == row.id {
                    Button {
                        renameDraft = row.name
                        renaming = row.id
                        renameFocused = true
                    } label: {
                        Image(systemName: "pencil").font(.system(size: 11, weight: .semibold))
                            .frame(width: 20, height: 20)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Rename this VM in UTM Watch, up to \(VMName.maxLength) characters. Save an empty name to go back to the UTM name. UTM itself is not changed.")
                    .accessibilityLabel("Rename \(row.name)")
                }
            }
        }
        .padding(.leading, 10).padding(.trailing, editing || hoveredChip == row.id ? 4 : 10).frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(selected ? 0.07 : 0.0)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(editing ? Color.accentColor : (selected ? Color.primary.opacity(0.75) : Color.primary.opacity(0.16)), lineWidth: selected || editing ? 1.5 : 1))
        .opacity(dimmed && !editing ? 0.6 : 1)
        .onHover { inside in
            if inside { hoveredChip = row.id } else if hoveredChip == row.id { hoveredChip = nil }
        }
    }

    private func commitRename() {
        guard let key = renaming else { return }
        renaming = nil
        model.rename(vm: key, to: renameDraft)
        detail.refresh(force: true)
    }

    @State private var hoveredChip: String?
    @State private var renaming: String?
    @State private var renameDraft = ""
    @FocusState private var renameFocused: Bool

    @State private var promptCopied = false

    static func prompt(for date: Date) -> String {
        let f = ISO8601DateFormatter(); f.timeZone = .current; f.formatOptions = [.withInternetDateTime]
        return "Use the utm-watch tools to investigate what was happening on this Mac around \(f.string(from: date)). "
            + "Start with get_moment for that time and find_incidents for the hour around it, then explain the most likely cause and what I should change."
    }

    private static let stamp: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE d MMM, HH:mm:ss"; return f }()

    @Environment(\.colorScheme) private var scheme

    private var footer: some View {
        HStack {
            Text(storageText)
            if detail.history.bucketMs > 5000 {
                Text("· each point averages \(Self.duration(detail.history.bucketMs)), the faint line is the peak")
            }
            Spacer()
            Text("Click a track to pin a moment. ← → step one sample, Shift for ten, Esc unpins.")
        }
        .font(.system(size: 12)).foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 20).padding(.vertical, 8)
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
