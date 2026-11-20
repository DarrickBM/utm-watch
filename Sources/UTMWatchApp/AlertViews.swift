import SwiftUI
import UTMWatchCore
import UTMWatchStore

/// SwiftUI has an `Alert` of its own; in this app the word means ours.
typealias Alert = UTMWatchStore.Alert

/// Colours and wording shared by every place an alert shows.
enum AlertStyle {
    static let risk = Color(red: 0.98, green: 0.70, blue: 0.10)
    static let issue = Color(red: 0.78, green: 0.06, blue: 0.18)
    static func color(_ level: AlertLevel) -> Color { level == .issue ? issue : risk }

    private static let clock: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()
    private static let weekday: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE"; return f }()

    private static func day(_ d: Date, now: Date) -> String {
        let cal = Calendar.current
        if cal.isDate(d, inSameDayAs: now) { return "Today" }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(d, inSameDayAs: y) { return "Yesterday" }
        return weekday.string(from: d)
    }

    static func length(_ ms: Int64) -> String {
        let minutes = max(1, Int((Double(ms) / 60_000).rounded()))
        if minutes < 60 { return "\(minutes) min" }
        if minutes < 1440 { return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min" }
        return "\(minutes / 1440) d"
    }

    /// "6 min ago", "since yesterday", "since Tue".
    static func ago(_ opened: Int64, now: Date = Date()) -> String {
        let d = Date(ms: opened)
        let ms = now.msSince1970 - opened
        if ms < 60_000 { return "just now" }
        if ms < 3600_000 { return "\(length(ms)) ago" }
        let name = day(d, now: now)
        return name == "Today" ? "\(length(ms)) ago" : "since \(name.lowercased() == "yesterday" ? "yesterday" : name)"
    }

    /// "14:02, 6 min ago" or "since yesterday 16:40".
    static func since(_ opened: Int64, now: Date = Date()) -> String {
        let d = Date(ms: opened)
        let name = day(d, now: now)
        if name == "Today" { return "\(clock.string(from: d)), \(ago(opened, now: now))" }
        return "since \(name == "Yesterday" ? "yesterday" : name) \(clock.string(from: d))"
    }

    /// "Today 15:26 to 16:02".
    static func range(_ a: Alert, now: Date = Date()) -> String {
        let from = Date(ms: a.opened)
        guard let closed = a.closed, closed - a.opened >= 90_000 else { return "\(day(from, now: now)) \(clock.string(from: from))" }
        return "\(day(from, now: now)) \(clock.string(from: from)) to \(clock.string(from: Date(ms: closed)))"
    }

    static func counts(_ alerts: [Alert]) -> String {
        let issues = alerts.filter { $0.level == .issue }.count, risks = alerts.count - issues
        var parts: [String] = []
        if issues > 0 { parts.append("\(issues) issue\(issues == 1 ? "" : "s")") }
        if risks > 0 { parts.append("\(risks) risk\(risks == 1 ? "" : "s")") }
        return parts.joined(separator: ", ")
    }
}

struct LevelPill: View {
    let level: AlertLevel
    var body: some View {
        Text(level.title).font(.system(size: 11, weight: .semibold))
            .foregroundStyle(level == .issue ? Color.white : Color.black)
            .padding(.horizontal, 8).frame(height: 18)
            .background(Capsule().fill(AlertStyle.color(level)))
            .fixedSize()
    }
}

/// The "needs attention" list at the top of the hover brief: one line per open alert.
struct AlertsAttention: View {
    let alerts: [Alert]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(alerts.prefix(4).enumerated()), id: \.element.key) { i, a in
                if i > 0 { Divider() }
                HStack(alignment: .top, spacing: 10) {
                    LevelPill(level: a.level).padding(.top, 1)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(a.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(AlertStyle.ago(a.opened)).foregroundStyle(.secondary).fixedSize()
                        }
                        Text(a.what).foregroundStyle(.secondary).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 9)
                .accessibilityElement(children: .combine)
            }
            if alerts.count > 4 {
                Divider()
                Text("and \(alerts.count - 4) more in the Alerts list").foregroundStyle(.secondary).padding(.vertical, 7)
            }
        }
        .padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color(nsColor: .textBackgroundColor).opacity(0.75)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.12)))
    }
}

