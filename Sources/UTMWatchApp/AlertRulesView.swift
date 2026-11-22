import AppKit
import SwiftUI
import UTMWatchCore
import UTMWatchStore

/// The Alert rules window: every rule as a sentence whose numbers change in place, a check of the rule against the
/// last 7 days of this Mac's own history, and the AI agent and notification settings.
struct AlertRulesView: View {
    @ObservedObject var center: AlertCenter
    @ObservedObject var settings: AppSettings
    @ObservedObject var model: AppModel

    /// Debug aid: the rule the window opens on.
    static var initialKind: AlertKind = .cpu
    /// Debug aid, for pictures: a sentence shown as typed and the rule an agent would propose for it.
    static var demoProposal: (request: String, rule: AlertRule)?
    @State private var selected: AlertKind = AlertRulesView.initialKind
    /// A rule the AI agent proposes, shown in the editor until the user takes or drops it.
    @State private var draft: AlertRule?
    @State private var draftResult: AlertReplay.Result?
    @State private var request = ""
    @State private var asking = false
    @State private var note: String?

    private var rule: AlertRule { draft ?? center.rules.first { $0.kind == selected } ?? selected.spec.rule }
    private var result: AlertReplay.Result? { draft != nil ? draftResult : center.replay[selected] }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            describeBar
            HStack(alignment: .top, spacing: 16) {
                ruleList.frame(width: 440)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        editor
                        HStack(alignment: .top, spacing: 14) {
                            AIAgentCard(settings: settings, agent: center.agent)
                            notificationsCard
                        }
                        PhoneCard(settings: settings, center: center)
                    }
                    .padding(.bottom, 4)
                }
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 20).padding(.vertical, 16)
        .frame(minWidth: 1180, minHeight: 760)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { center.loadReplay() }
        .onChange(of: center.replayLoaded) {
            guard center.replayLoaded, draft == nil, let demo = AlertRulesView.demoProposal else { return }
            AlertRulesView.demoProposal = nil
            request = demo.request
            selected = demo.rule.kind
            setDraft(demo.rule)
            note = "Your AI agent proposes the rule shown below. Check it against last week, change its numbers if you like, then use it or drop it."
        }
    }

    // MARK: A rule from a sentence

    private var describeBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "sparkle").font(.system(size: 15))
                TextField("Describe an alert, e.g. tell me if any VM uses more than 80% of its CPU for 5 minutes", text: $request)
                    .textFieldStyle(.roundedBorder).font(.system(size: 14))
                    .onSubmit { ask() }
                    .disabled(!center.agent.isOn || asking)
                    .accessibilityLabel("Describe an alert")
                if asking { ProgressView().controlSize(.small) }
                Button("Make a rule") { ask() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!center.agent.isOn || asking || request.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text(note ?? (center.agent.isOn
                 ? "Say what you want to be told about. Your AI agent turns it into one of the rules below, where you can check it against last week before it goes live."
                 : "Writing a rule from a sentence needs an AI agent; choose one under \"AI agent\" below. Without one, change the rules by hand in the list."))
                .font(.system(size: 12)).foregroundStyle(.secondary).padding(.leading, 28).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.14)))
    }

    private func ask() {
        let text = request.trimmingCharacters(in: .whitespaces)
        guard center.agent.isOn, !asking, !text.isEmpty else { return }
        asking = true; note = nil
        center.makeRule(from: text) { reply in
            asking = false
            switch reply {
            case .rule(let r):
                selected = r.kind
                setDraft(r)
                note = "Your AI agent proposes the rule shown below. Check it against last week, change its numbers if you like, then use it or drop it."
            case .failed(let why):
                note = why
            }
        }
    }

    private func setDraft(_ r: AlertRule?) {
        draft = r
        draftResult = r.flatMap { center.preview($0) }
    }

    /// Steppers and switches change the proposal while one is shown, and the live rule otherwise.
    private func change(_ r: AlertRule) {
        if draft != nil { setDraft(r) } else { center.update(r) }
    }

    // MARK: The list

    private var ruleList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Rules").fontWeight(.semibold)
                Spacer()
                Text("alerts in the last 7 days")
            }
            .font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 4)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(center.rules.enumerated()), id: \.element.id) { i, r in
                        if i > 0 { Divider() }
                        Button {
                            if draft != nil, r.kind != selected { setDraft(nil); note = nil }
                            selected = r.kind
                        } label: {
                            HStack(spacing: 10) {
                                LevelPill(level: r.level).frame(width: 46).opacity(r.enabled ? 1 : 0.35)
                                Text(r.sentence).foregroundStyle(r.enabled ? Color.primary : Color.secondary)
                                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 6)
                                if settings.barkOn, r.enabled, r.phone {
                                    Image(systemName: "iphone").font(.system(size: 11)).foregroundStyle(.secondary)
                                        .help("Alerts from this rule are pushed to your phone").accessibilityLabel("Pushed to your phone")
                                }
                                Text(countText(r)).font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                                    .frame(minWidth: 34, alignment: .trailing).fixedSize()
                            }
                            .padding(.horizontal, 12).frame(minHeight: 44).contentShape(Rectangle())
                            .background(r.kind == selected ? Color.primary.opacity(0.08) : Color.clear)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(r.level.title). \(r.sentence). \(r.enabled ? countText(r) + " in the last 7 days" : "Off").")
                        .accessibilityAddTraits(r.kind == selected ? .isSelected : [])
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.10)))
                .padding(1)
            }
            HStack {
                Button("Restore the standard rules") { setDraft(nil); center.restoreDefaults() }
                    .controlSize(.small).disabled(center.rules == AlertRule.defaults)
                Spacer()
            }
        }
    }

    private func countText(_ r: AlertRule) -> String {
        guard r.enabled else { return "off" }
        guard let res = center.replay[r.kind] else { return center.replayLoaded ? "–" : "…" }
        return !res.hasData ? "no data" : res.count == 0 ? "none" : "\(res.count)×"
    }

    // MARK: The editor

    private var editor: some View {
        let r = rule
        let spec = r.kind.spec
        return VStack(alignment: .leading, spacing: 14) {
            if draft != nil {
                HStack(spacing: 10) {
                    Image(systemName: "sparkle")
                    Text("Proposed by your AI agent. It is not in use yet.").fontWeight(.semibold)
                    Spacer()
                    Button("Drop it") { setDraft(nil); note = nil }
                    Button("Use this rule") {
                        if let d = draft { center.update(d) }
                        setDraft(nil); note = nil; request = ""
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.12)))
            }

            FlowLayout(spacing: 8) {
                Text(spec.prefix)
                if r.value != nil {
                    Stepper2(text: r.valueText, less: "Lower the value", more: "Raise the value",
                             onLess: { change(r.stepped(value: -1)) }, onMore: { change(r.stepped(value: 1)) })
                }
                if !spec.middle.isEmpty { Text(spec.middle) }
                Stepper2(text: AlertRule.duration(r.minutes), less: "Shorter time", more: "Longer time",
                         onLess: { change(r.stepped(minutes: -1)) }, onMore: { change(r.stepped(minutes: 1)) })
                Text(", open")
                Button {
                    var n = r; n.level = r.level == .issue ? .risk : .issue; change(n)
                } label: {
                    Text(r.level == .issue ? "an Issue" : "a Risk").fontWeight(.semibold)
                        .foregroundStyle(r.level == .issue ? Color.white : Color.black)
                        .padding(.horizontal, 12).frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 8).fill(AlertStyle.color(r.level)))
                }
                .buttonStyle(.plain)
                .help("Click to change between a Risk (will cause trouble if it carries on) and an Issue (broken now)")
                .accessibilityLabel("Opens \(r.level == .issue ? "an Issue" : "a Risk"). Click to change.")
            }
            .font(.system(size: 16))

            HStack(spacing: 16) {
                if spec.perVM { scopeMenu(r) } else {
                    (Text("Applies to: ").foregroundColor(.secondary) + Text(spec.scope).fontWeight(.semibold)).font(.system(size: 12))
                }
                Text(closesText(r)).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Toggle("Phone", isOn: Binding(get: { r.phone }, set: { on in var n = r; n.phone = on; change(n) }))
                    .toggleStyle(.switch).controlSize(.small)
                    .help(settings.barkOn ? "Also push this rule's alerts to your phone" : "Also push this rule's alerts to your phone. Set the phone up in the Phone card below first.")
                    .accessibilityLabel("Push this rule's alerts to my phone")
                Toggle("On", isOn: Binding(get: { r.enabled }, set: { on in var n = r; n.enabled = on; change(n) }))
                    .toggleStyle(.switch).controlSize(.small)
                    .accessibilityLabel("Rule is on")
            }

            replayChart(r)

            if draft == nil, let tip = center.suggestions.first(where: { $0.kind == r.kind }) {
                HStack(spacing: 12) {
                    Image(systemName: "sparkle")
                    (Text("Suggested by your AI agent. ").fontWeight(.semibold) + Text(tip.reason))
                        .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Not now") { center.dismiss(tip) }
                    Button(tipLabel(tip, now: r)) {
                        // Only the numbers the agent proposed; whatever else the user has set on the rule since stays.
                        var n = r; n.minutes = tip.rule.minutes; n.value = tip.rule.value
                        center.update(n)
                    }
                    .fontWeight(.semibold)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.10)))
    }

    private func tipLabel(_ tip: AlertAI.Suggestion, now: AlertRule) -> String {
        if tip.rule.minutes != now.minutes { return "Use \(AlertRule.duration(tip.rule.minutes))" }
        return "Use \(tip.rule.valueText)"
    }

    private func closesText(_ r: AlertRule) -> String {
        switch r.kind {
        case .vmStopped: return "Closes as soon as the VM runs again"
        case .vmDisk, .macDisk: return "Closes by itself once the disk has been back to normal for 10 minutes"
        default: return "Closes by itself once back to normal for as long as it took to open"
        }
    }

    /// Per-VM rules can leave VMs out: a guest that sleeps on purpose, a VM you stop yourself.
    private func scopeMenu(_ r: AlertRule) -> some View {
        let vms = model.ring.order.filter { !OtherVMs.isOther(key: $0) }.compactMap { key in model.ring.infos[key].map { (key, $0.name) } }
        let left = vms.filter { r.excluded.contains($0.0) }
        let label = left.isEmpty ? "every VM" : "every VM except \(left.map(\.1).joined(separator: ", "))"
        return HStack(spacing: 4) {
            Text("Applies to:").font(.system(size: 12)).foregroundStyle(.secondary)
            Menu {
                ForEach(vms, id: \.0) { key, name in
                    Toggle(name, isOn: Binding(get: { !r.excluded.contains(key) }, set: { on in
                        var n = r
                        if on { n.excluded.removeAll { $0 == key } } else if !n.excluded.contains(key) { n.excluded.append(key) }
                        change(n)
                    }))
                }
                if vms.isEmpty { Text("No VM recorded yet") }
            } label: {
                Text(label).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Untick a VM to leave it out of this rule")
        }
    }

    private func replayChart(_ r: AlertRule) -> some View {
        let res = result
        let color = r.level == .issue ? AlertStyle.issue : Color(red: 0.88, green: 0.60, blue: 0.0)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(verdict(res)).fontWeight(.semibold)
                Spacer(minLength: 8)
                Text("\(r.kind.spec.chartLabel), last 7 days of your own history").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Canvas { ctx, size in
                guard let res, res.hasData else { return }
                let n = CGFloat(max(1, res.bars.count))
                let w = (size.width - 12) / n
                for (i, bar) in res.bars.enumerated() {
                    guard let h = bar.height else { continue }
                    let height = max(2, CGFloat(min(1, max(0, h))) * (size.height - 6))
                    let rect = CGRect(x: 6 + CGFloat(i) * w, y: size.height - height, width: max(1, w - 1), height: height)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(bar.firing ? color : Color.primary.opacity(0.22)))
                }
                if let t = res.threshold {
                    let y = size.height - CGFloat(min(1, max(0, t))) * (size.height - 6)
                    var line = Path(); line.move(to: CGPoint(x: 0, y: y)); line.addLine(to: CGPoint(x: size.width, y: y))
                    ctx.stroke(line, with: .color(.primary), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    let tag = ctx.resolve(Text(r.valueText).font(.system(size: 11, weight: .semibold)).foregroundColor(Color(nsColor: .textBackgroundColor)))
                    let ts = tag.measure(in: size)
                    let above = y - ts.height - 6 > 0
                    let box = CGRect(x: size.width - ts.width - 20, y: above ? y - ts.height - 5 : y + 3, width: ts.width + 12, height: ts.height + 2)
                    ctx.fill(Path(roundedRect: box, cornerRadius: 5), with: .color(.primary))
                    ctx.draw(tag, at: CGPoint(x: box.midX, y: box.midY))
                }
            }
            .frame(height: 150)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            .overlay {
                if res == nil {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading the last 7 days…").foregroundStyle(.secondary) }
                } else if res?.hasData == false {
                    Text("Nothing recorded yet that this rule could be checked against. It is still watched from now on.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 40)
                }
            }
            .accessibilityLabel("\(r.kind.spec.chartLabel) over the last 7 days. \(verdict(res))")
            HStack {
                Text("7 days ago")
                Spacer()
                Text("Coloured bars: the rule would have had an alert open")
                Spacer()
                Text("now")
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func verdict(_ res: AlertReplay.Result?) -> String {
        guard let res else { return "Checking this rule against the last 7 days…" }
        guard res.hasData else { return "No history yet to check this rule against" }
        if res.count == 0 { return "Set like this, it would not have alerted you in the last 7 days" }
        return "Set like this, it would have alerted you \(res.count) time\(res.count == 1 ? "" : "s") in the last 7 days"
    }

    // MARK: Notifications

    private var notificationsCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Notifications").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 4)
            VStack(spacing: 0) {
                SwitchRow(label: "Notify me about issues", sub: "With the agent's finding once it is ready", isOn: $settings.notifyIssues)
                Divider()
                SwitchRow(label: "Notify me about risks", sub: "Off: risks still show in the menu bar and the brief", isOn: $settings.notifyRisks)
            }
            .padding(.horizontal, 14)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.10)))
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

struct SwitchRow: View {
    let label: String
    let sub: String
    @Binding var isOn: Bool
    var disabled = false

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                Text(sub).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle(label, isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.small).disabled(disabled)
        }
        .frame(minHeight: 54)
        .opacity(disabled ? 0.55 : 1)
    }
}

