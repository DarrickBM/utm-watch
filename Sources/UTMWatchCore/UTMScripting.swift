import Foundation

public struct UTMListedVM: Codable, Equatable {
    public var id: String
    public var name: String
    public var status: String
    public var backend: String
    /// The VM's settings as UTM reports them: nil from a UTM too old to say, or for a VM it could not describe.
    /// They stand in for config.plist when macOS will not let this app read UTM's folder.
    public var cpuCores: Int?
    public var memoryMB: Int?
    public var macs: [String]?

    public init(id: String, name: String, status: String, backend: String, cpuCores: Int? = nil, memoryMB: Int? = nil, macs: [String]? = nil) {
        self.id = id; self.name = name; self.status = status; self.backend = backend
        self.cpuCores = cpuCores; self.memoryMB = memoryMB; self.macs = macs
    }
}

extension UTMListedVM {
    public var memoryBytes: UInt64? { memoryMB.flatMap { $0 > 0 ? UInt64($0) * 1024 * 1024 : nil } }
}

public enum UTMScriptingError: Error, Equatable {
    case notRunning
    case notAuthorized
    case failed(String)

    public var notice: String {
        switch self {
        case .notRunning: return "UTM is not running; names come from .utm bundles"
        case .notAuthorized: return "UTM automation denied (System Settings > Privacy & Security > Automation); names come from .utm bundles"
        case .failed(let msg): return "UTM query failed (\(msg)); retrying in a minute, or press r. Names come from .utm bundles"
        }
    }
}

/// Asks UTM for its VM list through its AppleScript interface (via JXA so we get JSON back).
public enum UTMScripting {
    static let script = """
    const app = Application("UTM");
    if (!app.running()) { "NOT_RUNNING"; } else {
      const vms = app.virtualMachines();
      JSON.stringify(vms.map(vm => {
        const o = { id: vm.id(), name: vm.name(), status: vm.status(), backend: vm.backend() };
        try {
          const c = vm.configuration();
          if (c.cpuCores > 0) o.cpuCores = c.cpuCores;
          if (c.memory > 0) o.memoryMB = c.memory;
          o.macs = (c.networkInterfaces || []).map(n => n.address).filter(a => a);
        } catch (e) {}
        return o;
      }));
    }
    """

    public static func parse(_ json: String) throws -> [UTMListedVM] {
        try JSONDecoder().decode([UTMListedVM].self, from: Data(json.utf8))
    }

    public static func list(timeout: TimeInterval = 8) -> Result<[UTMListedVM], UTMScriptingError> {
        if UTMBundles.disabled { return .success([]) }
        let result = Shell.run("/usr/bin/osascript", ["-l", "JavaScript", "-e", script], timeout: timeout)
        if result.timedOut { return .failure(.failed("timed out, answer the Automation prompt if one is showing")) }
        let out = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.status != 0 {
            let err = result.stderr
            if err.contains("-1743") || err.lowercased().contains("not authorized") { return .failure(.notAuthorized) }
            if err.contains("-600") { return .failure(.notRunning) }
            return .failure(.failed(err.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        if out == "NOT_RUNNING" { return .failure(.notRunning) }
        do { return .success(try parse(out)) } catch { return .failure(.failed("unexpected output: \(out.prefix(80))")) }
    }
}
