import Foundation
import UTMWatchCore
import UTMWatchStore

/// Runs a prompt through the AI agent the user chose: Claude Code (or another command) on this Mac, or a model
/// reached with their own API key. The agent gets words in and gives words back; it is handed no tools.
final class AIAgent {
    struct Failure: Error, Equatable {
        var message: String
        /// True when the agent is there but needs the user to sign in.
        var needsSignIn = false
    }

    private let settings: AppSettings
    private let queue = DispatchQueue(label: "utmwatch.ai", qos: .utility)

    init(settings: AppSettings) { self.settings = settings }

    var isOn: Bool { settings.aiBackend != "off" }

    /// Runs off the main thread and calls back on it.
    func run(_ prompt: String, completion: @escaping (Result<String, Failure>) -> Void) {
        let backend = settings.aiBackend, command = settings.aiCommand, provider = settings.aiProvider
        let model = settings.aiModel, base = AIAgent.address(provider: provider, custom: settings.aiBaseURL)
        queue.async {
            let result: Result<String, Failure>
            switch backend {
            case "cli": result = AIAgent.runCommand(prompt, custom: command)
            case "key": result = AIAgent.runAPI(prompt, provider: provider, model: model, baseURL: base)
            default: result = .failure(Failure(message: "No AI agent is chosen."))
            }
            if case .failure(let f) = result { FileLog.shared.log("ai: \(backend) failed: \(f.message)") }
            DispatchQueue.main.async { completion(result) }
        }
    }

    // MARK: Claude Code, or another command

    /// Where Claude Code is installed, looking in the places its installers use.
    static func findClaude() -> String? {
        let home = NSHomeDirectory()
        let places = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                      "\(home)/.npm-global/bin/claude", "\(home)/.bun/bin/claude", "\(home)/.volta/bin/claude"]
        return places.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func runCommand(_ prompt: String, custom: String) -> Result<String, Failure> {
        let custom = custom.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty {
            let r = launch("/bin/zsh", ["-lc", custom], input: prompt)
            return r.status == 0 && !r.out.isEmpty ? .success(r.out) : .failure(Failure(message: r.timedOut ? "The command did not answer within 3 minutes." : "The command failed: \(brief(r.err.isEmpty ? r.out : r.err))"))
        }
        guard let claude = findClaude() else {
            return .failure(Failure(message: "Claude Code is not installed on this Mac."))
        }
        // No tools and no other MCP servers: everything the agent may use is in the prompt.
        var r = launch(claude, ["-p", "--output-format", "text", "--tools", "", "--strict-mcp-config", "--no-session-persistence"], input: prompt)
        if r.status != 0, r.err.contains("unknown option") {
            r = launch(claude, ["-p"], input: prompt) // an older Claude Code without those switches
        }
        let said = (r.out + " " + r.err).lowercased()
        if r.status != 0, said.contains("/login") || said.contains("not logged in") || said.contains("invalid api key") || said.contains("authentication") {
            return .failure(Failure(message: "Claude Code is installed but not signed in.", needsSignIn: true))
        }
        if r.timedOut { return .failure(Failure(message: "Claude Code did not answer within 3 minutes.")) }
        guard r.status == 0, !r.out.isEmpty else { return .failure(Failure(message: "Claude Code failed: \(brief(r.err.isEmpty ? r.out : r.err))")) }
        return .success(r.out)
    }

