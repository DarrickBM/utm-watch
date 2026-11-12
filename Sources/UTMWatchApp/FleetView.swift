import AppKit
import SwiftUI
import UTMWatchCore
import UTMWatchFleet
import UTMWatchStore

/// The fleet window: every Mac with its VMs, or one Mac in the same detail view this Mac has for itself.
struct FleetWindowView: View {
    @ObservedObject var fleet: FleetController
    @ObservedObject var settings: AppSettings
    var onSettings: () -> Void

    var body: some View {
        if let uuid = fleet.selected, let host = fleet.hosts.first(where: { $0.uuid == uuid }) {
            DetailView(model: fleet.mirror, settings: settings, detail: fleet.remoteDetail, onSettings: onSettings,
                       remote: .init(name: host.name, state: host.state, onBack: { fleet.select(nil) }))
        } else {
            FleetOverview(fleet: fleet, settings: settings, onSettings: onSettings)
        }
    }
}

/// One table: a grey row per Mac with its VMs listed beneath. A Mac that is not reporting collapses to one line.
struct FleetOverview: View {
    @ObservedObject var fleet: FleetController
    @ObservedObject var settings: AppSettings
    var onSettings: () -> Void
    @State private var attentionOnly = false

    private enum Col {
        static let state: CGFloat = 150, cpu: CGFloat = 190, memory: CGFloat = 250, network: CGFloat = 210, tail: CGFloat = 90
    }

    private var newestVersion: String? {
        fleet.hosts.compactMap(\.appVersion).filter { !AppVersion.parts($0).isEmpty }.max { AppVersion.isNewer($1, than: $0) }
    }

    private func rows(_ host: HostStatus) -> [VMRow] {
        (host.snapshot?.rows ?? []).filter { settings.showOtherVMs || !OtherVMs.isOther(key: $0.id) }
    }

    private func needsAttention(_ host: HostStatus) -> Bool {
        if host.state != "online" { return true }
        if let skew = host.skewMs, abs(skew) > 5000 { return true }
        guard let snap = host.snapshot else { return false }
        return Explain.pressure(snap.host) != nil || Explain.swap(snap.host) != nil || rows(host).contains { Explain.cpu($0) != nil }
    }

    private var shown: [HostStatus] { attentionOnly ? fleet.hosts.filter(needsAttention) : fleet.hosts }

    private struct Line {
        enum Kind { case mac(HostStatus), vm(VMRow), collapsed(HostStatus) }
        var id: String
        var kind: Kind
    }

