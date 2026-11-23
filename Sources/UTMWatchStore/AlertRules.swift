import Foundation

/// How bad an alert is. A risk will break something if it carries on; an issue is broken now.
public enum AlertLevel: String, Codable, Equatable {
    case risk, issue
    public var title: String { self == .issue ? "Issue" : "Risk" }
}

/// What a rule watches. One rule per kind.
public enum AlertKind: String, Codable, CaseIterable, Equatable {
    case cpu
    case vmDisk = "vm_disk"
    case macDisk = "mac_disk"
    case memory
    case wifi
    case unusual
    case vmStopped = "vm_stopped"
    case vmFrozen = "vm_frozen"
    case vmUnrouted = "vm_unrouted"
    case vmDiskFull = "vm_disk_full"
    case macDiskFull = "mac_disk_full"
    case memoryCritical = "memory_critical"
    case networkDown = "network_down"
    case poorConnection = "poor_connection"
}

/// One alert rule: a sentence with a number and a time the user can change.
public struct AlertRule: Codable, Equatable, Identifiable {
    public var kind: AlertKind
    public var level: AlertLevel
    /// The threshold in the kind's own unit (percent, GB, dBm); nil for kinds that have none.
    public var value: Double?
    /// How long the condition must last, or how far ahead a forecast looks, in minutes.
    public var minutes: Int
    public var enabled: Bool
    /// VMs this rule leaves alone, by VM key.
    public var excluded: [String]
    /// This rule's alerts are also pushed to the user's phone, when a phone is set up. Issues start on, risks off.
    public var phone: Bool

    public var id: String { kind.rawValue }

    public init(kind: AlertKind, level: AlertLevel, value: Double?, minutes: Int, enabled: Bool = true, excluded: [String] = [], phone: Bool? = nil) {
        self.kind = kind; self.level = level; self.value = value; self.minutes = minutes; self.enabled = enabled; self.excluded = excluded
        self.phone = phone ?? (level == .issue)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(AlertKind.self, forKey: .kind)
        let d = kind.spec.rule
        level = try c.decodeIfPresent(AlertLevel.self, forKey: .level) ?? d.level
        value = try c.decodeIfPresent(Double.self, forKey: .value) ?? d.value
        minutes = try c.decodeIfPresent(Int.self, forKey: .minutes) ?? d.minutes
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        excluded = try c.decodeIfPresent([String].self, forKey: .excluded) ?? []
        phone = try c.decodeIfPresent(Bool.self, forKey: .phone) ?? (level == .issue)
    }

    /// The rule as a sentence, e.g. "When a VM uses more than 90% of its cores for 10 min".
    public var sentence: String {
        let s = kind.spec
        return [s.prefix, valueText, s.middle, AlertRule.duration(minutes)].filter { !$0.isEmpty }.joined(separator: " ").replacingOccurrences(of: " ,", with: ",")
    }

    /// The threshold with its unit, e.g. "90%", "20 GB", "−75 dBm"; empty when the kind has none.
    public var valueText: String { value.map { kind.spec.format($0) } ?? "" }

    /// The value moved by `steps` of the kind's step, kept inside its range.
    public func stepped(value steps: Int) -> AlertRule {
        guard let v = value else { return self }
        let s = kind.spec
        var r = self
        r.value = min(s.range.upperBound, max(s.range.lowerBound, v + Double(steps) * s.step))
        return r
    }

    /// The time moved along the kind's ladder of round durations.
    public func stepped(minutes steps: Int) -> AlertRule {
        let ladder = kind.spec.ladder
        let at = ladder.firstIndex(where: { $0 >= minutes }) ?? ladder.count - 1
        var r = self
        r.minutes = ladder[min(ladder.count - 1, max(0, at + steps))]
        return r
    }

    /// Brings a rule from outside (a file, an AI agent) inside the kind's limits.
    public func clamped() -> AlertRule {
        let s = kind.spec
        var r = self
        r.value = s.rule.value == nil ? nil : min(s.range.upperBound, max(s.range.lowerBound, value ?? s.rule.value ?? 0))
        r.minutes = min(s.ladder.last ?? 1440, max(s.ladder.first ?? 1, minutes))
        return r
    }

