import AppKit
import CryptoKit
import Foundation
import UTMWatchCore

/// Looks for a newer release on GitHub and, on one click, replaces this app with it and restarts.
final class Updater: ObservableObject {
    enum State: Equatable {
        case idle
        case available(String)
        case updating(String)
    }

    @Published private(set) var state: State = .idle

    private static let latestURL = URL(string: "https://api.github.com/repos/DarrickBM/utm-watch/releases/latest")!
    /// "Latest" leaves pre-releases out, so the beta channel reads the list of recent releases instead.
    private static let listURL = URL(string: "https://api.github.com/repos/DarrickBM/utm-watch/releases?per_page=30")!
    private let settings: AppSettings
    private var release: ReleaseInfo?
    private var timer: Timer?

    init(settings: AppSettings) { self.settings = settings }

    /// Nil when not running from an app bundle (a development run), which turns updating off.
    /// UTMWATCH_PRETEND_VERSION lets the whole path be tested against the real latest release.
    var currentVersion: String? {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        return ProcessInfo.processInfo.environment["UTMWATCH_PRETEND_VERSION"]
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    /// The beta number of this copy, nil for a final release. UTMWATCH_PRETEND_BETA overrides it for testing.
    var currentBeta: Int? {
        if let pretend = ProcessInfo.processInfo.environment["UTMWATCH_PRETEND_BETA"] { return Int(pretend).flatMap { $0 > 0 ? $0 : nil } }
        return AppSettings.buildBeta
    }

    /// The version as shown to the user: "0.6.0" or "0.6.0 beta 5".
    var currentLabel: String? { currentVersion.map { AppVersion.label($0, beta: currentBeta) } }

    /// Checks shortly after launch and then once a day, while the setting is on.
    func start() {
        let t = Timer(timeInterval: 24 * 3600, repeats: true) { [weak self] _ in self?.automaticCheck() }
        t.tolerance = 600
        RunLoop.main.add(t, forMode: .common)
        timer = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.automaticCheck() }
    }

    private func automaticCheck() {
        guard settings.checkForUpdates else { return }
        check { _ in }
    }

    enum CheckResult { case upToDate(String), available(String), failed(String), unavailable }