    private var lines: [Line] {
        var out: [Line] = []
        for host in shown {
            out.append(Line(id: host.uuid, kind: .mac(host)))
            if host.state == "online" {
                for row in rows(host) { out.append(Line(id: host.uuid + "|" + row.id, kind: .vm(row))) }
            } else {
                out.append(Line(id: host.uuid + "|collapsed", kind: .collapsed(host)))
            }
        }
        return out
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            Group {
                if !fleet.canView {
                    emptyState
                } else if !fleet.loadedOnce {
                    VStack(spacing: 10) {
                        if fleet.hostsError == nil { ProgressView() }
                        Text(fleet.hostsError ?? "Asking the hub…").foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if shown.isEmpty {
                    Text(attentionOnly ? "Nothing needs attention." : "No Macs have joined yet. Create a pairing code in Settings to add one.")
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            columnHeads
                            // One flat list: two Macs can have VMs with the same key, so a row's identity includes its Mac.
                            ForEach(lines, id: \.id) { line in
                                switch line.kind {
                                case .mac(let host): macRow(host)
                                case .vm(let row): vmRow(row)
                                case .collapsed(let host): collapsed(host)
                                }
                            }
                        }
                        .padding(.bottom, 12)
                    }
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
            Divider()
            footer
        }
        .frame(minWidth: 1180, minHeight: 720)
    }

    // MARK: Chrome

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text("Fleet").font(.system(size: 15, weight: .semibold))
            if fleet.canView {
                Picker("Show", selection: $attentionOnly) {
                    Text("All").tag(false); Text("Needs attention").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            Spacer(minLength: 8)
            if let error = fleet.hostsError, fleet.loadedOnce {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).lineLimit(1)
            }
            Button { onSettings() } label: { Image(systemName: "slider.horizontal.3") }
                .help("Settings").accessibilityLabel("Settings")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "macmini").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("This Mac is not in a fleet yet").font(.system(size: 20, weight: .semibold))
            Text("A fleet shows the VMs of several Macs in one window. One Mac hosts the hub; the others join it with a pairing code.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460)
            HStack(spacing: 10) {
                Button("Enter pairing code…") { onSettings() }
                Button("Host the hub on this Mac…") { onSettings() }
            }
            .padding(.top, 4)
            Text("Both are in Settings, under Fleet.").font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        let online = fleet.hosts.filter { $0.state == "online" }
        let running = online.reduce(0) { $0 + rows($1).filter { $0.pid != nil }.count }
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        return HStack {
            if fleet.canView, fleet.loadedOnce {
                Text("\(fleet.hosts.count) Mac\(fleet.hosts.count == 1 ? "" : "s") · \(online.count) online · \(running) VM\(running == 1 ? "" : "s") running")
                if let at = fleet.updatedAt { Text("· as of \(f.string(from: at))").monospacedDigit() }
            }
            Spacer()
            Text("Click a Mac to see its history.")
        }
        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
        .padding(.horizontal, 20).padding(.vertical, 8)
    }

    private var columnHeads: some View {
        HStack(spacing: 0) {
            Text("Mac / VM").frame(maxWidth: .infinity, alignment: .leading)
            Text("State").frame(width: Col.state, alignment: .leading)
            Text("CPU").frame(width: Col.cpu, alignment: .leading)
            Text("Memory").frame(width: Col.memory, alignment: .leading)
            Text("Network").frame(width: Col.network, alignment: .leading)
            Text("").frame(width: Col.tail)
        }
        .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
        .padding(.horizontal, 20).padding(.vertical, 7)
    }

    // MARK: Rows

    private func macRow(_ host: HostStatus) -> some View {
        let snap = host.snapshot
        let online = host.state == "online"
        return Button { fleet.select(host.uuid) } label: {
            HStack(spacing: 0) {
                HStack(spacing: 7) {
                    Image(systemName: "macmini").foregroundStyle(.secondary)
                    Text(host.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    ForEach(pills(host), id: \.text) { pill in
                        Text(pill.text).font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill((pill.warn ? Color.orange : Color.primary).opacity(pill.warn ? 0.18 : 0.08)))
                            .foregroundStyle(pill.warn ? Color.orange : Color.secondary).fixedSize()
                    }
                }
                .padding(.trailing, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    Circle().fill(online ? Color.green : Color.secondary.opacity(0.6)).frame(width: 8, height: 8)
                    Text(stateText(host)).lineLimit(1)
                }
                .frame(width: Col.state, alignment: .leading)
                Group {
                    if online, let s = snap {
                        Text(s.host.hostCPUCores.map { "\(String(format: "%.1f", $0)) of \(s.host.physicalCores) cores busy" } ?? "\(s.host.physicalCores) cores")
                            .frame(width: Col.cpu, alignment: .leading)
                        HStack(spacing: 5) {
                            Text("\(Format.memory(s.host.allocatable)) free for VMs")
                            if let why = Explain.pressure(s.host) ?? Explain.swap(s.host) {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(why)
                            }
                        }
                        .frame(width: Col.memory, alignment: .leading)
                        Text(linkText(host.link)).foregroundStyle(Explain.link(host.link) == nil ? Color.primary : Color.orange)
                            .frame(width: Col.network, alignment: .leading)
                    } else {
                        Text("").frame(width: Col.cpu + Col.memory + Col.network)
                    }
                }
                .monospacedDigit().lineLimit(1)
                HStack(spacing: 6) {
                    Text(host.appVersion ?? "").foregroundStyle(.secondary).lineLimit(1)
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                }
                .frame(width: Col.tail, alignment: .trailing)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 20).frame(height: 34)
            .background(Color.primary.opacity(0.05))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 6)
        .help("Show \(host.name)'s history")
        .accessibilityLabel("\(host.name), \(stateText(host))")
    }

    private func vmRow(_ row: VMRow) -> some View {
        let running = row.pid != nil
        let limit = row.memoryAllocatedBytes.map(Double.init)
        func fraction(_ used: Double?, _ of: Double?) -> Double? {
            guard let used, let of, of > 0 else { return nil }
            return min(1, max(0, used / of))
        }
        return HStack(spacing: 0) {
            Text(row.name).lineLimit(1).padding(.leading, 26).frame(maxWidth: .infinity, alignment: .leading)
            Text(running ? "Running" : row.status == .unknown ? "Not running" : row.status.rawValue.capitalized)
                .foregroundStyle(running ? Color.primary : Color.secondary).frame(width: Col.state, alignment: .leading)
            if running {
                FleetMeter(text: Format.cores(row.cpuCores, row.cpuAllocated), fraction: fraction(row.cpuCores, row.cpuAllocated.map(Double.init)),
                           warning: Explain.cpu(row))
                    .frame(width: Col.cpu - 20, alignment: .leading).padding(.trailing, 20)
                FleetMeter(text: memoryText(row), fraction: fraction((row.residentBytes ?? row.memoryBytes).map(Double.init), limit),
                           back: row.residentBytes == nil ? nil : fraction(row.memoryBytes.map(Double.init), limit), warning: nil)
                    .frame(width: Col.memory - 20, alignment: .leading).padding(.trailing, 20)
                Text("↓ \(Format.rate(row.downRate, units: settings.rateUnits))   ↑ \(Format.rate(row.upRate, units: settings.rateUnits))")
                    .monospacedDigit().lineLimit(1).frame(width: Col.network, alignment: .leading)
            } else {
                Text("").frame(width: Col.cpu + Col.memory + Col.network)
            }
            Text("").frame(width: Col.tail)
        }
        .font(.system(size: 13))
        .opacity(running ? 1 : 0.6)
        .padding(.horizontal, 20).frame(height: 30)
        .overlay(alignment: .bottom) { Divider().padding(.leading, 46) }
    }

    /// A Mac that is not reporting: what it had, in one line, rather than rows of stale numbers.
    private func collapsed(_ host: HostStatus) -> some View {
        let all = rows(host), running = all.filter { $0.pid != nil }.count
        let text: String
        if host.snapshot == nil { text = "This Mac has joined but has not reported yet." }
        else if all.isEmpty { text = "No VMs." }
        else {
            let verb = host.state == "asleep" ? "went to sleep" : "stopped reporting"
            text = "\(all.count) VM\(all.count == 1 ? "" : "s") · \(running) \(running == 1 ? "was" : "were") running when this Mac \(verb)"
        }
        return Text(text).font(.system(size: 13)).foregroundStyle(.secondary)
            .padding(.leading, 46).padding(.trailing, 20).frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
    }

    // MARK: Wording

    private func pills(_ host: HostStatus) -> [(text: String, warn: Bool)] {
        var out: [(String, Bool)] = []
        if host.uuid == fleet.identity?.hostUUID {
            out.append(("This Mac", false))
            if settings.hostHub { out.append(("Hub", false)) }
        }
        if let skew = host.skewMs, abs(skew) > 5000 {
            // Skew is the hub's clock minus the Mac's: positive means the Mac's clock is behind.
            out.append(("Clock \(FleetOverview.span(abs(skew))) \(skew > 0 ? "behind" : "ahead")", true))
        }
        if let v = host.appVersion, let newest = newestVersion, AppVersion.isNewer(newest, than: v) { out.append(("Older version", false)) }
        return out
    }

    private func stateText(_ host: HostStatus) -> String {
        guard let seen = host.lastSeen else { return "Not reported yet" }
        switch host.state {
        case "online": return "Online"
        case "asleep": return "Asleep · \(FleetOverview.span(Date().msSince1970 - seen))"
        default: return "Offline · \(FleetOverview.span(Date().msSince1970 - seen))"
        }
    }

    private func linkText(_ link: LinkInfo?) -> String {
        guard let l = link else { return "—" }
        switch l.kind {
        case "wifi": return "Wi-Fi" + (l.rssi.map { " · \($0) dBm" } ?? "")
        case "ethernet": return "Ethernet" + (l.speedMbps.map { $0 >= 1000 ? " · \(Format.trimmed($0 / 1000)) Gbps" : " · \(Int($0)) Mbps" } ?? "")
        case "none": return "No network"
        default: return "Connected"
        }
    }

    private func memoryText(_ row: VMRow) -> String {
        let pair = Format.memoryPair(row.memoryBytes, row.memoryAllocatedBytes)
        guard let res = row.residentBytes else { return pair }
        return "\(Format.memory(res)) in RAM · \(pair)"
    }

    /// "40 s", "12 min", "3 h", "2 d".
    static func span(_ ms: Int64) -> String {
        let s = max(0, ms / 1000)
        if s < 90 { return "\(s) s" }
        if s < 90 * 60 { return "\(s / 60) min" }
        if s < 48 * 3600 { return "\(s / 3600) h" }
        return "\(s / 86400) d"
    }
}

/// A value with a thin bar under it. `back` is a paler, larger amount the main one is part of (memory held vs in RAM).
private struct FleetMeter: View {
    let text: String
    let fraction: Double?
    var back: Double? = nil
    let warning: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(text).monospacedDigit().lineLimit(1)
                if warning != nil { Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(.orange) }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.10))
                    if let back { Capsule().fill(Color.accentColor.opacity(0.3)).frame(width: geo.size.width * back) }
                    Capsule().fill(warning == nil ? Color.accentColor : Color.orange).frame(width: geo.size.width * (fraction ?? 0))
                }
            }
            .frame(height: 4)
        }
        .help(warning ?? "")
    }
}

