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
    @State private var confirmReset = false
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
                // One row for the one permission, always named after the sure way to grant it: the ordinary prompt
                // ("data from other apps") can stay refused after Allow on some Macs, and Full Disk Access cannot.
                // It reads "Granted" whenever the files can be read, whichever of the two let them be.
                LabeledContent {
                    VStack(alignment: .trailing, spacing: 6) {
                        status(filesStatus.ok, filesStatus.text)
                        if filesStatus.denied {
                            Button("Open Full Disk Access…") { SettingsView.openFullDiskAccess() }
                        }
                    }
                } label: {
                    Text("Full Disk Access")
                    Text("Lets UTM Watch read UTM's VM files to see which VMs run macOS.")
                }
                if filesStatus.denied || utmStatus.text == "Denied" {
                    LabeledContent {
                        Button("Reset and ask again…") { confirmReset = true }
                            .confirmationDialog("Reset UTM Watch's permissions?", isPresented: $confirmReset) {
                                Button("Reset and reopen UTM Watch") { SettingsView.resetPermissionsAndRelaunch() }
                            } message: {
                                Text("UTM Watch closes and opens again, and macOS asks twice: to control UTM, and to read data from other apps. Allow both. Nothing recorded is lost.")
                            }
                    } label: {
                        Text("Already allowed it?")
                        Text("macOS ties a permission to one build of UTM Watch and can keep refusing after an update without asking again. Resetting makes it ask once more.")
                    }
                }
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
                    Text("UTM Watch \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")"
                         + (AppSettings.buildBeta.map { " beta \($0)" } ?? "")
                         + ((Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String).map { " (build \($0))" } ?? ""))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Quit UTM Watch") { NSApp.terminate(nil) }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { loadStats() }
        // A fixed height with the form scrolling inside: the Fleet section grows and shrinks with its state.
        .frame(width: 560, height: SettingsView.snapshotHeight ?? 720)
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

    /// Debug aid: `--snapshot-height <points>` makes the settings picture tall enough to show every section.
    static var snapshotHeight: CGFloat?

    private static var lastFilesError: String?

    /// A missing folder is not a refusal: UTM may not be installed, or may never have made a VM.
    private var filesStatus: (ok: Bool, text: String, denied: Bool) {
        if UTMBundles.filesDisabled { return (false, "Not granted", true) } // the test aid imitates a refusal
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: UTMBundles.defaultDirectory.path)
            return (true, "Granted", false)
        } catch let error as NSError {
            // Logged once per distinct error: this runs on every redraw, and the exact refusal is what tells a
            // privacy denial from anything else.
            let why = "\(error.domain) \(error.code)" + ((error.userInfo[NSUnderlyingErrorKey] as? NSError).map { ", underlying \($0.domain) \($0.code)" } ?? "")
            if SettingsView.lastFilesError != why {
                SettingsView.lastFilesError = why
                FileLog.shared.log("permissions: UTM's VM folder cannot be listed: \(why)")
            }
            let missing = error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError
            return missing ? (false, "UTM has no VM folder here", false) : (false, "Not granted", true)
        }
    }

    /// Forgets what macOS recorded for this app's two permissions and reopens the app, so that it asks again.
    static func resetPermissionsAndRelaunch() {
        guard let id = Bundle.main.bundleIdentifier else { return }
        for service in ["SystemPolicyAppData", "AppleEvents"] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            p.arguments = ["reset", service, id]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try? p.run(); p.waitUntilExit()
            FileLog.shared.log("permissions: reset \(service), status \(p.terminationStatus)")
        }
        relaunch()
    }

    /// Opens the Full Disk Access list. macOS only lists an app there once it has tried to open something that
    /// list guards, so one such file is opened first; nothing is read from it.
    static func openFullDiskAccess() {
        let guarded = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db")
        if let handle = try? FileHandle(forReadingFrom: guarded) { try? handle.close() }
        FileLog.shared.log("permissions: opening Full Disk Access")
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Closes the app and opens it again; a permission changed in System Settings applies to the new process.
    static func relaunch() {
        let again = Process()
        again.executableURL = URL(fileURLWithPath: "/bin/sh")
        again.arguments = ["-c", "while kill -0 \"$0\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$1\"",
                           String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundlePath]
        try? again.run()
        NSApp.terminate(nil)
    }
}
