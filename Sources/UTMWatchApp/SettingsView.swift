import AppKit
import SwiftUI
import UTMWatchCore
import UTMWatchStore

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var model: AppModel
    @ObservedObject var fleet: FleetController
    var onClearData: () -> Void
    var onOpenFleet: () -> Void = {}

    @State private var copied = false
    private var connectCommand: String {
        "claude mcp add utm-watch -- \"\(Bundle.main.bundlePath)/Contents/MacOS/utmwatch-mcp\""
    }
    @State private var confirmClear = false
    @State private var stats: HistoryStore.Stats?

    private var storageText: String {
        guard model.store != nil else { return "History recording is unavailable" }
        guard let s = stats, let oldest = s.oldest else { return "Nothing recorded yet. Recording continues from now." }
        let f = DateFormatter(); f.dateFormat = "EEE d MMM, HH:mm"
        return "Since \(f.string(from: Date(ms: oldest))), \(Format.bytes(UInt64(s.bytes))) on disk"
    }

    private func loadStats() {
        guard let store = model.store else { return }
        DispatchQueue.global(qos: .utility).async {
            let s = store.stats()
            DispatchQueue.main.async { stats = s }
        }
    }

    var body: some View {
        Form {
            Section("General") {
                Toggle(isOn: Binding(get: { settings.launchAtLogin }, set: { settings.setLaunchAtLogin($0) })) {
                    Text("Launch at login")
                    Text(settings.launchAtLoginError ?? "Needed to record history while you are not watching")
                }
                Toggle(isOn: $settings.checkForUpdates) {
                    Text("Check for updates automatically")
                    Text("Once a day, from GitHub. Nothing about this Mac or its VMs is sent.")
                }
                Picker("Sample every", selection: $settings.sampleInterval) {
                    Text("1 s").tag(1); Text("2 s").tag(2); Text("5 s").tag(5)
                }.pickerStyle(.segmented)
                Picker("Network units", selection: $settings.rateUnits) {
                    Text("MB/s").tag(RateUnits.bytes); Text("Mbps").tag(RateUnits.bits)
                }.pickerStyle(.segmented)
                Toggle(isOn: $settings.showOtherVMs) {
                    Text("Show VMs from other apps")
                    Text("Docker Desktop, Tart and others. Their memory counts on this Mac either way.")
                }
            }

            FleetSettingsSection(fleet: fleet, settings: settings, onOpenFleet: onOpenFleet)

            Section {
                Picker("Keep history for", selection: $settings.retentionDays) {
                    Text("1 day").tag(1); Text("7 days").tag(7); Text("30 days").tag(30)
                }.pickerStyle(.segmented)
                LabeledContent {
                    Button("Clear data…", role: .destructive) { confirmClear = true }.disabled(model.store == nil)
                } label: {
                    Text("Recorded data")
                    Text(storageText)
                }
                .confirmationDialog("Delete all recorded history?", isPresented: $confirmClear) {
                    Button("Delete history", role: .destructive) {
                        onClearData()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { loadStats() }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This cannot be undone. Recording continues from now.")
                }
            } header: { Text("History") }

            Section("AI diagnosis") {
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
                    Text("Saved when pressure, swap or a CPU limit event fires, so an agent can explain why")
                }
            }

            Section("Permissions") {
                LabeledContent {
                    status(utmStatus.ok, utmStatus.text)
                } label: { Text("Control UTM"); Text("VM names and states") }
                LabeledContent {
                    status(filesReadable, filesReadable ? "Granted" : "Not granted")
                } label: { Text("Read UTM's VM files"); Text("CPU and memory limits, network mapping") }
                LabeledContent {
                    Button("Open System Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                } label: { Text("If either is denied, the app keeps running with less detail.").font(.callout).foregroundStyle(.secondary) }
            }

            Section {
                HStack {
                    Text("UTM Watch \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Quit UTM Watch") { NSApp.terminate(nil) }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { loadStats() }
        // A fixed height with the form scrolling inside: the Fleet section grows and shrinks with its state.
        .frame(width: 560, height: 720)
    }

    private func status(_ ok: Bool, _ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: ok ? "checkmark" : "exclamationmark.triangle.fill").foregroundStyle(ok ? Color.green : Color.orange)
            Text(text)
        }
    }

    /// Derived from the engine's own notices, so it reflects what the last UTM query actually did.
    private var utmStatus: (ok: Bool, text: String) {
        guard let snap = model.snapshot else { return (false, "Checking…") }
        if snap.notices.contains(where: { $0.contains("automation denied") }) { return (false, "Denied") }
        if snap.notices.contains(where: { $0.contains("UTM is not running") }) { return (false, "UTM not running") }
        if snap.notices.contains(where: { $0.contains("UTM query failed") }) { return (false, "No answer from UTM") }
        return (true, "Granted")
    }

    private var filesReadable: Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: UTMBundles.defaultDirectory.path)) != nil
    }
}