/// Settings › Fleet: join a fleet, see how reporting is going, or host the hub and add Macs to it.
struct FleetSettingsSection: View {
    @ObservedObject var fleet: FleetController
    @ObservedObject var settings: AppSettings
    var onOpenFleet: () -> Void

    @State private var name = FleetController.defaultName
    @State private var code = ""
    @State private var authKey = ""
    @State private var confirmLeave = false
    @State private var revoking: HostStatus?
    @State private var copied = ""

    private var reporting: Bool { fleet.identity.map { !$0.hostToken.isEmpty } ?? false }

    var body: some View {
        Section {
            if settings.hostHub {
                hosting
            } else if reporting {
                member
            } else {
                notInFleet
            }
        } header: { Text("Fleet") } footer: {
            if !settings.hostHub && !reporting {
                Text("A fleet shows the VMs of several Macs in one window. Without one, UTM Watch works on this Mac alone, as before.")
            }
        }
    }

    // MARK: Not in a fleet

    @ViewBuilder private var notInFleet: some View {
        TextField("This Mac's name", text: $name, prompt: Text(FleetController.defaultName))
        LabeledContent {
            HStack {
                TextField("Pairing code", text: $code, prompt: Text("utmw1.…")).labelsHidden().textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced)).frame(width: 220)
                if fleet.joining { ProgressView().controlSize(.small) }
                Button("Join") { fleet.join(code: code, name: name) }.disabled(code.trimmingCharacters(in: .whitespaces).isEmpty || fleet.joining)
            }
        } label: {
            Text("Join a fleet")
            Text(fleet.joinError ?? fleet.joinProgress ?? "Paste the pairing code from the Mac that hosts the hub").foregroundStyle(fleet.joinError == nil ? Color.secondary : Color.orange)
        }
        hostToggle
    }

    private var hostToggle: some View {
        Toggle(isOn: Binding(get: { settings.hostHub }, set: { fleet.setHosting($0) })) {
            Text("Host the hub on this Mac")
            Text(fleet.hubError ?? "The other Macs report to this one. It has to stay on and logged in.")
                .foregroundStyle(fleet.hubError == nil ? Color.secondary : Color.orange)
        }
    }

    // MARK: Reporting to a hub

    @ViewBuilder private var member: some View {
        LabeledContent {
            Button("Open Fleet") { onOpenFleet() }
        } label: {
            Text("Status")
            Text(statusText.text).foregroundStyle(statusText.warn ? Color.orange : Color.secondary)
        }
        LabeledContent("Hub") {
            Text(fleet.identity?.hubURL ?? "").font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
        }
        LabeledContent("This Mac's name") { Text(fleet.identity?.name ?? "") }
        Toggle(isOn: Binding(get: { !settings.fleetReportingPaused }, set: { settings.fleetReportingPaused = !$0 })) {
            Text("Report this Mac's VMs")
            Text("Off keeps this Mac in the fleet but stops sending. It keeps recording and catches up when switched back on.")
        }
        alertsToggle
        LabeledContent {
            HStack {
                TextField("Pairing code", text: $code, prompt: Text("utmw1.…")).labelsHidden().textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced)).frame(width: 180)
                if fleet.joining { ProgressView().controlSize(.small) }
                Button("Join") { fleet.join(code: code, name: fleet.identity?.name ?? name) }.disabled(code.trimmingCharacters(in: .whitespaces).isEmpty || fleet.joining)
            }
        } label: {
            Text("Enter a new code")
            Text(fleet.joinError ?? fleet.joinProgress ?? "To rejoin, or to move this Mac to another fleet").foregroundStyle(fleet.joinError == nil ? Color.secondary : Color.orange)
        }
        LabeledContent {
            Button("Leave fleet…", role: .destructive) { confirmLeave = true }
        } label: { Text("Leave") ; Text("Stops reporting. History already on the hub stays until it ages out.") }
        .confirmationDialog("Leave this fleet?", isPresented: $confirmLeave) {
            Button("Leave fleet", role: .destructive) { fleet.leave() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This Mac stops reporting and no longer sees the other Macs. Joining again needs a new pairing code.") }
    }

    private var alertsToggle: some View {
        Toggle(isOn: $settings.fleetAlerts) {
            Text("Notify me about other Macs")
            Text("When another Mac runs short of memory, a VM is held at its CPU limit, or a Mac stops reporting")
        }
    }

    private var statusText: (text: String, warn: Bool) {
        if settings.fleetReportingPaused { return ("Paused: this Mac's VMs are not being sent", false) }
        if fleet.identity?.viaPrivateNetwork == true {
            switch fleet.net {
            case .starting: return ("Connecting to the fleet's network…", false)
            case .needsKey: return ("The fleet's network no longer accepts this Mac. Enter a new pairing code.", true)
            case .failed(let why): return (why, true)
            default: break
            }
        }
        switch fleet.upload?.state {
        case .upToDate?: return ("Reporting · up to date", false)
        case .catchingUp?: return ("Reporting · sending older history", false)
        case .unreachable?: return ("The hub is not reachable. Recording continues and will be sent later.", true)
        case .rejected?: return ("The hub no longer accepts this Mac. Enter a new pairing code.", true)
        default: return ("Connecting…", false)
        }
    }

    // MARK: Hosting the hub

    @ViewBuilder private var hosting: some View {
        hostToggle
        if fleet.hubRunning {
            LabeledContent {
                HStack {
                    Button(copied == "address" ? "Copied" : "Copy") { copy(fleet.shareAddress, "address") }
                    Button("Open Fleet") { onOpenFleet() }
                }
            } label: {
                Text("Hub address")
                Text(fleet.shareAddress).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
            }
            LabeledContent {
                HStack {
                    if let code = fleet.pairingCode { Button(copied == "code" ? "Copied" : "Copy") { copy(code, "code") } }
                    Button("New pairing code") { fleet.newPairingCode(); copied = "" }
                }
            } label: {
                Text("Add a Mac")
                if let code = fleet.pairingCode {
                    Text(code).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).lineLimit(3)
                    Text("Adds one Mac. Works once, for 15 minutes. Treat it like a password.")
                } else {
                    Text("Creates a code to paste into UTM Watch's Settings on the other Mac")
                }
            }
            if !fleet.enrolled.isEmpty {
                ForEach(fleet.enrolled, id: \.uuid) { host in
                    LabeledContent {
                        if host.uuid == fleet.identity?.hostUUID { Text("This Mac").foregroundStyle(.secondary) }
                        else { Button("Revoke…", role: .destructive) { revoking = host } }
                    } label: {
                        Text(host.name)
                        Text(host.lastSeen == nil ? "Joined, not reported yet" : host.state == "online" ? "Online" : host.state == "asleep" ? "Asleep" : "Offline")
                    }
                }
                .confirmationDialog("Revoke \(revoking?.name ?? "this Mac")?", isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } })) {
                    Button("Revoke", role: .destructive) { if let h = revoking { fleet.revoke(h.uuid) }; revoking = nil }
                    Button("Cancel", role: .cancel) { revoking = nil }
                } message: { Text("It can no longer report to this hub or see the fleet. Its history stays until it ages out.") }
            }
            alertsToggle
            otherNetworks
        } else if fleet.hubError == nil {
            LabeledContent("Hub") { HStack { ProgressView().controlSize(.small); Text("Starting…").foregroundStyle(.secondary) } }
        }
    }

    @ViewBuilder private var otherNetworks: some View {
        switch fleet.net {
        case .ready(_, let address):
            LabeledContent {
                Button("Disconnect") { fleet.disconnectOtherNetworks() }
            } label: {
                Text("Macs on other networks")
                Text("Connected as \(address). New pairing codes work from any network.")
            }
        case .starting:
            LabeledContent("Macs on other networks") { HStack { ProgressView().controlSize(.small); Text("Connecting…").foregroundStyle(.secondary) } }
        default:
            LabeledContent {
                HStack {
                    SecureField("Tailscale auth key", text: $authKey, prompt: Text("tskey-auth-…")).labelsHidden().textFieldStyle(.roundedBorder).frame(width: 190)
                    Button("Connect") { fleet.connectOtherNetworks(authKey: authKey); authKey = "" }.disabled(authKey.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } label: {
                Text("Connect Macs on other networks")
                Text(otherNetworksHelp.text).foregroundStyle(otherNetworksHelp.warn ? Color.orange : Color.secondary)
            }
        }
    }

    private var otherNetworksHelp: (text: String, warn: Bool) {
        switch fleet.net {
        case .needsKey: return ("That key was not accepted or has expired. Create a new one in your Tailscale account.", true)
        case .failed(let why): return (why, true)
        default: return ("Only needed when a Mac is not on this network. Paste a reusable auth key from your own Tailscale account; nothing appears in the menu bar and an existing Tailscale is left alone.", false)
        }
    }

    private func copy(_ text: String, _ what: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = what
    }
}
