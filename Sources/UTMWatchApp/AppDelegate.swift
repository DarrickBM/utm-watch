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

    /// A menu bar app shows no menu bar of its own, but text fields get Cut, Copy, Paste, Select All and Undo from the
    /// key equivalents of an Edit menu. Without one, ⌘V does nothing in Settings.
    private func installEditMenu() {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        // The app menu is only seen while a window is open and the app is in the Dock.
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettingsFromMenu), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide UTM Watch", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit UTM Watch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let main = NSMenu()
        let app = NSMenuItem(); app.submenu = appMenu
        let editItem = NSMenuItem(); editItem.submenu = edit
        main.addItem(app); main.addItem(editItem)
        NSApp.mainMenu = main
    }

    @objc private func openSettingsFromMenu() { showSettings() }

    /// A menu bar app has no Dock icon. While one of its windows is open it takes one, so the window can be found
    /// again from the Dock and with ⌘Tab; with the last window closed it goes back to the menu bar alone.
    private func updateDockPresence() {
        let open = [detailWindow, settingsWindow, fleetWindow].contains { $0?.isVisible == true }
        let wanted: NSApplication.ActivationPolicy = open ? .regular : .accessory
        guard NSApp.activationPolicy() != wanted else { return }
        NSApp.setActivationPolicy(wanted)
        if open { NSApp.activate(ignoringOtherApps: true) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showDetails() }
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let logDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
        FileLog.shared.open(path: logDir.appendingPathComponent("UTMWatch.log").path)
        FileLog.shared.log("launch pid \(ProcessInfo.processInfo.processIdentifier) args \(CommandLine.arguments.dropFirst().joined(separator: " "))")

        installEditMenu()
        let debug = CommandLine.arguments.contains("--debug")
        statusItem = StatusItemController(model: model, settings: settings, updater: updater, debug: debug)
        statusItem.onOpenDetails = { [weak self] in self?.showDetails() }
        statusItem.onOpenSettings = { [weak self] in self?.showSettings() }
        statusItem.onOpenFleet = { [weak self] in self?.showFleet() }
        statusItem.offersFleet = { [weak self] in self?.fleet.offersFleetWindow ?? true }
        model.attachStore()
        // Fleet: does nothing unless this Mac has joined a fleet or hosts a hub.
        fleet.start()
        // Debug aid: `--fleet-join <pairing code>` joins a fleet at launch, as pasting the code into Settings would.
        if let i = CommandLine.arguments.firstIndex(of: "--fleet-join"), i + 1 < CommandLine.arguments.count {
            let name = CommandLine.arguments.firstIndex(of: "--fleet-name").flatMap { $0 + 1 < CommandLine.arguments.count ? CommandLine.arguments[$0 + 1] : nil }
            fleet.join(code: CommandLine.arguments[i + 1], name: name ?? "")
        }
        // The same from the environment, for a real code: the launch line is logged and visible to other processes.
        if let code = ProcessInfo.processInfo.environment["UTMWATCH_FLEET_JOIN"], !code.isEmpty { fleet.join(code: code, name: "") }
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
        runDebugEditKeyCheck()
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
        updateDockPresence()
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in self?.updateDockPresence() } // after the window has gone
        if (notification.object as? NSWindow) === detailWindow { detail.isActive = false }
        if (notification.object as? NSWindow) === fleetWindow {
            fleet.viewActive = false
            fleet.remoteDetail.isActive = false
        }
    }

    private func showFleet() {
        guard fleet.offersFleetWindow else { return } // a Mac that only reports has no fleet window
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
        updateDockPresence()
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

    /// Debug aid: `--check-edit-keys <file>` opens Settings, presses ⌘A ⌘C ⌘X ⌘V ⌘Z in every text field as real key
    /// events, and writes what each did. The clipboard is put back afterwards.
    private func runDebugEditKeyCheck() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--check-edit-keys"), i + 1 < args.count else { return }
        let out = args[i + 1]
        showSettings()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, let window = self.settingsWindow else { return }
            let board = NSPasteboard.general
            let saved = board.string(forType: .string)
            func fields(_ v: NSView) -> [NSTextField] { (v as? NSTextField).map { $0.isEditable ? [$0] : [] } ?? [] + v.subviews.flatMap(fields) }
            func press(_ ch: String, code: UInt16, shift: Bool = false) {
                var flags: NSEvent.ModifierFlags = .command
                if shift { flags.insert(.shift) }
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: window.windowNumber, context: nil, characters: ch, charactersIgnoringModifiers: ch, isARepeat: false, keyCode: code) {
                        NSApp.sendEvent(e)
                    }
                }
            }
            var lines = ["key window: \(window.isKeyWindow), app active: \(NSApp.isActive)"]
            for f in fields(window.contentView ?? NSView()) {
                let kind = f is NSSecureTextField ? "secure" : "plain"
                let label = "\(kind) field “\(f.placeholderString ?? f.placeholderAttributedString?.string ?? "?")”"
                let original = f.stringValue
                guard window.makeFirstResponder(f), let editor = f.currentEditor() else { lines.append("\(label): could not focus"); continue }
                editor.string = "hello"
                editor.selectedRange = NSRange(location: 5, length: 0)
                press("a", code: 0)
                let all = editor.selectedRange.length == 5
                board.clearContents(); board.setString("marker", forType: .string)
                press("c", code: 8)
                let copy = board.string(forType: .string) == "hello"
                board.clearContents(); board.setString("marker", forType: .string)
                press("x", code: 7)
                let cut = editor.string.isEmpty && board.string(forType: .string) == "hello"
                editor.string = ""
                board.clearContents(); board.setString("pasted", forType: .string)
                press("v", code: 9)
                let paste = editor.string == "pasted"
                press("z", code: 6)
                let undo = editor.string != "pasted"
                lines.append("\(label): selectAll \(all), copy \(copy), cut \(cut), paste \(paste), undo \(undo)")
                editor.string = original
                f.stringValue = original
            }
            board.clearContents()
            if let saved { board.setString(saved, forType: .string) }
            try? lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }

    private func showSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "UTM Watch Settings"
            w.isReleasedWhenClosed = false
            w.delegate = self
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
        updateDockPresence()
    }
}
