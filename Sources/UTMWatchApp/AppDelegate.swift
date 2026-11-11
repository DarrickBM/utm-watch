import AppKit
import Combine
import SwiftUI
import UTMWatchCore
import UTMWatchStore

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let settings = AppSettings()
    lazy var model = AppModel(settings: settings)
    private var sampler: Sampler!
    private var statusItem: StatusItemController!
    private var detailWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var cancellables: Set<AnyCancellable> = []
    private var detail: DetailModel!
    private var pruneTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let logDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
        FileLog.shared.open(path: logDir.appendingPathComponent("UTMWatch.log").path)
        FileLog.shared.log("launch pid \(ProcessInfo.processInfo.processIdentifier) args \(CommandLine.arguments.dropFirst().joined(separator: " "))")

        let debug = CommandLine.arguments.contains("--debug")
        statusItem = StatusItemController(model: model, settings: settings, debug: debug)
        statusItem.onOpenDetails = { [weak self] in self?.showDetails() }
        statusItem.onOpenSettings = { [weak self] in self?.showSettings() }
        model.attachStore()
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
        runDebugSnapshotIfRequested()
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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
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
        }
        detail.isActive = true
        NSApp.activate(ignoringOtherApps: true)
        detailWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === detailWindow { detail.isActive = false }
    }

    private func showSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "UTM Watch Settings"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView(settings: settings, model: model, onClearData: { [weak self] in
                self?.model.clearHistory()
                self?.detail.refresh(force: true)
                self?.detail.refreshStats()
            }))
            w.setContentSize(w.contentView?.fittingSize ?? w.frame.size)
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
