import Foundation
import UTMWatchCore

/// Interactive loop: ticks the engine on the chosen interval, redraws, and handles single-key commands.
final class App {
    private let engine: MonitorEngine
    private var state: UIState
    private let terminal = Terminal()
    private var lastSnapshot: Snapshot?

    init(options: CLIOptions) {
        var eo = MonitorEngine.Options()
        eo.swapDirections = options.swapDirections
        eo.useUTMScripting = !options.noUTM
        engine = MonitorEngine(options: eo)
        state = UIState(interval: options.interval, showStopped: options.showStopped, units: options.units)
    }

    func run() {
        terminal.enableRaw()
        defer { terminal.restore() }
        var nextTick = MonotonicClock.now()
        var quit = false
        while gQuitRequested == 0 && !quit {
            // No run loop on this thread, so Foundation's autoreleased temporaries (formatters,
            // formatted strings, Data) would pile up forever without an explicit pool per iteration.
            autoreleasepool {
                let now = MonotonicClock.now()
                if now >= nextTick {
                    lastSnapshot = engine.tick(interval: state.interval.seconds)
                    draw()
                    nextTick = now &+ UInt64(state.interval.seconds * 1e9)
                }
                if gResized != 0 { gResized = 0; draw() }
                let remaining = nextTick > now ? Int32(min(UInt64(Int32.max), (nextTick - now) / 1_000_000)) : 0
                guard let key = terminal.readKey(timeoutMs: remaining) else { return }
                switch key {
                case UInt8(ascii: "q"), UInt8(ascii: "Q"), 3 /* Ctrl-C */: quit = true
                case UInt8(ascii: "1"): state.interval = .one; nextTick = 0
                case UInt8(ascii: "2"): state.interval = .two; nextTick = 0
                case UInt8(ascii: "5"): state.interval = .five; nextTick = 0
                case UInt8(ascii: "s"): state.sort = state.sort.next; draw()
                case UInt8(ascii: "h"): state.showStopped.toggle(); draw()
                case UInt8(ascii: "u"): state.units = state.units == .bytes ? .bits : .bytes; draw()
                case UInt8(ascii: "r"): engine.requestRefresh(); nextTick = 0
                default: break
                }
            }
        }
    }

    private func draw() {
        guard let snap = lastSnapshot else { return }
        let size = Terminal.size()
        var lines = Renderer.render(snap, state: state, width: size.columns, interactive: true)
        if lines.count > size.rows { lines = Array(lines.prefix(size.rows)) }
        var out = "\u{1b}[H"
        for (i, l) in lines.enumerated() {
            out += l + "\u{1b}[K"
            if i < lines.count - 1 { out += "\n" }
        }
        out += "\u{1b}[J"
        terminal.write(out)
    }
}

enum OnceRunner {
    static func run(options: CLIOptions) {
        var eo = MonitorEngine.Options()
        eo.swapDirections = options.swapDirections
        eo.useUTMScripting = !options.noUTM
        let engine = MonitorEngine(options: eo)
        _ = engine.tick(interval: options.interval.seconds)
        Thread.sleep(forTimeInterval: options.interval.seconds)
        let snap = engine.tick(interval: options.interval.seconds)
        if options.json {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            enc.dateEncodingStrategy = .iso8601
            if let data = try? enc.encode(snap) { print(String(decoding: data, as: UTF8.self)) }
        } else {
            let state = UIState(interval: options.interval, showStopped: options.showStopped, units: options.units)
            let width = isatty(STDOUT_FILENO) == 1 ? Terminal.size().columns : 140
            print(Renderer.render(snap, state: state, width: width, interactive: false).joined(separator: "\n"))
        }
    }
}
