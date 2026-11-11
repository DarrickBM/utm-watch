import AppKit
import Combine
import SwiftUI
import UTMWatchCore
import UTMWatchFleet
import UTMWatchStore

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let settings = AppSettings()
    lazy var model = AppModel(settings: settings)
    lazy var updater = Updater(settings: settings)
    lazy var fleet = FleetController(settings: settings, model: model)
    private var fleetWindow: NSWindow?
    private var sampler: Sampler!
    private var statusItem: StatusItemController!
    private var detailWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var cancellables: Set<AnyCancellable> = []
    private var detail: DetailModel!
    private var pruneTimer: Timer?
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let logDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
        FileLog.shared.open(path: logDir.appendingPathComponent("UTMWatch.log").path)
        FileLog.shared.log("launch pid \(ProcessInfo.processInfo.processIdentifier) args \(CommandLine.arguments.dropFirst().joined(separator: " "))")

        let debug = CommandLine.arguments.contains("--debug")
        statusItem = StatusItemController(model: model, settings: settings, updater: updater, debug: debug)
        statusItem.onOpenDetails = { [weak self] in self?.showDetails() }
        statusItem.onOpenSettings = { [weak self] in self?.showSettings() }
        statusItem.onOpenFleet = { [weak self] in self?.showFleet() }
        model.attachStore()
        // Fleet: does nothing unless this Mac has joined a fleet or hosts a hub.
        fleet.start()
        // Debug aid: `--fleet-join <pairing code>` joins a fleet at launch, as pasting the code into Settings would.
        if let i = CommandLine.arguments.firstIndex(of: "--fleet-join"), i + 1 < CommandLine.arguments.count {
            let name = CommandLine.arguments.firstIndex(of: "--fleet-name").flatMap { $0 + 1 < CommandLine.arguments.count ? CommandLine.arguments[$0 + 1] : nil }
            fleet.join(code: CommandLine.arguments[i + 1], name: name ?? "")
        }
        detail = DetailModel(model: model, settings: settings)
        sampler = Sampler(model: model)
        // Retention: prune at launch, hourly, and whenever the setting changes.
        settings.$retentionDays.removeDuplicates().sink { [weak self] days in self?.prune(days: days) }.store(in: &cancellables)
        let t = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.prune(days: self.settings.retentionDays)
        }
        t.tolerance = 300
        RunLoop.main.add(t, forMode: .common)
        pruneTimer = t
        sampler.startProbes()
        // Sleep and wake go on the timeline: a sleeping Mac pauses its VMs, which looks like a slow connection from outside.
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.model.record([HistoryEvent(ts: Date().msSince1970, kind: "sleep", vmKey: nil, label: "Mac went to sleep")])
            self?.model.flush(wait: true)
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.model.record([HistoryEvent(ts: Date().msSince1970, kind: "wake", vmKey: nil, label: "Mac woke")])
        }
        // Debug aid: `--dark` or `--light` forces the appearance, so both can be checked without changing the system setting.
        if CommandLine.arguments.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if CommandLine.arguments.contains("--light") { NSApp.appearance = NSAppearance(named: .aqua) }
        runDebugSnapshotIfRequested()
        runDebugViewSnapshots()
        runDebugFleetSnapshot()
        updater.start()
        // Debug aid: `--update-now` installs a newer release without a click, so the update path can be tested.
        if CommandLine.arguments.contains("--update-now") {
            updater.check { [weak self] result in if case .available = result { self?.updater.install() } }
        }
        // Starts sampling now and re-arms the timer whenever the interval changes in Settings.
        settings.$sampleInterval.removeDuplicates().sink { [weak self] seconds in
            self?.sampler.start(interval: Double(seconds))
        }.store(in: &cancellables)
    }

    /// Debug aid: `--snapshot-details <png>` opens the detail window and writes a picture of it after a delay,
    /// so the layout can be checked without screen-recording permission.
    private func runDebugSnapshotIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot-details"), i + 1 < args.count else { return }
        let path = args[i + 1]
        let delay = args.firstIndex(of: "--snapshot-delay").flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil } ?? 8
        showDetails()
        if let j = args.firstIndex(of: "--snapshot-length"), j + 1 < args.count, let len = Int(args[j + 1]) { detail.select(length: len) }
        if let k = args.firstIndex(of: "--snapshot-size"), k + 2 < args.count, let w = Double(args[k + 1]), let h = Double(args[k + 2]) {
            detailWindow?.setContentSize(NSSize(width: w, height: h))
        }
        if args.contains("--snapshot-pin") { detail.pin = Date().addingTimeInterval(-Double(detail.lengthSeconds) / 3) }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let view = self?.detailWindow?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            FileLog.shared.log("snapshot written to \(path)")
        }
    }

    /// Debug aid: `--snapshot-brief <png>` and `--snapshot-settings <png>` write pictures of the hover brief and
    /// the Settings window after `--snapshot-delay` seconds, without the pointer having to be anywhere.
    private var snapshotWindows: [NSWindow] = []
    private func runDebugViewSnapshots() {
        let args = CommandLine.arguments
        func path(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        let delay = path("--snapshot-delay").flatMap(Double.init) ?? 8
        func capture<V: View>(_ view: V, to path: String) {
            let host = NSHostingView(rootView: view)
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: [.borderless], backing: .buffered, defer: false)
            w.contentView = host
            w.setFrameOrigin(NSPoint(x: -20000, y: -20000)) // rendered, but off every screen
            w.orderFrontRegardless()
            snapshotWindows.append(w)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                w.setContentSize(host.fittingSize)
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                FileLog.shared.log("snapshot written to \(path)")
            }
        }
        if let p = path("--snapshot-brief") {
            capture(BriefView(model: model, settings: settings, updater: updater, showsHint: true)
                .background(Color(nsColor: .windowBackgroundColor)), to: p)
        }
        if let p = path("--snapshot-settings") {
            capture(SettingsView(settings: settings, model: model, fleet: fleet, onClearData: {}), to: p)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        fleet.shutdown() // the hub and the network helper must not outlive the app
        model.flush(wait: true) // do not lose the last few seconds
    }

    private func prune(days: Int) {
        guard let store = model.store else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400).msSince1970
        DispatchQueue.global(qos: .utility).async { store.prune(olderThan: cutoff) }
    }

    private func showDetails() {
        if detailWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 900),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "UTM Watch"
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentView = NSHostingView(rootView: DetailView(model: model, settings: settings, detail: detail,
                                                               onSettings: { [weak self] in self?.showSettings() }))
            w.contentMinSize = NSSize(width: 1180, height: 720)
            w.center()
            w.setFrameAutosaveName("UTMWatchDetail")
            detailWindow = w
            // Arrow keys step the pinned moment and Esc unpins it, unless a control (the date field, a button) has the keys.
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.detailWindow, event.window === window,
                      event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return event }
                if let responder = window.firstResponder, responder is NSText || responder is NSControl { return event }
                let many = event.modifierFlags.contains(.shift)
                switch event.keyCode {
                case 123: self.detail.stepPin(samples: many ? -10 : -1); return nil
                case 124: self.detail.stepPin(samples: many ? 10 : 1); return nil
                case 53 where self.detail.pin != nil: self.detail.pin = nil; return nil
                default: return event
                }
            }
        }
        detail.isActive = true
        NSApp.activate(ignoringOtherApps: true)
        detailWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === detailWindow { detail.isActive = false }
        if (notification.object as? NSWindow) === fleetWindow {
            fleet.viewActive = false
            fleet.remoteDetail.isActive = false
        }
    }

    private func showFleet() {
        if fleetWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 820),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "UTM Watch Fleet"
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentView = NSHostingView(rootView: FleetWindowView(fleet: fleet, settings: settings, onSettings: { [weak self] in self?.showSettings() }))
            w.contentMinSize = NSSize(width: 1180, height: 720)
            w.center()
            w.setFrameAutosaveName("UTMWatchFleet")
            fleetWindow = w
        }
        fleet.viewActive = true
        if fleet.selected != nil { fleet.remoteDetail.isActive = true }
        NSApp.activate(ignoringOtherApps: true)
        fleetWindow?.makeKeyAndOrderFront(nil)
    }

    /// Debug aid: `--snapshot-fleet <png>` opens the fleet window and writes a picture of it after `--snapshot-delay` seconds.
    /// `--snapshot-fleet-host <name>` first drills into that Mac.
    private func runDebugFleetSnapshot() {
        let args = CommandLine.arguments
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        guard let path = value("--snapshot-fleet") else { return }
        let delay = value("--snapshot-delay").flatMap(Double.init) ?? 8
        showFleet()
        if let name = value("--snapshot-fleet-host") {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay / 2) { [weak self] in
                guard let self, let host = self.fleet.hosts.first(where: { $0.name == name }) else { return }
                self.fleet.select(host.uuid)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let view = self?.fleetWindow?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            FileLog.shared.log("snapshot written to \(path)")
        }
    }

    private func showSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "UTM Watch Settings"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView(settings: settings, model: model, fleet: fleet, onClearData: { [weak self] in
                self?.model.clearHistory()
                self?.detail.refresh(force: true)
                self?.detail.refreshStats()
            }, onOpenFleet: { [weak self] in self?.showFleet() }))
            w.setContentSize(w.contentView?.fittingSize ?? w.frame.size)
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
