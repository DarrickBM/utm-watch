import AppKit
import SwiftUI
import UTMWatchCore
import UTMWatchStore

/// The Settings window's tabs, in toolbar order.
enum SettingsTab: String, CaseIterable {
    case general, alerts, ai, fleet

    var title: String {
        switch self {
        case .general: return "General"
        case .alerts: return "Alerts"
        case .ai: return "AI"
        case .fleet: return "Fleet"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .alerts: return "bell"
        case .ai: return "sparkles"
        case .fleet: return "network"
        }
    }
}

extension SettingsView {
    /// Every tab has the same size, so the window does not jump when the tab changes; the form scrolls inside.
    static let pageSize = NSSize(width: 560, height: 680)
}

extension View {
    func settingsPageFrame() -> some View {
        frame(width: SettingsView.pageSize.width, height: SettingsView.snapshotHeight ?? SettingsView.pageSize.height)
    }
}

// MARK: Alerts

/// What UTM Watch alerts about lives in the Alert rules window; how you hear about it lives here.
struct AlertSettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var center: AlertCenter
    var onOpenAlertRules: () -> Void

    var body: some View {
        Form {
            Section("Rules") {
                LabeledContent {
                    Button("Alert rules…") { onOpenAlertRules() }
                } label: {
                    Text("Risks and issues")
                    Text("What UTM Watch alerts you about, and when. \(center.rules.filter(\.enabled).count) of \(center.rules.count) rules are on.")
                }
            }
            Section("Notifications on this Mac") {
                Toggle(isOn: $settings.notifyIssues) {
                    Text("Notify me about issues")
                    Text("Something is broken now: a VM stopped, a disk is full, the network is down")
                }
                Toggle(isOn: $settings.notifyRisks) {
                    Text("Notify me about risks")
                    Text("Off: risks still show in the menu bar item and the brief")
                }
            }
            PhoneSection(settings: settings, center: center)
        }
        .formStyle(.grouped)
        .settingsPageFrame()
    }
}

/// Pushing alerts to an iPhone through Bark: where to send them, and what besides the alert itself.
struct PhoneSection: View {
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
        let which = n == 0 ? "No rule pushes to the phone yet." : "\(n) of \(center.rules.count) rules push to the phone."
        return which + " Choose rule by rule under \"When it opens\" in Alert rules; those rules show a small phone in the list."
    }

    var body: some View {
        Section {
            Toggle(isOn: $settings.barkOn) {
                Text("Push alerts to my iPhone with Bark")
                Text("Bark is a free app for iPhone and iPad. It has no Android version.")
            }
            if settings.barkOn {
                SecureField(text: $key, prompt: Text("From the address Bark shows")) { Text("Device key") }
                    .onChange(of: key) { keyChanged() }
                    .accessibilityLabel("Bark device key")
                TextField(text: $settings.barkServer, prompt: Text(BarkPush.defaultServer)) { Text("Server") }
                    .accessibilityLabel("Bark server address")
                LabeledContent {
                    Button(testing ? "Sending…" : "Send a test") { test() }
                        .disabled(testing || key.trimmingCharacters(in: .whitespaces).isEmpty)
                } label: {
                    if let r = testResult {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: r.ok ? "checkmark" : "exclamationmark.triangle.fill").foregroundStyle(r.ok ? Color.green : Color.orange)
                            Text(r.text).textSelection(.enabled)
                        }
                    } else {
                        Text("Open Bark on the phone and copy the key from the address it shows; you can paste the whole address. The key is kept on this Mac, in a file only you can read.")
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $settings.barkUrgentIssues) {
                    Text("Issues break through Focus")
                    Text("Sent as time-sensitive, so they show while a Focus is on")
                }
                Toggle(isOn: $settings.barkEnded) {
                    Text("Also push when an alert ends")
                    Text("One more push saying it is over, and how long it lasted")
                }
                Toggle(isOn: $settings.barkFinding) {
                    Text("Add the AI agent's finding")
                    Text("The same push is updated once the finding is ready")
                }
            }
        } header: {
            Text("Phone")
        } footer: {
            if settings.barkOn {
                Text(summary).font(.system(size: 12)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
            }
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

// MARK: AI

/// Every AI feature in one place: the agent UTM Watch runs itself, and the read-only access for agents you connect.
struct AISettingsView: View {
    @ObservedObject var settings: AppSettings
    let agent: AIAgent
    var onOpenAlertRules: () -> Void

    @State private var copied = false
    private var connectCommand: String {
        "claude mcp add utm-watch -- \"\(Bundle.main.bundlePath)/Contents/MacOS/utmwatch-mcp\""
    }

    var body: some View {
        Form {
            AIAgentSections(settings: settings, agent: agent, onOpenAlertRules: onOpenAlertRules)

            Section {
                Toggle(isOn: $settings.allowAgents) {
                    Text("Let AI agents read history")
                    Text("Read-only access through MCP, for agents you connect such as Claude")
                }
                LabeledContent {
                    Button(copied ? "Copied" : "Copy command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(connectCommand, forType: .string)
                        copied = true
                    }
                } label: {
                    Text("Connect an agent")
                    Text(connectCommand).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                }
                Toggle(isOn: $settings.captureProcesses) {
                    Text("Record the busiest processes at events")
                    Text("Saved when pressure, swap or a CPU limit event fires, so an agent can say which process was behind it")
                }
            } header: {
                Text("Agents you connect yourself (MCP)")
            }
        }
        .formStyle(.grouped)
        .settingsPageFrame()
    }
}

// MARK: Fleet

struct FleetSettingsView: View {
    @ObservedObject var fleet: FleetController
    @ObservedObject var settings: AppSettings
    var onOpenFleet: () -> Void

    var body: some View {
        Form {
            FleetSettingsSection(fleet: fleet, settings: settings, onOpenFleet: onOpenFleet)
        }
        .formStyle(.grouped)
        .settingsPageFrame()
    }
}