/// The Alerts list that slides over the right side of the detail window.
struct AlertsPanel: View {
    @ObservedObject var center: AlertCenter
    var onShow: (Int64) -> Void
    var onRules: () -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Now").font(.system(size: 15, weight: .semibold))
                        Spacer()
                        Text(center.open.isEmpty ? "all clear" : AlertStyle.counts(center.open)).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    if center.open.isEmpty {
                        Text("Nothing needs attention. An alert shows here when a rule's condition has lasted its time, and leaves by itself when the problem is over.")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.12)))
                    }
                    ForEach(center.open, id: \.key) { a in card(a) }

                    HStack(alignment: .firstTextBaseline) {
                        Text("Earlier").font(.system(size: 15, weight: .semibold))
                        Spacer()
                        Text("Last 7 days").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .padding(.top, 6)
                    if center.past.isEmpty {
                        Text("No alert has ended in the last 7 days.").foregroundStyle(.secondary)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(center.past.prefix(40).enumerated()), id: \.offset) { i, a in
                                if i > 0 { Divider() }
                                Button { onShow(a.opened) } label: {
                                    HStack(spacing: 10) {
                                        Circle().fill(AlertStyle.color(a.level)).frame(width: 8, height: 8)
                                        (Text(a.title).fontWeight(.semibold) + Text(a.closed.map { "  for \(AlertStyle.length($0 - a.opened))" } ?? "").foregroundColor(.secondary))
                                            .lineLimit(1)
                                        Spacer(minLength: 8)
                                        Text(AlertStyle.range(a)).font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit().fixedSize()
                                    }
                                    .frame(minHeight: 40).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help("Show this moment on the timeline. \(a.what)")
                                .accessibilityLabel("\(a.level.title), \(a.title), \(AlertStyle.range(a)). Show on timeline.")
                            }
                        }
                        .padding(.horizontal, 14)
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.12)))
                    }
                }
                .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12)
            }
            Divider()
            HStack {
                Button("Alert rules…") { onRules() }
                Spacer()
                Button("Close") { onClose() }.keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20).padding(.vertical, 10)
        }
        .font(.system(size: 13))
        .frame(width: 440)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .leading) { Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1) }
        .shadow(color: .black.opacity(0.16), radius: 14, x: -6, y: 0)
    }

    private func card(_ a: Alert) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                LevelPill(level: a.level)
                Text(a.title).fontWeight(.semibold).lineLimit(2)
                Spacer(minLength: 8)
                Text(AlertStyle.since(a.opened)).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize()
            }
            Text(a.what).fixedSize(horizontal: false, vertical: true)
            Text(a.todo).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let finding = a.finding {
                (Text("Looked into by your AI agent\(a.findingAt.map { " at \(Self.clock.string(from: Date(ms: $0)))" } ?? ""). ").fontWeight(.semibold) + Text(finding))
                    .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
            } else if center.investigating.contains(a.key) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Your AI agent is looking into it…").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                Button("Show on timeline") { onShow(a.opened) }
                    .help("Moves the tracks to the moment this began and pins it")
                if a.rule == AlertKind.vmStopped.rawValue {
                    Button("I stopped it myself") { center.acknowledge(a) }
                        .help("Closes this alert. It stays quiet until the VM has run again.")
                } else {
                    Button("Mute for a day") { center.mute(a) }
                        .help("Closes this alert and keeps it quiet for 24 hours")
                }
            }
            .controlSize(.small).padding(.top, 2)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.12)))
    }

    private static let clock: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()
}