/// A value with − and + beside it.
private struct Stepper2: View {
    let text: String
    let less: String
    let more: String
    let onLess: () -> Void
    let onMore: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onLess) { Text("−").frame(width: 30, height: 30).contentShape(Rectangle()) }
                .buttonStyle(.plain).accessibilityLabel(less)
            Text(text).fontWeight(.semibold).monospacedDigit().frame(minWidth: 62)
            Button(action: onMore) { Text("+").frame(width: 30, height: 30).contentShape(Rectangle()) }
                .buttonStyle(.plain).accessibilityLabel(more)
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.22)))
    }
}

/// Lays its children out left to right and wraps them onto further lines, like words in a sentence.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            for item in row.items {
                let size = subviews[item.index].sizeThatFits(.unspecified)
                subviews[item.index].place(at: CGPoint(x: bounds.minX + item.x, y: bounds.minY + row.y + (row.height - size.height) / 2), proposal: .unspecified)
            }
        }
    }

    private struct Row { var y: CGFloat; var height: CGFloat; var width: CGFloat; var items: [(index: Int, x: CGFloat)] }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row(y: 0, height: 0, width: 0, items: [])
        for (i, v) in subviews.enumerated() {
            let size = v.sizeThatFits(.unspecified)
            if !row.items.isEmpty, row.width + spacing + size.width > width {
                rows.append(row)
                row = Row(y: row.y + row.height + spacing, height: 0, width: 0, items: [])
            }
            let x = row.items.isEmpty ? 0 : row.width + spacing
            row.items.append((i, x))
            row.width = x + size.width
            row.height = max(row.height, size.height)
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}

