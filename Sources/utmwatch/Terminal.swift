import Darwin
import Foundation

var gQuitRequested: Int32 = 0
var gResized: Int32 = 0

/// Raw-mode terminal with alternate screen; restores the original state on exit.
final class Terminal {
    private var original = termios()
    private var rawEnabled = false

    func enableRaw() {
        guard isatty(STDIN_FILENO) == 1 else { return }
        tcgetattr(STDIN_FILENO, &original)
        var raw = original
        cfmakeraw(&raw)
        raw.c_oflag |= UInt(OPOST | ONLCR) // keep "\n" -> "\r\n" so our output stays readable
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
        rawEnabled = true
        write("\u{1b}[?1049h\u{1b}[?25l\u{1b}[H\u{1b}[2J")
        signal(SIGINT) { _ in gQuitRequested = 1 }
        signal(SIGTERM) { _ in gQuitRequested = 1 }
        signal(SIGWINCH) { _ in gResized = 1 }
    }

    func restore() {
        guard rawEnabled else { return }
        write("\u{1b}[?25h\u{1b}[?1049l")
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
        rawEnabled = false
    }

    static func size() -> (columns: Int, rows: Int) {
        var ws = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0, ws.ws_col > 0, ws.ws_row > 0 {
            return (Int(ws.ws_col), Int(ws.ws_row))
        }
        return (100, 30)
    }

    /// Waits up to `timeoutMs` for a key; nil on timeout or signal interruption.
    func readKey(timeoutMs: Int32) -> UInt8? {
        var pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        let r = poll(&pfd, 1, max(0, timeoutMs))
        guard r > 0 else { return nil }
        var byte: UInt8 = 0
        return read(STDIN_FILENO, &byte, 1) == 1 ? byte : nil
    }

    func write(_ s: String) {
        var data = Array(s.utf8)
        var offset = 0
        while offset < data.count {
            let n = data.withUnsafeMutableBytes { Darwin.write(STDOUT_FILENO, $0.baseAddress! + offset, $0.count - offset) }
            if n <= 0 { break }
            offset += n
        }
    }
}
