import CryptoKit
import Foundation
import UTMWatchCore
import UTMWatchStore

/// Sends pushes to the user's Bark server. The device key comes from the keys file.
/// A push that could not be delivered because nothing answered waits and is tried again, so an alert raised while
/// the network was down still reaches the phone once it is back. Main thread only, except where noted.
final class BarkSender {
    static let account = "bark"
    /// Set by a debug flag that points this run at another server: the saved key is then never read or sent there.
    static var redirected = false

    /// The device key as saved.
    static func savedKey() -> String {
        // Debug aid: `UTMWATCH_BARK_KEY` supplies the key for one run, so a trial copy needs nothing saved.
        if let trial = ProcessInfo.processInfo.environment["UTMWATCH_BARK_KEY"] { return trial }
        return redirected ? "" : (KeysFile.get(account) ?? "")
    }

    /// An id for the phone that says nothing about the Mac: the alert's own key holds a VM's file path.
    static func pushID(alertKey: String, opened: Int64, suffix: String = "") -> String {
        let digest = SHA256.hash(data: Data("\(alertKey)|\(opened)".utf8))
        return "utmwatch-" + digest.prefix(8).map { String(format: "%02x", $0) }.joined() + suffix
    }

    private struct Waiting {
        var message: BarkPush.Message
        var since: Date
    }
    private var waiting: [Waiting] = []
    private var timer: Timer?
    private let settings: AppSettings
    private static let keepFor: TimeInterval = 6 * 3600
    private static let most = 20

    init(settings: AppSettings) { self.settings = settings }

    /// Sends now; if nothing answers, keeps it and tries again every minute for up to six hours.
    func push(_ message: BarkPush.Message) {
        // A newer push for the same alert takes the place of one still waiting.
        if let id = message.id { waiting.removeAll { $0.message.id == id } }
        attempt(Waiting(message: message, since: Date()))
    }

    private func attempt(_ item: Waiting) {
        BarkSender.send(item.message, server: settings.barkServer) { [weak self] failure, retry in
            guard let self else { return }
            guard let failure else { FileLog.shared.log("bark: pushed \(item.message.title)"); return }
            guard retry else { FileLog.shared.log("bark: push refused, not sent again: \(failure)"); return }
            FileLog.shared.log("bark: push not delivered, will try again: \(failure)")
            self.waiting.removeAll { $0.message.id != nil && $0.message.id == item.message.id }
            self.waiting.append(item)
            if self.waiting.count > BarkSender.most { self.waiting.removeFirst(self.waiting.count - BarkSender.most) }
            self.startTimer()
        }
    }

    private func startTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.retry() }
        t.tolerance = 10
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func retry() {
        let due = waiting.filter { Date().timeIntervalSince($0.since) < BarkSender.keepFor }
        waiting = []
        if due.isEmpty || !settings.barkOn { timer?.invalidate(); timer = nil; return }
        for item in due { attempt(item) }
    }

    /// One attempt. Calls back on the main thread: nil when the server took the push; otherwise why not, and whether
    /// trying again later could help. `key` nil means the saved one.
    static func send(_ message: BarkPush.Message, server: String, key: String? = nil, completion: @escaping (String?, Bool) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let key = key ?? savedKey()
            func done(_ failure: String?, _ retry: Bool) { DispatchQueue.main.async { completion(failure, retry) } }
            guard !key.isEmpty else { return done("No device key is saved.", false) }
            guard let r = BarkPush.request(server: server, key: key, message: message) else { return done("The server address is not a web address.", false) }
            var request = URLRequest(url: r.url)
            request.httpMethod = "POST"
            request.timeoutInterval = 30
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = r.body
            URLSession.shared.dataTask(with: request) { data, response, error in
                if let error { return done(error.localizedDescription, true) }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                done(BarkPush.failure(status: status, body: data), BarkPush.worthRetrying(status: status))
            }.resume()
        }
    }
}
