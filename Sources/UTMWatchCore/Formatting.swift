import Foundation

public enum RateUnits: String, Codable, CaseIterable {
    case bytes   // KB/s, MB/s
    case bits    // Kbps, Mbps
}

public enum Format {
    /// Network totals: decimal units ("1.2 GB" = 1.2e9 bytes), as network tools report them.
    public static func bytes(_ value: UInt64) -> String {
        let v = Double(value)
        if v >= 1e12 { return String(format: "%.2f TB", v / 1e12) }
        if v >= 1e9 { return String(format: "%.1f GB", v / 1e9) }
        if v >= 1e6 { return String(format: "%.0f MB", v / 1e6) }
        if v >= 1e3 { return String(format: "%.0f KB", v / 1e3) }
        return "\(value) B"
    }

    static let gib = 1024.0 * 1024 * 1024
    static let mib = 1024.0 * 1024

    /// Memory: binary units so an 8192 MiB VM shows as "8 GB", like UTM and Activity Monitor.
    public static func memory(_ value: UInt64) -> String {
        let v = Double(value)
        if v >= gib { return String(format: "%.1f GB", v / gib) }
        if v >= mib { return String(format: "%.0f MB", v / mib) }
        return String(format: "%.0f KB", v / 1024)
    }

    /// Short "x / y GB" where both share the larger unit, e.g. "6.1 / 8 GB".
    public static func memoryPair(_ used: UInt64?, _ limit: UInt64?) -> String {
        guard let limit, limit > 0 else { return used.map { memory($0) } ?? "—" }
        let unit = Double(limit) >= gib ? gib : mib
        let suffix = unit == gib ? "GB" : "MB"
        let limitStr = trimmed(Double(limit) / unit)
        guard let used else { return "— / \(limitStr) \(suffix)" }
        return "\(String(format: "%.1f", Double(used) / unit)) / \(limitStr) \(suffix)"
    }

    /// "11.8 MB/s", "0.2 KB/s", or "94.4 Mbps".
    public static func rate(_ bytesPerSecond: Double?, units: RateUnits) -> String {
        guard let b = bytesPerSecond else { return "—" }
        switch units {
        case .bytes:
            if b >= 1e9 { return String(format: "%.2f GB/s", b / 1e9) }
            if b >= 1e6 { return String(format: "%.1f MB/s", b / 1e6) }
            return String(format: "%.1f KB/s", b / 1e3)
        case .bits:
            let bits = b * 8
            if bits >= 1e9 { return String(format: "%.2f Gbps", bits / 1e9) }
            if bits >= 1e6 { return String(format: "%.1f Mbps", bits / 1e6) }
            return String(format: "%.1f Kbps", bits / 1e3)
        }
    }

    /// "2.9 / 4 cores" or "2.9 cores" when the limit is unknown.
    public static func cores(_ used: Double?, _ limit: Int?) -> String {
        let u = used.map { String(format: "%.1f", $0) } ?? "—"
        if let limit { return "\(u) / \(limit) cores" }
        return "\(u) cores"
    }

    public static func trimmed(_ v: Double) -> String {
        v == v.rounded() ? String(format: "%.0f", v) : String(format: "%.1f", v)
    }

    /// Terminal cell width: East Asian wide characters and emoji take two cells.
    public static func displayWidth(_ s: String) -> Int {
        s.unicodeScalars.reduce(0) { $0 + scalarWidth($1) }
    }

    static func scalarWidth(_ u: Unicode.Scalar) -> Int {
        let v = u.value
        if v < 0x20 || (v >= 0x7F && v < 0xA0) { return 0 }
        if (0x300...0x36F).contains(v) || (0x200B...0x200F).contains(v) || v == 0xFE0F { return 0 }
        if (0x1100...0x115F).contains(v) || (0x2E80...0x303E).contains(v) || (0x3041...0x33FF).contains(v)
            || (0x3400...0x4DBF).contains(v) || (0x4E00...0x9FFF).contains(v) || (0xA000...0xA4CF).contains(v)
            || (0xAC00...0xD7A3).contains(v) || (0xF900...0xFAFF).contains(v) || (0xFE30...0xFE4F).contains(v)
            || (0xFF00...0xFF60).contains(v) || (0xFFE0...0xFFE6).contains(v)
            || (0x1F300...0x1F64F).contains(v) || (0x1F900...0x1F9FF).contains(v) || (0x20000...0x3FFFD).contains(v) {
            return 2
        }
        return 1
    }

    public enum Align { case left, right }

    /// Pads or truncates to exactly `width` cells.
    public static func pad(_ s: String, _ width: Int, _ align: Align = .left) -> String {
        var text = s
        var w = displayWidth(text)
        if w > width {
            var out = ""
            var used = 0
            for ch in text {
                let cw = displayWidth(String(ch))
                if used + cw > max(0, width - 1) { break }
                out.append(ch); used += cw
            }
            text = out + (width > 0 ? "…" : "")
            w = displayWidth(text)
        }
        let fill = String(repeating: " ", count: max(0, width - w))
        return align == .left ? text + fill : fill + text
    }
}