/// Where the AI agent runs, and how it is connected: Claude Code on this Mac, or a model reached with an API key.
struct AIAgentCard: View {
    @ObservedObject var settings: AppSettings
    let agent: AIAgent

    @StateObject private var saved = AIPresetList()
    @State private var storedKey = ""
    /// The account the key field was last filled from, so typing in the address reloads it only when the host changes.
    @State private var loadedAccount = ""
    @State private var keySaver = KeySaver()
    /// A new preset being filled in. While there is one, the Address, API key and Model fields edit it and not the
    /// settings in use, so leaving the form any way but Save changes nothing.
    @State private var draft: AIPresetDraft?
    @FocusState private var addressFocused: Bool
    @State private var claudePath: String? = AIAgent.findClaude()
    @State private var editingCommand = false
    @State private var key = ""
    @State private var testing = false
    @State private var testResult: (ok: Bool, text: String, signIn: Bool)?

    private var sub: String {
        switch settings.aiBackend {
        case "cli": return "Runs the Claude Code already on this Mac, on the plan you have."
        case "key": return "UTM Watch calls the model itself with your key; you pay the provider for each use."
        default: return "No AI. Rules, the editor and the 7-day check all work without it."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("AI agent").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 4)
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Runs on").fixedSize()
                        Spacer(minLength: 8)
                        Picker("Where the AI agent runs", selection: $settings.aiBackend) {
                            Text("Off").tag("off"); Text("Claude Code").tag("cli"); Text("API key").tag("key")
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                    }
                    Text(sub).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if settings.aiBackend == "cli" { cliBox }
                    if settings.aiBackend == "key" { keyBox }
                    if settings.aiBackend != "off" {
                        Text("What the agent is sent: the alert, and the readings around it with your VMs' names and the names of the busiest processes. It is given no tools and cannot change anything on this Mac.")
                            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 10)
                Divider()
                SwitchRow(label: "Investigate every issue when it opens", sub: "The agent reads the history around it and adds the likely cause to the alert. At most 20 a day.",
                          isOn: Binding(get: { settings.aiBackend != "off" && settings.aiInvestigate }, set: { settings.aiInvestigate = $0 }),
                          disabled: settings.aiBackend == "off")
                Divider()
                SwitchRow(label: "Suggest better settings", sub: "Once a week, for rules that alert often without anything going wrong",
                          isOn: Binding(get: { settings.aiBackend != "off" && settings.aiSuggest }, set: { settings.aiSuggest = $0 }),
                          disabled: settings.aiBackend == "off")
            }
            .padding(.horizontal, 14)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.10)))
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onAppear { loadKey(); saved.watch(true) }
        .onDisappear { draft = nil; keySaver.flush(); saved.watch(false) }
        .onChange(of: settings.aiBackend) { draft = nil; testResult = nil; claudePath = AIAgent.findClaude() }
        .onChange(of: settings.aiProvider) { draft = nil; testResult = nil; loadKey() }
    }

    private func status(_ ok: Bool, _ strong: String, _ rest: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: ok ? "checkmark" : "exclamationmark.triangle.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(ok ? Color.green : Color.orange)
            (Text(strong).fontWeight(.semibold) + Text(rest.isEmpty ? "" : " " + rest)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
    }

    private var cliBox: some View {
        let custom = settings.aiCommand.trimmingCharacters(in: .whitespaces)
        return VStack(alignment: .leading, spacing: 8) {
            if !custom.isEmpty {
                status(true, "Using your command.", "It gets the question on standard input and answers on standard output.")
            } else if let path = claudePath {
                status(true, "Found.", "Claude Code is at \((path as NSString).abbreviatingWithTildeInPath). Press Test to check that it is signed in.")
            } else {
                status(false, "Claude Code is not installed on this Mac.", "")
                HStack(spacing: 8) {
                    Link("How to install Claude Code", destination: URL(string: "https://claude.com/claude-code")!)
                    Button("Look again") { claudePath = AIAgent.findClaude() }.controlSize(.small)
                }
            }
            if let r = testResult {
                status(r.ok, r.ok ? "Connected." : "Not working.", r.ok ? "It answered." : r.text)
                if r.signIn {
                    Button("Open Terminal to sign in") { AIAgent.openClaudeInTerminal() }.controlSize(.small)
                        .help("Opens Claude Code in Terminal. Sign in there once, quit it, then press Test again.")
                }
            }
            Text("UTM Watch finds Claude Code by itself and hands it this Mac's readings each time it asks. There is nothing to set up in Claude Code.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if editingCommand || !custom.isEmpty {
                TextField("Command, e.g. ollama run llama3", text: $settings.aiCommand)
                    .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                    .accessibilityLabel("Command to run instead of Claude Code")
                Text("Runs in your login shell. Leave it empty to use Claude Code.").foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                testButton
                if !editingCommand, custom.isEmpty { Button("Use another command…") { editingCommand = true } }
            }
            .controlSize(.small)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }

    private var keyBox: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow(alignment: .top) {
                Text("Provider").foregroundStyle(.secondary).padding(.top, 4)
                FlowLayout(spacing: 5) {
                    providerChip(AIAgent.anthropic, "Anthropic")
                    ForEach(AIAgent.providers) { providerChip($0.id, $0.name) }
                    providerChip(AIAgent.custom, "Custom endpoint")
                }
                .accessibilityElement(children: .contain).accessibilityLabel("Provider")
            }
            if let named = AIAgent.providers.first(where: { $0.id == settings.aiProvider }) {
                GridRow {
                    Text("Address").foregroundStyle(.secondary)
                    (Text(named.address.replacingOccurrences(of: "https://", with: "")) + Text("  · set by the provider").foregroundColor(Color.secondary.opacity(0.7)))
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        .help("\(named.name)'s own address. For another address, such as its international one, use Custom endpoint.")
                }
            }
            if settings.aiProvider == AIAgent.custom {
                GridRow(alignment: .top) {
                    Text("Address").foregroundStyle(.secondary).padding(.top, 4)
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("https://…/v1", text: draftField(\.address, else: $settings.aiBaseURL)).textFieldStyle(.roundedBorder)
                            .focused($addressFocused)
                            .accessibilityLabel("Address of the chat-completions service")
                        FlowLayout(spacing: 5) {
                            ForEach(AIAgent.presets) { preset in
                                chip(preset.name, address: preset.address, model: preset.model, onRemove: nil)
                            }
                            // The user's own, after the built-in ones; only these can be removed.
                            ForEach(saved.presets, id: \.name) { preset in
                                chip(preset.name, address: preset.address, model: preset.model, onRemove: { remove(preset) })
                            }
                            // Always there. On an address typed but not saved yet it only asks for a name; otherwise the form starts empty.
                            if draft == nil {
                                Button {
                                    let typed = AIPresetDraft(name: AIPreset.host(of: settings.aiBaseURL) ?? "", address: settings.aiBaseURL, model: settings.aiModel, key: key)
                                    let p = problem(typed)
                                    if p != .noAddress, p != .addressTaken {
                                        draft = typed
                                    } else {
                                        draft = AIPresetDraft()
                                        addressFocused = true
                                    }
                                    testResult = nil
                                } label: {
                                    Text("+ New preset").fontWeight(.semibold)
                                        .padding(.horizontal, 10).frame(height: 22)
                                        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                                        .contentShape(Capsule())
                                }
                                .buttonStyle(.plain)
                                .help("Keeps an address with its model and key under a name of your own")
                            }
                        }
                        if let d = draft {
                            HStack(spacing: 6) {
                                Text("Name").foregroundStyle(.secondary).fixedSize()
                                TextField("Name for this endpoint", text: draftField(\.name, else: .constant(""))).textFieldStyle(.roundedBorder)
                                    .onSubmit { savePreset() }
                                    .accessibilityLabel("Name for this preset")
                                Button("Save") { savePreset() }.buttonStyle(.borderedProminent)
                                    .disabled(problem(d) != nil)
                                Button("Cancel") { draft = nil }
                            }
                            .controlSize(.small)
                            // Only what the user could not guess: an empty field needs no telling.
                            switch problem(d) {
                            case .addressTaken: Text("A preset already has this address.").foregroundStyle(.secondary)
                            case .nameBuiltIn: Text("That name is built in; choose another.").foregroundStyle(.secondary)
                            case .nameTaken: Text("You already have a preset with this name.").foregroundStyle(.secondary)
                            default: EmptyView()
                            }
                        }
                        Text("The endpoint must support OpenAI chat completions.")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            GridRow {
                Text("API key").foregroundStyle(.secondary)
                SecureField(settings.aiProvider == AIAgent.anthropic ? "sk-ant-…" : settings.aiProvider == AIAgent.custom ? "Key for this address" : "API key", text: draftField(\.key, else: $key))
                    .textFieldStyle(.roundedBorder)
                    // Saved as it is typed or pasted: closing the window must not lose it.
                    .onChange(of: key) { saveKey() }
                    .accessibilityLabel("API key")
            }
            GridRow {
                Text("Model").foregroundStyle(.secondary)
                TextField("Model name", text: draftField(\.model, else: $settings.aiModel)).textFieldStyle(.roundedBorder).accessibilityLabel("Model name")
            }
            GridRow {
                Color.clear.frame(width: 1, height: 1)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) { testButton.controlSize(.small); Text("Kept in a file only you can read").foregroundStyle(.secondary).fixedSize() }
                    if let r = testResult { status(r.ok, r.ok ? "It answered." : "Not working.", r.ok ? "The key is saved." : r.text) }
                }
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        .onChange(of: settings.aiProvider) { old, new in
            // Each provider has model names of its own: remember the one in use, and bring back the new provider's.
            settings.aiModels[old] = settings.aiModel
            settings.aiModel = settings.aiModels[new] ?? AIAgent.defaultModel(provider: new, custom: settings.aiBaseURL)
            draft = nil
        }
        // Each address has a key of its own: show the one that belongs to the address now in the field.
        .onChange(of: settings.aiBaseURL) { testResult = nil; if AIAgent.keyAccount(provider: settings.aiProvider, baseURL: settings.aiBaseURL) != loadedAccount { loadKey() } }
    }

    // MARK: Presets

    private func same(_ a: String, _ b: String) -> Bool { AIPreset.same(a, b) }

    /// A field of the draft while a new preset is being filled in; the setting in use otherwise.
    private func draftField(_ field: WritableKeyPath<AIPresetDraft, String>, else live: Binding<String>) -> Binding<String> {
        guard draft != nil else { return live }
        return Binding(get: { draft?[keyPath: field] ?? "" }, set: { draft?[keyPath: field] = $0 })
    }

    private func problem(_ d: AIPresetDraft) -> AIPresetDraft.Problem? {
        d.problem(takenAddresses: AIAgent.presets.map(\.address), reservedNames: (AIAgent.presets + AIAgent.providers).map(\.name), own: saved.presets)
    }

    /// Only here does the draft reach the settings in use: the preset is saved, its key filed under its address, and it becomes the one chosen.
    private func savePreset() {
        guard let d = draft, problem(d) == nil else { return }
        let preset = d.preset, newKey = d.key.trimmingCharacters(in: .whitespacesAndNewlines)
        saved.add(preset)
        draft = nil
        keySaver.flush() // whatever was typed for the address in use before
        let account = AIAgent.keyAccount(provider: AIAgent.custom, baseURL: preset.address)
        if !newKey.isEmpty, !KeysFile.set(newKey, for: account) { testResult = (false, "The key could not be saved.", false) }
        let sameAccount = account == loadedAccount
        settings.aiBaseURL = preset.address // a new host makes the key field reload, from the file just written
        settings.aiModel = preset.model
        if sameAccount, !newKey.isEmpty { storedKey = newKey; key = newKey }
    }

    private func remove(_ preset: AIPreset) {
        saved.remove(preset)
        // Its key goes with it, unless another of the user's presets is at the same host.
        if let host = preset.host, !saved.presets.contains(where: { $0.host == host }) {
            keySaver.cancel()
            KeysFile.set("", for: AIAgent.keyAccount(provider: AIAgent.custom, baseURL: preset.address))
            if same(preset.address, settings.aiBaseURL) { storedKey = ""; key = "" }
        }
    }

    /// One provider in the Provider choice: exactly one is chosen.
    private func providerChip(_ id: String, _ name: String) -> some View {
        let on = settings.aiProvider == id
        return Button { settings.aiProvider = id } label: {
            Text(name).lineLimit(1).fontWeight(on ? .semibold : .regular)
                .foregroundStyle(on ? Color(nsColor: .textBackgroundColor) : Color.primary)
                .padding(.horizontal, 9).frame(height: 22)
                .background(Capsule().fill(on ? Color.primary : Color(nsColor: .controlBackgroundColor)))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(on ? 0 : 0.22)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name).accessibilityAddTraits(on ? .isSelected : [])
    }

    /// One preset as a chip: click to use it. `onRemove` adds the × that only the user's own presets have.
    private func chip(_ name: String, address: String, model: String, onRemove: (() -> Void)?) -> some View {
        let on = same(address, draft?.address ?? settings.aiBaseURL)
        return HStack(spacing: 0) {
            Button {
                settings.aiBaseURL = address
                settings.aiModel = model
                draft = nil
            } label: {
                Text(name).lineLimit(1)
                    .padding(.leading, 9).padding(.trailing, onRemove == nil ? 9 : 3).frame(height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Fills in \(name)'s address\(model.isEmpty ? "" : " and the model \(model)")")
            .accessibilityLabel("\(name)\(on ? ", selected" : "")")
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).frame(width: 20, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Remove \(name) and forget its key")
                .accessibilityLabel("Remove \(name)")
            }
        }
        .foregroundStyle(on ? Color(nsColor: .textBackgroundColor) : Color.primary)
        .background(Capsule().fill(on ? Color.primary : Color(nsColor: .controlBackgroundColor)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(on ? 0 : 0.22)))
    }

    private var keyAccount: String { AIAgent.keyAccount(provider: settings.aiProvider, baseURL: settings.aiBaseURL) }

    /// Saved shortly after the last change, not on every keystroke, and under the address it was typed for.
    private func saveKey() {
        let wanted = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard wanted != storedKey else { keySaver.cancel(); return }
        keySaver.schedule(wanted, account: keyAccount) { ok in
            if ok { storedKey = wanted } else { testResult = (false, "The key could not be saved.", false) }
        }
    }

    /// The key for the address now in the field, read off the main thread.
    /// Whatever was typed for the address before is saved first.
    private func loadKey() {
        keySaver.flush()
        let account = keyAccount
        loadedAccount = account
        DispatchQueue.global(qos: .userInitiated).async {
            let saved = KeysFile.get(account) ?? ""
            DispatchQueue.main.async {
                guard account == keyAccount else { return } // the address moved on while this was read
                storedKey = saved
                key = saved
            }
        }
    }

    private var testButton: some View {
        Button(testing ? "Testing…" : "Test") {
            if settings.aiBackend == "key" { saveKey(); keySaver.flush() }
            testing = true; testResult = nil
            agent.run("Reply with the single word OK.") { result in
                testing = false
                switch result {
                case .success: testResult = (true, "", false)
                case .failure(let f): testResult = (false, f.message, f.needsSignIn)
                }
            }
        }
        .disabled(testing || draft != nil) // it asks the agent in use, not the preset being filled in
        .help(draft != nil ? "Save the preset first, then test it" : "Asks the agent one short question to check that it answers")
    }
}

/// The user's own endpoint presets: the list in `ai-presets.json`, kept in step with the file in both directions.
final class AIPresetList: ObservableObject {
    @Published private(set) var presets: [AIPreset] = AIPresetsFile.load()
    private var stamp = AIPresetsFile.modified()
    private var timer: Timer?

    func add(_ preset: AIPreset) {
        var list = presets.filter { $0.name.caseInsensitiveCompare(preset.name) != .orderedSame }
        list.append(preset)
        write(list)
    }

    func remove(_ preset: AIPreset) { write(presets.filter { $0 != preset }) }

    private func write(_ list: [AIPreset]) {
        AIPresetsFile.save(list)
        presets = list
        stamp = AIPresetsFile.modified()
    }

    /// While the card is on screen, a hand edit of the file shows up within a couple of seconds.
    func watch(_ on: Bool) {
        timer?.invalidate(); timer = nil
        guard on else { return }
        reloadIfChanged()
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.reloadIfChanged() }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func reloadIfChanged() {
        let now = AIPresetsFile.modified()
        guard now != stamp else { return }
        stamp = now
        presets = AIPresetsFile.load()
    }
}

/// Pushing alerts to an iPhone through Bark: where to send them, and what besides the alert itself.
struct PhoneCard: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var center: AlertCenter

    @State private var key = ""
    /// What is saved, as last read or written; and whether it has been read yet.
    @State private var stored = ""
    @State private var loaded = false
    @State private var saver = KeySaver()
    @State private var testing = false
    @State private var testResult: (ok: Bool, text: String)?

    private var summary: String {
        let n = center.rules.filter { $0.enabled && $0.phone }.count
        return n == 0 ? "No rule pushes to the phone yet." : "\(n) of \(center.rules.count) rules push to the phone."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Phone").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 4)
            VStack(alignment: .leading, spacing: 0) {
                SwitchRow(label: "Push alerts to my iPhone with Bark", sub: "Bark is a free app for iPhone and iPad. It has no Android version.", isOn: $settings.barkOn)
                if settings.barkOn {
                    HStack(alignment: .top, spacing: 14) {
                        setup.frame(maxWidth: .infinity, alignment: .topLeading)
                        VStack(alignment: .leading, spacing: 0) {
                            (Text(summary).fontWeight(.semibold) + Text(" Choose rule by rule with the Phone switch beside each rule's On switch; rules that push show a small phone in the list.").foregroundColor(.secondary))
                                .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true).padding(.bottom, 8)
                            Divider()
                            SwitchRow(label: "Issues break through Focus", sub: "Sent as time-sensitive, so they show while a Focus is on", isOn: $settings.barkUrgentIssues)
                            Divider()
                            SwitchRow(label: "Also push when an alert ends", sub: "One more push saying it is over, and how long it lasted", isOn: $settings.barkEnded)
                            Divider()
                            SwitchRow(label: "Add the AI agent's finding", sub: "The same push is updated once the finding is ready", isOn: $settings.barkFinding)
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .padding(.bottom, 10)
                }
            }
            .padding(.horizontal, 14)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.10)))
        }
        .onAppear { loadKey() }
        .onDisappear { saver.flush() }
        .onChange(of: settings.barkOn) { loadKey() }
    }

    /// The saved key, read off the main thread.
    private func loadKey() {
        guard settings.barkOn, !loaded else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let saved = BarkSender.savedKey()
            DispatchQueue.main.async {
                loaded = true
                stored = saved
                if key.isEmpty { key = saved }
            }
        }
    }

    private var setup: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                Text("Device key").foregroundStyle(.secondary).fixedSize()
                SecureField("From the address Bark shows", text: $key).textFieldStyle(.roundedBorder)
                    .onChange(of: key) { keyChanged() }
                    .accessibilityLabel("Bark device key")
            }
            GridRow {
                Text("Server").foregroundStyle(.secondary)
                TextField(BarkPush.defaultServer, text: $settings.barkServer).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Bark server address")
            }
            GridRow {
                Color.clear.frame(width: 1, height: 1)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Button(testing ? "Sending…" : "Send a test") { test() }.controlSize(.small).disabled(testing || key.trimmingCharacters(in: .whitespaces).isEmpty)
                        if let r = testResult {
                            Image(systemName: r.ok ? "checkmark" : "exclamationmark.triangle.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(r.ok ? Color.green : Color.orange)
                            Text(r.text).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        }
                    }
                    Text("Open Bark on the phone and copy the key from the address it shows; you can paste the whole address. The key is kept on this Mac, in a file only you can read. Use your own server's address if you run one.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }

    /// A whole pasted address is taken apart into the server and the key. The key is saved shortly after the last
    /// change, not on every keystroke.
    private func keyChanged() {
        let parsed = BarkPush.parse(key)
        if parsed.server != nil || key.contains("://") {
            if let server = parsed.server { settings.barkServer = server }
            key = parsed.key
            return // setting `key` calls this again with the bare key
        }
        // A key supplied for one trial run, or typed into a run pointed at another server, is not the user's to keep.
        guard loaded, ProcessInfo.processInfo.environment["UTMWATCH_BARK_KEY"] == nil, !BarkSender.redirected else { return }
        guard parsed.key != stored else { saver.cancel(); return }
        let value = parsed.key
        saver.schedule(value, account: BarkSender.account) { ok in
            if ok { stored = value } else { testResult = (false, "The key could not be saved.") }
        }
    }

    private func test() {
        testing = true; testResult = nil
        let message = BarkPush.Message(title: "UTM Watch", body: "Test: alerts will arrive like this.", id: "utmwatch-test")
        BarkSender.send(message, server: settings.barkServer, key: BarkPush.parse(key).key) { failure, _ in
            testing = false
            testResult = failure.map { (false, $0) } ?? (true, "Sent. Check your phone.")
        }
    }
}

/// Saves a key a moment after the last change to its field, off the main thread, and always under
/// the account it was typed for.
final class KeySaver {
    private var pending: (value: String, account: String, done: (Bool) -> Void)?
    private var work: DispatchWorkItem?

    func schedule(_ value: String, account: String, done: @escaping (Bool) -> Void) {
        work?.cancel()
        pending = (value, account, done)
        let item = DispatchWorkItem { [weak self] in self?.flush() }
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: item)
    }

    func cancel() { work?.cancel(); work = nil; pending = nil }

    /// Saves now whatever is waiting: before a test, when the field's address changes, when the window closes.
    func flush() {
        work?.cancel(); work = nil
        guard let p = pending else { return }
        pending = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = KeysFile.set(p.value, for: p.account)
            DispatchQueue.main.async { p.done(ok) }
        }
    }
}