    /// Asks GitHub for the latest release, or on the beta channel for the newest release of either kind.
    /// The request carries nothing about this Mac or its VMs.
    func check(completion: @escaping (CheckResult) -> Void) {
        guard let current = currentVersion, let currentLabel else { completion(.unavailable); return }
        if case .updating = state { return }
        let currentBeta = currentBeta, betas = settings.betaUpdates
        var request = URLRequest(url: betas ? Self.listURL : Self.latestURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("UTMWatch", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            let found = ok ? data.flatMap { betas ? ReleaseInfo.newest(inList: $0, includeBetas: true) : ReleaseInfo.parse($0) } : nil
            DispatchQueue.main.async {
                guard let self else { return }
                guard let found else {
                    let why = error?.localizedDescription ?? "GitHub did not return a usable release."
                    FileLog.shared.log("update check failed: \(why)")
                    completion(.failed(why))
                    return
                }
                let channel = betas ? "beta channel" : "release channel"
                if AppVersion.isNewer(found.version, beta: found.beta, than: current, beta: currentBeta) {
                    self.release = found
                    if case .updating = self.state {} else { self.state = .available(found.label) }
                    FileLog.shared.log("update available: \(found.label) (running \(currentLabel), \(channel))")
                    completion(.available(found.label))
                } else {
                    self.release = nil
                    if case .updating = self.state {} else { self.state = .idle }
                    FileLog.shared.log("update check: \(currentLabel) is current (newest \(found.label), \(channel))")
                    completion(.upToDate(currentLabel))
                }
            }
        }.resume()
    }

    /// The menu's "Check for Updates…": always answers, in a dialog.
    func checkManually() {
        check { [weak self] result in
            let alert = NSAlert()
            switch result {
            case .available(let v):
                alert.messageText = "UTM Watch \(v) is available"
                alert.informativeText = "Updating downloads the new version, replaces this copy and restarts UTM Watch. Your recorded history is kept."
                alert.addButton(withTitle: "Update")
                alert.addButton(withTitle: "Later")
            case .upToDate(let v):
                alert.messageText = "UTM Watch is up to date"
                alert.informativeText = "Version \(v) is the newest."
            case .failed(let why):
                alert.messageText = "Could not check for updates"
                alert.informativeText = why
            case .unavailable:
                alert.messageText = "Updates are not available for this copy"
                alert.informativeText = "This copy of UTM Watch is not running from an app bundle."
            }
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn, case .available = result { self?.install() }
        }
    }

    /// One click: download, verify, replace this app, restart.
    func install() {
        guard case .available(let version) = state, let release else { return }
        state = .updating(version)
        FileLog.shared.log("update: installing \(version)")
        let destination = Bundle.main.bundleURL
        let bundleID = Bundle.main.bundleIdentifier
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try Self.replace(appAt: destination, bundleID: bundleID, with: release)
                DispatchQueue.main.async { Self.relaunch(destination) }
            } catch {
                let why = (error as? UpdateError)?.message ?? error.localizedDescription
                FileLog.shared.log("update failed: \(why)")
                DispatchQueue.main.async {
                    self?.state = .available(version)
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = "The update could not be installed"
                    alert.informativeText = "\(why)\n\nUTM Watch \(self?.currentLabel ?? "") keeps running. You can also download the new version from the project's releases page."
                    NSApp.activate(ignoringOtherApps: true)
                    alert.runModal()
                }
            }
        }
    }

    private struct UpdateError: Error { var message: String }

    private static func replace(appAt destination: URL, bundleID: String?, with release: ReleaseInfo) throws {
        let fm = FileManager.default
        guard fm.isWritableFile(atPath: destination.deletingLastPathComponent().path) else {
            throw UpdateError(message: "UTM Watch cannot write to \(destination.deletingLastPathComponent().path).")
        }
        // The work folder sits beside the app so the final swap stays on one volume.
        let work = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true)
        defer { try? fm.removeItem(at: work) }

        let zip: Data, listing: String
        do {
            zip = try Data(contentsOf: release.appZip)
            listing = String(decoding: try Data(contentsOf: release.checksums), as: UTF8.self)
        } catch { throw UpdateError(message: "The download failed: \(error.localizedDescription)") }

        // The file must be the one the release lists, byte for byte.
        let digest = SHA256.hash(data: zip).map { String(format: "%02x", $0) }.joined()
        guard let expected = ReleaseInfo.checksum(for: release.appZip.lastPathComponent, in: listing), expected == digest else {
            throw UpdateError(message: "The download does not match the checksum published with the release.")
        }

        let zipFile = work.appendingPathComponent("app.zip"), unpacked = work.appendingPathComponent("app")
        try zip.write(to: zipFile)
        try run("/usr/bin/ditto", ["-x", "-k", zipFile.path, unpacked.path])
        let fresh = unpacked.appendingPathComponent("UTMWatch.app")
        guard let info = NSDictionary(contentsOf: fresh.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == bundleID,
              info["CFBundleShortVersionString"] as? String == release.version,
              AppSettings.beta(in: info as? [String: Any]) == release.beta else {
            throw UpdateError(message: "The download is not UTM Watch \(release.label).")
        }
        try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", fresh.path])
        do {
            _ = try fm.replaceItemAt(destination, withItemAt: fresh)
        } catch { throw UpdateError(message: "The app could not be replaced: \(error.localizedDescription)") }
    }

    private static func run(_ tool: String, _ arguments: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = arguments
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 { throw UpdateError(message: "\(URL(fileURLWithPath: tool).lastPathComponent) failed while unpacking the update.") }
    }

    /// Starts the new copy once this one has gone, then quits (which saves the last few seconds of history).
    private static func relaunch(_ app: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \"$0\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$1\"",
                       String(ProcessInfo.processInfo.processIdentifier), app.path]
        // The helper must not inherit the test override, or the new copy would offer the update again.
        var env = ProcessInfo.processInfo.environment
        env["UTMWATCH_PRETEND_VERSION"] = nil
        env["UTMWATCH_PRETEND_BETA"] = nil
        p.environment = env
        do { try p.run() } catch { FileLog.shared.log("update: could not schedule the restart: \(error)") }
        FileLog.shared.log("update: installed, restarting")
        NSApp.terminate(nil)
    }
}