    private static func brief(_ s: String) -> String {
        let line = s.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isNewline).last.map(String.init) ?? "no output"
        return String(line.prefix(200))
    }

    private static func launch(_ path: String, _ args: [String], input: String, timeout: TimeInterval = 180) -> (status: Int32, out: String, err: String, timedOut: Bool) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        // An app started from the Finder has a bare PATH; a script-installed agent needs its interpreter.
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        env["PATH"] = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", env["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
        p.environment = env
        // An empty folder of its own: nothing of the user's is in reach, whatever the agent is.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("utmwatch-ai", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        p.currentDirectoryURL = dir
        let stdin = Pipe(), out = Pipe(), err = Pipe()
        p.standardInput = stdin; p.standardOutput = out; p.standardError = err
        do { try p.run() } catch { return (-1, "", "\(error.localizedDescription)", false) }
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        group.enter(); DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter(); DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        DispatchQueue.global().async {
            try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
            try? stdin.fileHandleForWriting.close()
        }
        var timedOut = false
        if group.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            p.terminate()
            _ = group.wait(timeout: .now() + 2)
            // A process that ignores the polite request is stopped outright: one stuck agent must not hold up the next request.
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: outData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                String(decoding: errData, as: UTF8.self), timedOut)
    }

    /// Opens Terminal with Claude Code running, where the user signs in once.
    static func openClaudeInTerminal() {
        guard let claude = findClaude() else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", "Terminal", claude]
        try? p.run()
    }

    // MARK: An API key

    /// A service with a chat-completions API that the Address field can be filled in for with one click.
    struct Preset: Identifiable {
        let id: String
        let name: String
        let address: String
        /// A model name the service's own documentation uses; empty where there is no safe default.
        let model: String
    }

    /// Services offered by name in the Provider choice. Each speaks the OpenAI-style chat-completions API at an
    /// address of its own; the user gives only a key and a model. Addresses and model names are as the services'
    /// documentation gave them in November 2026; accounts outside mainland China may need a service's international
    /// address, which goes under "Custom endpoint".
    static let providers: [Preset] = [
        Preset(id: "deepseek", name: "DeepSeek", address: "https://api.deepseek.com", model: "deepseek-flash"),
        Preset(id: "kimi", name: "Kimi", address: "https://api.moonshot.cn/v1", model: "kimi-k3.1-pro"),
        Preset(id: "qwen", name: "Qwen", address: "https://dashscope.aliyuncs.com/compatible-mode/v1", model: "qwen3.7-plus"),
        Preset(id: "glm", name: "GLM", address: "https://open.bigmodel.cn/api/paas/v4", model: "glm-5.3"),
        Preset(id: "openai", name: "OpenAI", address: "https://api.openai.com/v1", model: ""),
    ]

    /// The one address built into "Custom endpoint"; the rest there are the user's own saved presets.
    static let presets: [Preset] = [
        Preset(id: "local", name: "On this Mac", address: "http://localhost:11434/v1", model: "qwen3:8b"),
    ]

    static let anthropic = "anthropic", custom = "custom"
    static var providerIDs: [String] { [anthropic] + providers.map(\.id) + [custom] }

    /// The address a provider is reached at: its own for a named one, what the user typed for a custom endpoint.
    static func address(provider: String, custom typed: String) -> String {
        providers.first { $0.id == provider }?.address ?? typed
    }

    /// The model a provider starts with when the user has not chosen one for it.
    static func defaultModel(provider: String, custom typed: String) -> String {
        if provider == anthropic { return "claude-haiku-5-5" }
        if let named = providers.first(where: { $0.id == provider }) { return named.model }
        return presets.first { chatURL(from: $0.address) == chatURL(from: typed) }?.model ?? ""
    }

    /// The name a key is kept under in the keys file. Each custom endpoint has a key of its own, by host, so a key entered for
    /// one service is never sent to another when the address changes.
    static func keyAccount(provider: String, baseURL: String) -> String {
        guard provider != anthropic else { return anthropic }
        let url = chatURL(from: address(provider: provider, custom: baseURL))
        return "custom:" + (url?.host ?? "") + (url?.port.map { ":\($0)" } ?? "")
    }

    /// The chat-completions address for what the user typed: a base address ("https://api.deepseek.com/v1"), with or
    /// without a trailing slash, or the full address of the endpoint itself.
    static func chatURL(from typed: String) -> URL? { AIPreset.chatURL(from: typed) }

    private static func runAPI(_ prompt: String, provider: String, model: String, baseURL: String) -> Result<String, Failure> {
        // Debug aid: `UTMWATCH_AI_KEY` supplies the key for one run, so a trial copy can be tested without saving a key.
        let key = ProcessInfo.processInfo.environment["UTMWATCH_AI_KEY"] ?? KeysFile.get(keyAccount(provider: provider, baseURL: baseURL)) ?? ""
        let model = model.trimmingCharacters(in: .whitespaces)
        guard !model.isEmpty else { return .failure(Failure(message: "No model name is set.")) }
        var request: URLRequest
        let body: [String: Any]
        if provider == "anthropic" {
            guard !key.isEmpty else { return .failure(Failure(message: "No API key is saved.")) }
            request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
            body = ["model": model, "max_tokens": 4000, "messages": [["role": "user", "content": prompt]]]
        } else {
            guard let url = chatURL(from: baseURL) else {
                return .failure(Failure(message: "The address is not a web address."))
            }
            request = URLRequest(url: url)
            // A model served on this Mac usually wants no key.
            if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
            body = ["model": model, "messages": [["role": "user", "content": prompt]]]
        }
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let done = DispatchSemaphore(value: 0)
        var result: Result<String, Failure> = .failure(Failure(message: "No answer."))
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { done.signal() }
            if let error { result = .failure(Failure(message: error.localizedDescription)); return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let obj = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            guard (200..<300).contains(status), let obj else {
                // Both kinds of server put the reason at error.message.
                let why = ((obj?["error"] as? [String: Any])?["message"] as? String) ?? (obj?["error"] as? String) ?? "HTTP \(status)"
                result = .failure(Failure(message: status == 401 || status == 403 ? "The key was refused: \(why)" : why))
                return
            }
            var text = ""
            if provider == "anthropic" {
                if obj["stop_reason"] as? String == "refusal" { result = .failure(Failure(message: "The model declined to answer.")); return }
                text = ((obj["content"] as? [[String: Any]]) ?? []).filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
            } else {
                // Chat completions: the answer is choices[0].message.content. Some servers send it as a list of parts.
                let content = (((obj["choices"] as? [[String: Any]])?.first)?["message"] as? [String: Any])?["content"]
                text = (content as? String) ?? ((content as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined()
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            result = text.isEmpty ? .failure(Failure(message: "The model gave an empty answer.")) : .success(text)
        }.resume()
        done.wait()
        return result
    }
}
