import Foundation
import ServiceManagement
import UTMWatchCore
import UTMWatchStore

/// User preferences, persisted in UserDefaults.
final class AppSettings: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var sampleInterval: Int { didSet { defaults.set(sampleInterval, forKey: "sampleInterval") } }
    @Published var rateUnits: RateUnits { didSet { defaults.set(rateUnits.rawValue, forKey: "rateUnits") } }
    @Published var retentionDays: Int { didSet { defaults.set(retentionDays, forKey: "retentionDays") } }
    /// The MCP helper reads this from the app's defaults and refuses to serve when it is off.
    @Published var allowAgents: Bool { didSet { defaults.set(allowAgents, forKey: "allowAgents") } }
    @Published var captureProcesses: Bool { didSet { defaults.set(captureProcesses, forKey: "captureProcesses") } }
    /// Names the user gave VMs in the detail window, by VM key. A VM without an entry shows its UTM name.
    @Published var vmAliases: [String: String] { didSet { defaults.set(vmAliases, forKey: "vmAliases") } }
    /// Off hides VMs that do not belong to UTM (Docker Desktop, Tart, ...) from every view. They are still recorded.
    @Published var showOtherVMs: Bool { didSet { defaults.set(showOtherVMs, forKey: "showOtherVMs") } }
    /// Tracks the detail window leaves out, by `TrackKind` raw value. They are still recorded.
    @Published var hiddenTracks: Set<String> { didSet { defaults.set(Array(hiddenTracks).sorted(), forKey: "hiddenTracks") } }
    @Published var checkForUpdates: Bool { didSet { defaults.set(checkForUpdates, forKey: "checkForUpdates") } }
    /// Updates include betas. Unless set by hand, a beta build follows the betas and a final release does not, so a
    /// Mac on a beta moves to each next beta and then to the final release, and stays on releases from there.
    var betaUpdates: Bool { defaults.object(forKey: "betaUpdates") as? Bool ?? (AppSettings.buildBeta != nil) }

    /// The beta number this copy was built as (Info.plist "UTMWatchBeta"); nil for a final release.
    static let buildBeta: Int? = beta(in: Bundle.main.infoDictionary)

    static func beta(in info: [String: Any]?) -> Int? {
        let n = (info?["UTMWatchBeta"] as? Int) ?? (info?["UTMWatchBeta"] as? String).flatMap { Int($0) }
        return n.flatMap { $0 > 0 ? $0 : nil }
    }
    /// Fleet: this Mac runs the hub the other Macs report to.
    @Published var hostHub: Bool { didSet { defaults.set(hostHub, forKey: "hostHub") } }
    @Published var hubPort: Int { didSet { defaults.set(hubPort, forKey: "hubPort") } }
    /// Fleet: stay in the fleet but stop sending this Mac's VMs for now.
    @Published var fleetReportingPaused: Bool { didSet { defaults.set(fleetReportingPaused, forKey: "fleetReportingPaused") } }
    /// Fleet: show a notification when another Mac has trouble or stops reporting.
    @Published var fleetAlerts: Bool { didSet { defaults.set(fleetAlerts, forKey: "fleetAlerts") } }
    /// Alerts: a macOS notification when an issue, or a risk, opens.
    @Published var notifyIssues: Bool { didSet { defaults.set(notifyIssues, forKey: "notifyIssues") } }
    @Published var notifyRisks: Bool { didSet { defaults.set(notifyRisks, forKey: "notifyRisks") } }
    /// Alerts: where the AI agent runs. "off", "cli" (Claude Code or another command on this Mac) or "key" (an API key).
    @Published var aiBackend: String { didSet { if overridesPersist { defaults.set(aiBackend, forKey: "aiBackend") } } }
    /// False while a debug flag overrides a choice for one run: the override must never become the saved setting.
    var overridesPersist = true
    /// A command to run instead of Claude Code; it gets the prompt on standard input and answers on standard output.
    @Published var aiCommand: String { didSet { if overridesPersist { defaults.set(aiCommand, forKey: "aiCommand") } } }
    /// "anthropic", a named service ("deepseek", "kimi", "qwen", "glm", "openai") or "custom" (an address the user gives:
    /// any server that speaks the OpenAI chat API, including one on this Mac).
    @Published var aiProvider: String { didSet { if overridesPersist { defaults.set(aiProvider, forKey: "aiProvider") } } }
    /// The model last used with each provider, so switching provider and back keeps what was typed.
    @Published var aiModels: [String: String] { didSet { if overridesPersist { defaults.set(aiModels, forKey: "aiModels") } } }
    @Published var aiModel: String { didSet { if overridesPersist { defaults.set(aiModel, forKey: "aiModel") } } }
    @Published var aiBaseURL: String { didSet { if overridesPersist { defaults.set(aiBaseURL, forKey: "aiBaseURL") } } }
    @Published var aiInvestigate: Bool { didSet { defaults.set(aiInvestigate, forKey: "aiInvestigate") } }
    @Published var aiSuggest: Bool { didSet { defaults.set(aiSuggest, forKey: "aiSuggest") } }
    /// Alerts: also push them to an iPhone through Bark. The device key is in the keys file.
    @Published var barkOn: Bool { didSet { if overridesPersist { defaults.set(barkOn, forKey: "barkOn") } } }
    @Published var barkServer: String { didSet { if overridesPersist { defaults.set(barkServer, forKey: "barkServer") } } }
    /// Issues are sent as time-sensitive, so they show while a Focus is on.
    @Published var barkUrgentIssues: Bool { didSet { defaults.set(barkUrgentIssues, forKey: "barkUrgentIssues") } }
    /// One more push when an alert ends.
    @Published var barkEnded: Bool { didSet { defaults.set(barkEnded, forKey: "barkEnded") } }
    /// The push is updated with the AI agent's finding once it is ready.
    @Published var barkFinding: Bool { didSet { defaults.set(barkFinding, forKey: "barkFinding") } }
    @Published var launchAtLogin: Bool
    @Published var launchAtLoginError: String?

    init() {
        defaults.register(defaults: ["sampleInterval": 2, "rateUnits": RateUnits.bytes.rawValue, "retentionDays": 7,
                                     "allowAgents": true, "captureProcesses": true, "checkForUpdates": true, "showOtherVMs": true,
                                     "hubPort": 8787, "fleetAlerts": true, "hiddenTracks": [TrackKind.swap.rawValue],
                                     "notifyIssues": true, "notifyRisks": true, "aiBackend": "off", "aiProvider": "anthropic",
                                     "aiModel": "claude-haiku-5-5", "aiBaseURL": "https://api.deepseek.com", "aiInvestigate": true, "aiSuggest": true,
                                     "barkOn": false, "barkServer": BarkPush.defaultServer, "barkUrgentIssues": true, "barkEnded": false, "barkFinding": true])
        let interval = defaults.integer(forKey: "sampleInterval")
        sampleInterval = [1, 2, 5].contains(interval) ? interval : 2
        rateUnits = RateUnits(rawValue: defaults.string(forKey: "rateUnits") ?? "") ?? .bytes
        let days = defaults.integer(forKey: "retentionDays")
        retentionDays = [1, 7, 30].contains(days) ? days : 7
        allowAgents = defaults.bool(forKey: "allowAgents")
        captureProcesses = defaults.bool(forKey: "captureProcesses")
        vmAliases = defaults.dictionary(forKey: "vmAliases") as? [String: String] ?? [:]
        checkForUpdates = defaults.bool(forKey: "checkForUpdates")
        showOtherVMs = defaults.bool(forKey: "showOtherVMs")
        hiddenTracks = Set(defaults.stringArray(forKey: "hiddenTracks") ?? [])
        hostHub = defaults.bool(forKey: "hostHub")
        let port = defaults.integer(forKey: "hubPort")
        hubPort = (1024...65535).contains(port) ? port : 8787
        fleetReportingPaused = defaults.bool(forKey: "fleetReportingPaused")
        fleetAlerts = defaults.bool(forKey: "fleetAlerts")
        notifyIssues = defaults.bool(forKey: "notifyIssues")
        notifyRisks = defaults.bool(forKey: "notifyRisks")
        let backend = defaults.string(forKey: "aiBackend") ?? "off"
        aiBackend = ["off", "cli", "key"].contains(backend) ? backend : "off"
        aiCommand = defaults.string(forKey: "aiCommand") ?? ""
        // Before services were offered by name, "openai" meant any address the user gave. Such a setting becomes the
        // named service whose address it holds, or a custom endpoint.
        var provider = defaults.string(forKey: "aiProvider") ?? AIAgent.anthropic
        if !defaults.bool(forKey: "aiProviderNamed") {
            if provider == "openai" {
                let host = AIPreset.host(of: defaults.string(forKey: "aiBaseURL") ?? "")
                provider = AIAgent.providers.first { AIPreset.host(of: $0.address) == host }?.id ?? AIAgent.custom
                defaults.set(provider, forKey: "aiProvider")
            }
            defaults.set(true, forKey: "aiProviderNamed")
        }
        aiProvider = AIAgent.providerIDs.contains(provider) ? provider : AIAgent.anthropic
        aiModels = defaults.dictionary(forKey: "aiModels") as? [String: String] ?? [:]
        aiModel = defaults.string(forKey: "aiModel") ?? "claude-haiku-5-5"
        aiBaseURL = defaults.string(forKey: "aiBaseURL") ?? "https://api.deepseek.com"
        aiInvestigate = defaults.bool(forKey: "aiInvestigate")
        aiSuggest = defaults.bool(forKey: "aiSuggest")
        barkOn = defaults.bool(forKey: "barkOn")
        barkServer = defaults.string(forKey: "barkServer") ?? BarkPush.defaultServer
        barkUrgentIssues = defaults.bool(forKey: "barkUrgentIssues")
        barkEnded = defaults.bool(forKey: "barkEnded")
        barkFinding = defaults.bool(forKey: "barkFinding")
        launchAtLogin = SMAppService.mainApp.status == .enabled
        // Written explicitly so the helper, a separate process, sees the value even before it is ever toggled.
        defaults.set(allowAgents, forKey: "allowAgents")
    }

    /// Registers or unregisters the app as a login item; the switch always reflects what macOS reports.
    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
            FileLog.shared.log("launch at login change failed: \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
