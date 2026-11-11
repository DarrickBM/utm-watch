import AppKit
import Combine
import SwiftUI
import UserNotifications
import UTMWatchCore

/// Menu bar item: live title, hover brief, left click = details, right click = menu.
final class StatusItemController: NSObject {
    var onOpenDetails: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    private let model: AppModel
    private let settings: AppSettings
    private let debug: Bool
    private let item: NSStatusItem
    private var cancellable: AnyCancellable?
    private var panel: NSPanel?
    private var openTimer: Timer?
    private var closeTimer: Timer?
    private let openDelay: TimeInterval = 0.2
    private let closeDelay: TimeInterval = 0.25
    private var hoverTimer: Timer?
    private var pointerInside = false
    private var showingWarning = false
    private let briefPointer = BriefPointer()
    private var lastLoggedFrame: NSRect = .zero

    init(model: AppModel, settings: AppSettings, debug: Bool) {
        self.model = model
        self.settings = settings
        self.debug = debug
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        guard let button = item.button else { return }
        button.image = NSImage(systemSymbolName: "macwindow.on.rectangle", accessibilityDescription: "UTM Watch")
        button.imagePosition = .imageLeading
        button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        button.title = model.title
        button.target = self
        button.action = #selector(clicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        installHoverMonitors()
        FileLog.shared.log("status item created, frame \(button.window?.frame ?? .zero)")

        cancellable = model.$snapshot.receive(on: RunLoop.main).sink { [weak self] _ in
            guard let self, let button = self.item.button else { return }
            let title = self.model.title
            if button.title != title { button.title = title } // touch AppKit only when the text changes
            let warn = self.model.hasWarning
            if warn != self.showingWarning {
                self.showingWarning = warn
                button.image = NSImage(systemSymbolName: warn ? "exclamationmark.triangle.fill" : "macwindow.on.rectangle",
                                       accessibilityDescription: warn ? "UTM Watch, warning" : "UTM Watch")
            }
            if self.panel != nil { DispatchQueue.main.async { self.resizePanel() } } // rows may have appeared or gone
            if self.debug, let w = button.window, w.frame != self.lastLoggedFrame {
                self.lastLoggedFrame = w.frame
                FileLog.shared.log("status item frame \(w.frame) screen \(w.screen?.frame ?? .zero) visible \(w.isVisible) occlusion \(w.occlusionState.contains(.visible))")
            }
        }
    }

    // MARK: Clicks

    @objc private func clicked(_ sender: Any?) {
        closePanel()
        if NSApp.currentEvent?.type == .rightMouseUp {
            // Attach the menu only for this click so left click keeps its own action.
            item.menu = makeMenu()
            item.button?.performClick(nil)
            item.menu = nil
        } else {
            onOpenDetails?()
        }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open UTM Watch", action: #selector(openDetails), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        if debug {
            menu.addItem(.separator())
            menu.addItem(withTitle: "Send test notification", action: #selector(testNotification), keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit UTM Watch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    @objc private func openDetails() { onOpenDetails?() }
    @objc private func openSettings() { onOpenSettings?() }

    @objc private func testNotification() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            FileLog.shared.log("notification authorization granted=\(granted) error=\(String(describing: error))")
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "UTM Watch"
            content.body = "Test notification: alerts will appear like this."
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { error in
                FileLog.shared.log("notification delivered error=\(String(describing: error))")
            }
        }
    }

    // MARK: Hover

    // macOS draws status items inside Control Center's process, so the button gets no tracking-area
    // events, and global mouse-moved monitors are not delivered to an unprivileged app either.
    // The pointer position itself is always readable, so hover is a cheap poll: one rectangle test
    // a few times a second (the timer has a generous tolerance so macOS can coalesce the wakeups).
    private func installHoverMonitors() {
        let t = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in self?.pointerMoved() }
        t.tolerance = 0.05
        RunLoop.main.add(t, forMode: .common)
        hoverTimer = t
    }

    private func pointerMoved() {
        guard let itemFrame = item.button?.window?.frame else { return }
        let p = NSEvent.mouseLocation
        let overItem = itemFrame.contains(p)
        // The 6pt outset covers the small gap between the menu bar and the panel.
        let overPanel = panel.map { $0.frame.insetBy(dx: -6, dy: -6).contains(p) } ?? false
        let inside = overItem || overPanel
        // Position inside the brief (top-left origin), so it can explain the value under the pointer.
        let local: CGPoint? = panel.flatMap { $0.frame.contains(p) ? CGPoint(x: p.x - $0.frame.minX, y: $0.frame.maxY - p.y) : nil }
        if local != briefPointer.point {
            briefPointer.point = local
            if debug, let local { FileLog.shared.log("hover: point in brief \(Int(local.x)),\(Int(local.y))") }
        }
        guard inside != pointerInside else { return }
        pointerInside = inside
        if inside {
            FileLog.shared.log("hover: pointer entered")
            closeTimer?.invalidate()
            if panel == nil {
                openTimer?.invalidate()
                openTimer = Timer.scheduledTimer(withTimeInterval: openDelay, repeats: false) { [weak self] _ in self?.openPanel() }
            }
        } else {
            FileLog.shared.log("hover: pointer left")
            openTimer?.invalidate()
            scheduleClose()
        }
    }

    private func scheduleClose() {
        closeTimer?.invalidate()
        closeTimer = Timer.scheduledTimer(withTimeInterval: closeDelay, repeats: false) { [weak self] _ in self?.closePanel() }
    }

    private func openPanel() {
        guard panel == nil, let buttonWindow = item.button?.window else { return }
        let host = NSHostingView(rootView: BriefView(model: model, settings: settings, showsHint: true, pointer: briefPointer, onLayoutChange: { [weak self] in
            DispatchQueue.main.async { self?.resizePanel() }
        }))
        let size = host.fittingSize

        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .popUpMenu
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        p.contentView = host

        // Centered under the item, kept on screen, touching the menu bar so the pointer can travel into it.
        let anchor = buttonWindow.frame
        let screen = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var x = anchor.midX - size.width / 2
        x = min(max(x, screen.minX + 8), screen.maxX - size.width - 8)
        p.setFrameOrigin(NSPoint(x: x, y: anchor.minY - size.height - 2))
        p.orderFrontRegardless()
        panel = p
        FileLog.shared.log("hover: brief shown \(Int(size.width))x\(Int(size.height)) frame \(p.frame)")
    }

    /// Refits the panel to its content, keeping the top edge under the menu bar.
    private func resizePanel() {
        guard let p = panel, let host = p.contentView else { return }
        let size = host.fittingSize
        guard abs(size.height - p.frame.height) > 0.5 else { return }
        let top = p.frame.maxY
        p.setFrame(NSRect(x: p.frame.minX, y: top - size.height, width: size.width, height: size.height), display: true)
        if debug { FileLog.shared.log("hover: brief resized to \(Int(size.width))x\(Int(size.height))") }
    }

    private func closePanel() {
        openTimer?.invalidate()
        closeTimer?.invalidate()
        guard let p = panel else { return }
        p.orderOut(nil)
        panel = nil
        briefPointer.point = nil
        FileLog.shared.log("hover: brief hidden")
    }
}
