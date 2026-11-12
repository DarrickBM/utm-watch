import Foundation
import ServiceManagement
import UTMWatchCore

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
    @Published var launchAtLogin: Bool
    @Published var launchAtLoginError: String?

    init() {
        defaults.register(defaults: ["sampleInterval": 2, "rateUnits": RateUnits.bytes.rawValue, "retentionDays": 7,
                                     "allowAgents": true, "captureProcesses": true, "checkForUpdates": true, "showOtherVMs": true,
                                     "hubPort": 8787, "fleetAlerts": true])
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
        hostHub = defaults.bool(forKey: "hostHub")
        let port = defaults.integer(forKey: "hubPort")
        hubPort = (1024...65535).contains(port) ? port : 8787
        fleetReportingPaused = defaults.bool(forKey: "fleetReportingPaused")
        fleetAlerts = defaults.bool(forKey: "fleetAlerts")
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
