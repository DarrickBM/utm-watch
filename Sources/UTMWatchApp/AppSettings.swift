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
    @Published var launchAtLogin: Bool
    @Published var launchAtLoginError: String?

    init() {
        defaults.register(defaults: ["sampleInterval": 2, "rateUnits": RateUnits.bytes.rawValue, "retentionDays": 7,
                                     "allowAgents": true, "captureProcesses": true])
        let interval = defaults.integer(forKey: "sampleInterval")
        sampleInterval = [1, 2, 5].contains(interval) ? interval : 2
        rateUnits = RateUnits(rawValue: defaults.string(forKey: "rateUnits") ?? "") ?? .bytes
        let days = defaults.integer(forKey: "retentionDays")
        retentionDays = [1, 7, 30].contains(days) ? days : 7
        allowAgents = defaults.bool(forKey: "allowAgents")
        captureProcesses = defaults.bool(forKey: "captureProcesses")
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