    public static func duration(_ minutes: Int) -> String {
        if minutes >= 1440, minutes % 1440 == 0 { let d = minutes / 1440; return d == 1 ? "1 day" : "\(d) days" }
        if minutes >= 60, minutes % 60 == 0 { let h = minutes / 60; return h == 1 ? "1 hour" : "\(h) hours" }
        return "\(minutes) min"
    }

    /// The rules a new installation starts with, in the order they are listed.
    public static var defaults: [AlertRule] { AlertKind.allCases.map { $0.spec.rule } }

    /// Stored rules laid over the defaults: every kind is present exactly once, in the standard order.
    public static func merged(_ stored: [AlertRule]) -> [AlertRule] {
        defaults.map { d in stored.first(where: { $0.kind == d.kind })?.clamped() ?? d }
    }
}

public extension AlertKind {
    struct Spec {
        public var prefix: String
        public var middle: String
        public var unit: String
        public var step: Double
        public var range: ClosedRange<Double>
        /// Durations the time control steps through, in minutes.
        public var ladder: [Int]
        /// "every VM" or "this Mac".
        public var scope: String
        public var perVM: Bool
        /// What the 7-day chart plots.
        public var chartLabel: String
        /// False when a lower reading is the bad direction (free space, signal strength).
        public var higherIsWorse: Bool
        /// The rule as shipped.
        public var rule: AlertRule

        public func format(_ v: Double) -> String {
            let n = v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
            return (v < 0 ? "−" + n.dropFirst() : n) + unit
        }
    }

    private static let holds = [1, 2, 5, 10, 15, 30, 60, 360, 1440]
    private static let horizons = [60, 360, 1440, 4320, 10080]

