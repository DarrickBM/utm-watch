import AppKit
import Combine
import Foundation
import UserNotifications
import UTMWatchCore
import UTMWatchStore

/// Everything about alerts on this Mac: runs the engine on each reading, keeps the open and recent alerts, sends
/// notifications, asks the AI agent, and holds the rules. Main thread only.
final class AlertCenter: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    /// Open alerts as shown: issues first, then newest first, without a risk whose issue is also open.
    @Published private(set) var open: [Alert] = []
    /// Alerts that ended in the last 7 days, newest first.
    @Published private(set) var past: [Alert] = []
    @Published private(set) var rules: [AlertRule]
    /// How each rule would have done over the recorded week; nil until worked out.
    @Published private(set) var replay: [AlertKind: AlertReplay.Result] = [:]
    @Published private(set) var replayLoaded = false
    /// Settings the AI agent proposes for rules that alert too often.
    @Published private(set) var suggestions: [AlertAI.Suggestion] = []
    /// Alerts the agent is looking into right now, by alert key.
    @Published private(set) var investigating: Set<String> = []

    /// Puts alert openings and endings on the timeline.
    var onEvents: (([HistoryEvent]) -> Void)?
    /// The user clicked a notification: show that moment.
    var onShow: ((Int64) -> Void)?

    let agent: AIAgent
    private let settings: AppSettings
    private let defaults = UserDefaults.standard
    private var engine: AlertEngine
    private var store: HistoryStore?
    private let io = DispatchQueue(label: "utmwatch.alerts", qos: .utility)
    private var ids: [String: Int64] = [:]            // alert key -> row id; touched on `io` only
    private var timeline: AlertReplay.Timeline?
    private var replayGeneration = 0
    private var askedForNotifications = false
    private var lastBaselines = Date.distantPast
    private var demo = false
    private static let maxInvestigationsPerDay = 20

    /// The worst open alert's level; nil when all is clear. Drives the menu bar mark.
    var level: AlertLevel? { open.contains { $0.level == .issue } ? .issue : (open.isEmpty ? nil : .risk) }

    init(settings: AppSettings) {
        self.settings = settings
        agent = AIAgent(settings: settings)
        let loaded = AlertRulesFile.load()
        rules = loaded
        engine = AlertEngine(rules: loaded)
        if let saved = defaults.dictionary(forKey: "alertMuted") as? [String: NSNumber] {
            let now = Date().msSince1970
            engine.muted = saved.mapValues(\.int64Value).filter { $0.value > now }
        }
        if let data = defaults.data(forKey: "alertSuggestions"), let list = try? JSONDecoder().decode([AlertAI.Suggestion].self, from: data) {
            suggestions = list
        }
        super.init()
        suggestions = suggestions.filter { s in rules.contains { $0.kind == s.kind && ($0.minutes != s.rule.minutes || $0.value != s.rule.value) } }
        if Bundle.main.bundleIdentifier != nil { UNUserNotificationCenter.current().delegate = self }
    }

    // MARK: Start

    func attach(store: HistoryStore) {
        self.store = store
        let now = Date().msSince1970
        io.async { [weak self] in
            let stored = store.alerts(since: now - 7 * 86_400_000)
            let recent = store.load(from: now - 6 * 3600_000, to: now, maxPoints: 360)
            var known: [String: Int64] = [:]
            for a in stored where a.closed == nil { known[a.key] = a.id }
            DispatchQueue.main.async {
                guard let self, !self.demo else { return }
                self.io.async { self.ids = known }
                // Alerts that were open at the last quit carry on; one whose problem has gone closes by itself.
                self.engine.restore(stored.filter { $0.closed == nil })
                self.engine.seedTrend(recent)
                self.past = stored.filter { $0.closed != nil }
                self.publish()
            }
        }
        refreshBaselines()
    }

    private func refreshBaselines() {
        guard let store, Date().timeIntervalSince(lastBaselines) > 6 * 3600 else { return }
        lastBaselines = Date()
        let now = Date().msSince1970
        io.async { [weak self] in
            let week = store.load(from: now - 7 * 86_400_000, to: now, maxPoints: 10_080)
            let b = AlertReplay.baselines(week)
            DispatchQueue.main.async { self?.engine.baselines = b }
        }
    }

    /// Called hourly: housekeeping that does not belong on the sampling path.
    func hourly() {
        refreshBaselines()
        if let store {
            let cutoff = Date().msSince1970 - 30 * 86_400_000
            io.async { store.pruneAlerts(olderThan: cutoff) }
        }
        suggestIfDue()
    }

    // MARK: Readings

    func ingest(_ snap: Snapshot) {
        guard !demo else { return }
        apply(engine.ingest(AlertSample(snap)))
    }

    func ingest(_ probe: ProbeResult) {
        guard !demo else { return }
        apply(engine.ingest(AlertProbe(probe)))
    }

    private func apply(_ changes: [AlertChange]) {
        guard !changes.isEmpty else { return }
        var events: [HistoryEvent] = []
        var ended = false
        for change in changes {
            switch change {
            case .opened(let a):
                FileLog.shared.log("alert opened: \(a.level.rawValue) \(a.title)")
                events.append(HistoryEvent(ts: Date().msSince1970, kind: a.level == .issue ? HistoryEvent.alertIssue : HistoryEvent.alertRisk,
                                           vmKey: a.vmKey, label: "\(a.level.title): \(a.title)"))
                if let store { io.async { [weak self] in self?.ids[a.key] = store.insertAlert(a) } }
                // A risk that opens while its issue is already open says nothing new.
                let outranked = AlertKind(rawValue: a.rule)?.escalation.map { self.engine.open[Alert.key(rule: $0.rawValue, subject: a.subject)] != nil } ?? false
                if !outranked { notify(a) }
                if a.level == .issue { investigate(a.key) }
            case .updated(let a):
                if let store { io.async { [weak self] in var b = a; b.id = self?.ids[a.key] ?? 0; store.updateAlert(b) } }
            case .closed(let key, let at):
                let title = open.first { $0.key == key }?.title ?? key
                FileLog.shared.log("alert ended: \(title)")
                events.append(HistoryEvent(ts: Date().msSince1970, kind: HistoryEvent.alertEnd, vmKey: nil, label: "Ended: \(title)"))
                if let store { io.async { [weak self] in if let id = self?.ids.removeValue(forKey: key) { store.closeAlert(id: id, at: at) } } }
                investigating.remove(key)
                ended = true
            }
        }
        publish()
        if ended { reloadPast() }
        onEvents?(events)
    }

    private func publish() {
        let all = Array(engine.open.values)
        open = all.filter { a in
            guard let stronger = AlertKind(rawValue: a.rule)?.escalation else { return true }
            return engine.open[Alert.key(rule: stronger.rawValue, subject: a.subject)] == nil
        }.sorted { ($0.level == .issue ? 0 : 1, -$0.opened) < ($1.level == .issue ? 0 : 1, -$1.opened) }
    }

    private func reloadPast() {
        guard let store else { return }
        let since = Date().msSince1970 - 7 * 86_400_000
        io.async { [weak self] in
            let list = store.alerts(since: since).filter { $0.closed != nil }
            DispatchQueue.main.async { self?.past = list }
        }
    }

    /// History was cleared: forget the alerts too. Whatever is still wrong opens again by itself.
    func clear() {
        let muted = engine.muted
        engine = AlertEngine(rules: rules)
        engine.muted = muted // what the user silenced stays silenced
        if let store { io.async { [weak self] in store.clearAlerts(); self?.ids = [:] } }
        open = []; past = []; replay = [:]; timeline = nil; replayLoaded = false
    }

    // MARK: What the user does with an alert

    /// Silences this alert for a day.
    func mute(_ alert: Alert) {
        let now = Date().msSince1970
        apply(engine.mute(alert.key, until: now + 86_400_000, at: now))
        defaults.set(engine.muted.mapValues { NSNumber(value: $0) }, forKey: "alertMuted")
    }

    /// "I stopped it myself": the alert goes away and stays away until the VM has run again.
    func acknowledge(_ alert: Alert) {
        apply(engine.acknowledge(alert.key, at: Date().msSince1970))
    }

    // MARK: Rules

    func update(_ rule: AlertRule) {
        guard let i = rules.firstIndex(where: { $0.kind == rule.kind }), rules[i] != rule else { return }
        let before = rules[i]
        rules[i] = rule.clamped()
        engine.rules = rules
        AlertRulesFile.save(rules)
        // A suggestion was worked out for the numbers the rule had; once they change it no longer applies.
        if before.minutes != rules[i].minutes || before.value != rules[i].value {
            suggestions.removeAll { $0.kind == rule.kind }
            saveSuggestions()
        }
        recompute([rule.kind])
    }

    func restoreDefaults() {
        rules = AlertRule.defaults
        engine.rules = rules
        AlertRulesFile.save(rules)
        recompute(AlertKind.allCases)
    }

    /// Loads the recorded week once, then says how each rule would have done over it.
    func loadReplay(force: Bool = false) {
        guard let store, timeline == nil || force else { return }
        let now = Date().msSince1970
        io.async { [weak self] in
            let week = store.load(from: now - 7 * 86_400_000, to: now, maxPoints: 10_080)
            let tl = AlertReplay.timeline(week)
            DispatchQueue.main.async {
                guard let self else { return }
                self.timeline = tl
                self.recompute(AlertKind.allCases)
            }
        }
    }

    /// How a rule that is not saved yet (one the user is trying, or one the agent proposes) would have done.
    func preview(_ rule: AlertRule) -> AlertReplay.Result? {
        timeline.map { AlertReplay.run(rule, over: $0) }
    }

    private func recompute(_ kinds: [AlertKind]) {
        guard let tl = timeline else { return }
        replayGeneration += 1
        let wanted = rules.filter { kinds.contains($0.kind) }
        io.async { [weak self] in
            var out: [AlertKind: AlertReplay.Result] = [:]
            for r in wanted { out[r.kind] = AlertReplay.run(r, over: tl) }
            DispatchQueue.main.async {
                guard let self else { return }
                // A rule changed again while this ran: its newer result is on the way.
                for (kind, result) in out where self.rules.first(where: { $0.kind == kind }) == wanted.first(where: { $0.kind == kind }) {
                    self.replay[kind] = result
                }
                self.replayLoaded = true
            }
        }
    }

    // MARK: Notifications

    private func notify(_ a: Alert, quiet: Bool = false) {
        guard a.level == .issue ? settings.notifyIssues : settings.notifyRisks else { return }
        // Notifications need a bundle; a bare development binary has none.
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        let post = {
            let content = UNMutableNotificationContent()
            content.title = "\(a.level.title): \(a.title)"
            content.body = a.finding.map { "\(a.what) \($0)" } ?? "\(a.what) \(a.todo)"
            content.userInfo = ["opened": NSNumber(value: a.opened)]
            if !quiet { content.sound = a.level == .issue ? .default : nil }
            // The same identifier replaces the earlier notification, so a finding updates it in place.
            center.add(UNNotificationRequest(identifier: "alert-\(a.key)-\(a.opened)", content: content, trigger: nil))
        }
        if askedForNotifications { post(); return }
        askedForNotifications = true
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in if granted { post() } }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let opened = (response.notification.request.content.userInfo["opened"] as? NSNumber)?.int64Value
        DispatchQueue.main.async { [weak self] in if let opened { self?.onShow?(opened) } }
        completionHandler()
    }

    // MARK: The AI agent

    /// Asks the agent what caused an issue and attaches its answer to the alert.
    private func investigate(_ key: String) {
        guard agent.isOn, settings.aiInvestigate, let store else { return }
        let day = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        var used = defaults.integer(forKey: "aiInvestigationsUsed")
        if defaults.double(forKey: "aiInvestigationsDay") != day { used = 0; defaults.set(day, forKey: "aiInvestigationsDay") }
        guard used < AlertCenter.maxInvestigationsPerDay else {
            FileLog.shared.log("ai: today's \(AlertCenter.maxInvestigationsPerDay) investigations are used up; not looking into \(key)")
            return
        }
        defaults.set(used + 1, forKey: "aiInvestigationsUsed")
        investigating.insert(key)
        // A short wait lets the readings from the moment it opened reach the database.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, let alert = self.engine.open[key] else { self?.investigating.remove(key); return }
            let others = self.engine.open.values.filter { $0.key != key }
            let now = Date().msSince1970
            self.io.async {
                let h = store.load(from: alert.opened - 2 * 3600_000, to: now, maxPoints: 26)
                let prompt = AlertAI.investigatePrompt(evidence: AlertAI.evidence(for: alert, history: h, others: Array(others)))
                self.agent.run(prompt) { result in
                    self.investigating.remove(key)
                    guard case .success(let reply) = result, let text = AlertAI.finding(from: reply), var a = self.engine.open[key] else { return }
                    let at = Date().msSince1970
                    self.engine.setFinding(text, at: at, for: key)
                    a.finding = text; a.findingAt = at
                    self.io.async { var b = a; b.id = self.ids[key] ?? 0; store.updateAlert(b) }
                    self.publish()
                    self.notify(a, quiet: true)
                    FileLog.shared.log("ai: looked into \(a.title)")
                }
            }
        }
    }

    enum RuleDraft: Equatable {
        case rule(AlertRule)
        case failed(String)
    }

    /// Turns "tell me if a VM uses more than 80% CPU for 5 minutes" into a rule for the user to check and accept.
    func makeRule(from request: String, completion: @escaping (RuleDraft) -> Void) {
        agent.run(AlertAI.rulePrompt(request: request, current: rules)) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let f): completion(.failed(f.message))
            case .success(let reply):
                switch AlertAI.rule(from: reply, current: self.rules) {
                case .rule(let r): completion(.rule(r))
                case .cannot(let why): completion(.failed(why))
                }
            }
        }
    }

    /// Once a week, asks the agent whether any rule cries wolf.
    func suggestIfDue(force: Bool = false) {
        guard agent.isOn, settings.aiSuggest || force, let store else { return }
        let last = defaults.double(forKey: "aiSuggestedAt")
        guard force || Date().timeIntervalSince1970 - last > 7 * 86_400 else { return }
        defaults.set(Date().timeIntervalSince1970, forKey: "aiSuggestedAt")
        let rules = self.rules
        let now = Date().msSince1970
        io.async { [weak self] in
            let tl = AlertReplay.timeline(store.load(from: now - 7 * 86_400_000, to: now, maxPoints: 10_080))
            var results: [AlertKind: AlertReplay.Result] = [:]
            for r in rules where r.enabled { results[r.kind] = AlertReplay.run(r, over: tl) }
            // Nothing alerted three times: nothing to tune, and no reason to spend a request.
            guard results.values.contains(where: { $0.count >= 3 }) else { return }
            self?.agent.run(AlertAI.tunePrompt(rules: rules, results: results)) { result in
                guard let self, case .success(let reply) = result else { return }
                self.suggestions = AlertAI.suggestions(from: reply, current: self.rules)
                self.saveSuggestions()
                FileLog.shared.log("ai: \(self.suggestions.count) suggestion(s) for the rules")
            }
        }
    }

    func dismiss(_ suggestion: AlertAI.Suggestion) {
        suggestions.removeAll { $0 == suggestion }
        saveSuggestions()
    }

    private func saveSuggestions() {
        defaults.set(try? JSONEncoder().encode(suggestions), forKey: "alertSuggestions")
    }

    // MARK: Debug aid

    /// `--demo-alerts`: example alerts in place of the real ones, for pictures of every surface. Nothing is stored or sent.
    func showDemo() {
        demo = true
        let now = Date().msSince1970
        var stop = Alert(rule: "vm_stopped", level: .issue, subject: "demo-b", vmKey: "demo-b", title: "macOS 26 B stopped",
                         what: "It was running and stopped at 14:02 without starting again. This Mac's disk had 1.2 GB free at that moment.",
                         todo: "Start it in UTM. If you stopped it yourself, say so and this alert goes away.", opened: now - 6 * 60_000)
        stop.finding = "The VM wrote 24 GB between 12:00 and 14:00 while this Mac went from 31 GB to 1.2 GB free. It stopped three minutes after the Mac's disk filled, with memory and network normal, so the full disk is the likely cause. Free space on this Mac first; the other VM will hit the same wall."
        stop.findingAt = now - 5 * 60_000
        let full = Alert(rule: "mac_disk_full", level: .issue, subject: "host", vmKey: nil, title: "This Mac's disk is full",
                         what: "1.2 GB free of 926 GB. VM disk images grow as the guests write; when they cannot grow, VMs pause or fail.",
                         todo: "Free space on this Mac now, then check that the VMs are still running.", opened: now - 9 * 60_000)
        let disk = Alert(rule: "vm_disk", level: .risk, subject: "demo-a", vmKey: "demo-a", title: "macOS 26 disk 92% full",
                         what: "58.9 of 64.0 GB used inside the VM. At the pace of the last hours it is full in about 3 days.",
                         todo: "Free space inside the VM, or make its disk larger in UTM.", opened: now - 22 * 3600_000)
        open = [stop, full, disk]
        func ended(_ rule: String, _ level: AlertLevel, _ title: String, _ what: String, ago: Int64, lasted: Int64) -> Alert {
            var a = Alert(rule: rule, level: level, subject: "host", vmKey: nil, title: title, what: what, todo: "", opened: now - ago * 60_000)
            a.closed = a.opened + lasted * 60_000
            return a
        }
        past = [ended("memory", .risk, "Memory is short", "Memory pressure stayed at Warning.", ago: 300, lasted: 36),
                ended("network_down", .issue, "Network is down", "This Mac had no network connection.", ago: 690, lasted: 1),
                ended("memory", .risk, "Memory is short", "Memory pressure stayed at Warning.", ago: 2600, lasted: 70),
                ended("vm_frozen", .issue, "macOS 26 2 is not responding", "It was running but did not answer pings.", ago: 4700, lasted: 3),
                ended("wifi", .risk, "Wi-Fi signal is weak", "The signal was at −78 dBm.", ago: 6000, lasted: 12)]
        if let memory = rules.first(where: { $0.kind == .memory }) {
            suggestions = [AlertAI.Suggestion(kind: .memory, rule: memory.stepped(minutes: 1),
                                              reason: "Most of this rule's alerts last week ended within a few minutes and nothing went wrong afterwards. Waiting 15 minutes would have kept only the long ones.")]
        }
    }
}