    var spec: Spec {
        switch self {
        case .cpu:
            return Spec(prefix: "When a VM uses more than", middle: "of its cores for", unit: "%", step: 5, range: 40...100, ladder: AlertKind.holds,
                        scope: "every VM", perVM: true, chartLabel: "Busiest VM, CPU as a share of its cores", higherIsWorse: true,
                        rule: AlertRule(kind: self, level: .risk, value: 90, minutes: 10))
        case .vmDisk:
            return Spec(prefix: "When a VM's disk is more than", middle: "full, or will be full within", unit: "%", step: 5, range: 50...100, ladder: AlertKind.horizons,
                        scope: "every VM", perVM: true, chartLabel: "Fullest VM disk", higherIsWorse: true,
                        rule: AlertRule(kind: self, level: .risk, value: 90, minutes: 1440))
        case .macDisk:
            return Spec(prefix: "When this Mac has less than", middle: "free, or will run out within", unit: " GB", step: 5, range: 5...200, ladder: AlertKind.horizons,
                        scope: "this Mac", perVM: false, chartLabel: "Free space on this Mac", higherIsWorse: false,
                        rule: AlertRule(kind: self, level: .risk, value: 20, minutes: 1440))
        case .memory:
            return Spec(prefix: "When memory pressure is at Warning for", middle: "", unit: "", step: 0, range: 0...0, ladder: AlertKind.holds,
                        scope: "this Mac", perVM: false, chartLabel: "Memory pressure", higherIsWorse: true,
                        rule: AlertRule(kind: self, level: .risk, value: nil, minutes: 10))
        case .wifi:
            return Spec(prefix: "When Wi-Fi signal is below", middle: "for", unit: " dBm", step: 5, range: -90...(-40), ladder: AlertKind.holds,
                        scope: "this Mac", perVM: false, chartLabel: "Wi-Fi signal", higherIsWorse: false,
                        rule: AlertRule(kind: self, level: .risk, value: -75, minutes: 2))
        case .unusual:
            return Spec(prefix: "When a VM's CPU, memory or network is unusual for that VM for", middle: "", unit: "", step: 0, range: 0...0, ladder: AlertKind.holds,
                        scope: "every VM, each against its own last 7 days", perVM: true, chartLabel: "Distance from each VM's usual level", higherIsWorse: true,
                        rule: AlertRule(kind: self, level: .risk, value: nil, minutes: 15))
        case .vmStopped:
            return Spec(prefix: "When a VM stops and has not started again within", middle: "", unit: "", step: 0, range: 0...0, ladder: AlertKind.holds,
                        scope: "every VM", perVM: true, chartLabel: "VMs running", higherIsWorse: false,
                        rule: AlertRule(kind: self, level: .issue, value: nil, minutes: 1))
        case .vmFrozen:
            return Spec(prefix: "When a running VM gives no ping reply for", middle: "", unit: "", step: 0, range: 0...0, ladder: AlertKind.holds,
                        scope: "every VM", perVM: true, chartLabel: "Pings to VMs without a reply", higherIsWorse: true,
                        rule: AlertRule(kind: self, level: .issue, value: nil, minutes: 1))
        case .vmUnrouted:
            return Spec(prefix: "When this Mac has no route back to a running VM for", middle: "", unit: "", step: 0, range: 0...0, ladder: AlertKind.holds,
                        scope: "every VM", perVM: true, chartLabel: "VMs this Mac has no route back to", higherIsWorse: true,
                        rule: AlertRule(kind: self, level: .issue, value: nil, minutes: 1))
        case .vmDiskFull:
            return Spec(prefix: "When a VM's disk is more than", middle: "full for", unit: "%", step: 1, range: 90...100, ladder: AlertKind.holds,
                        scope: "every VM", perVM: true, chartLabel: "Fullest VM disk", higherIsWorse: true,
                        rule: AlertRule(kind: self, level: .issue, value: 97, minutes: 1))
        case .macDiskFull:
            return Spec(prefix: "When this Mac has less than", middle: "free for", unit: " GB", step: 1, range: 1...50, ladder: AlertKind.holds,
                        scope: "this Mac", perVM: false, chartLabel: "Free space on this Mac", higherIsWorse: false,
                        rule: AlertRule(kind: self, level: .issue, value: 5, minutes: 1))
        case .memoryCritical:
            return Spec(prefix: "When memory pressure is at Critical for", middle: "", unit: "", step: 0, range: 0...0, ladder: AlertKind.holds,
                        scope: "this Mac", perVM: false, chartLabel: "Memory pressure", higherIsWorse: true,
                        rule: AlertRule(kind: self, level: .issue, value: nil, minutes: 1))
        case .networkDown:
            return Spec(prefix: "When this Mac has no network, or neither the router nor the internet answers, for", middle: "", unit: "", step: 0, range: 0...0, ladder: AlertKind.holds,
                        scope: "this Mac", perVM: false, chartLabel: "Pings to the router and internet lost", higherIsWorse: true,
                        rule: AlertRule(kind: self, level: .issue, value: nil, minutes: 1))
        case .poorConnection:
            return Spec(prefix: "When more than", middle: "of pings to the router or internet are lost over", unit: "%", step: 5, range: 5...50, ladder: AlertKind.holds,
                        scope: "this Mac", perVM: false, chartLabel: "Pings to the router and internet lost", higherIsWorse: true,
                        rule: AlertRule(kind: self, level: .issue, value: 10, minutes: 5))
        }
    }

    /// The issue that says the same thing more strongly. While it is open for the same subject, this risk is not shown.
    var escalation: AlertKind? {
        switch self {
        case .vmDisk: return .vmDiskFull
        case .macDisk: return .macDiskFull
        case .memory: return .memoryCritical
        default: return nil
        }
    }
}

/// Reads and writes the rules file that sits beside the history database, so the MCP helper can read it too.
public enum AlertRulesFile {
    public static var path: String {
        ((HistoryStore.defaultPath as NSString).deletingLastPathComponent as NSString).appendingPathComponent("alert-rules.json")
    }

    public static func load(path: String = AlertRulesFile.path) -> [AlertRule] {
        guard let data = FileManager.default.contents(atPath: path) else { return AlertRule.defaults }
        // Rules of a kind this copy does not know are skipped one by one, so a newer file still loads.
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return AlertRule.defaults }
        let rules = raw.compactMap { item -> AlertRule? in
            guard item is [String: Any], let d = try? JSONSerialization.data(withJSONObject: item) else { return nil }
            return try? JSONDecoder().decode(AlertRule.self, from: d)
        }
        return AlertRule.merged(rules)
    }

    public static func save(_ rules: [AlertRule], path: String = AlertRulesFile.path) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(rules) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
