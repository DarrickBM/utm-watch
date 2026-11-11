import Foundation
import UTMWatchCore
import UTMWatchFleet
import UTMWatchStore

/// `utmwatch fleet …`: joins this Mac to a fleet, shows where it stands, or leaves. The app reads the same
/// identity file at launch, so after `enroll` it starts reporting the next time it opens.
enum FleetCommand {
    static let usage = """
    usage:
      utmwatch fleet enroll --hub <url> --code <pairing code> [--name <name>] [--identity <file>]
      utmwatch fleet view --token <reader token> [--hub <url>] [--identity <file>]
      utmwatch fleet status [--identity <file>]
      utmwatch fleet leave [--identity <file>]
      utmwatch fleet sim --hub <url> --code <pairing code> [--code <pairing code> …] [--seconds <n>]
    """

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("utmwatch: \(message)\n".utf8))
        exit(1)
    }

    static func run(_ arguments: [String]) -> Never {
        var args = arguments
        func option(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
            let value = args[i + 1]
            args.removeSubrange(i...i + 1)
            return value
        }
        func options(_ name: String) -> [String] {
            var out: [String] = []
            while let v = option(name) { out.append(v) }
            return out
        }
        let path = option("--identity") ?? HostIdentity.defaultPath

        switch args.first {
        case "enroll":
            guard var code = option("--code") else { fail(usage) }
            // A pairing code from the app carries the hub's address; a bare token from `utmwatch-hub token create` needs --hub.
            var hubOption = option("--hub")
            if let packed = PairingCode(text: code) {
                guard packed.authKey == nil else { fail("this pairing code is for a fleet on a private network; enter it in UTM Watch's Settings instead") }
                code = packed.token; hubOption = hubOption ?? packed.hub
            }
            guard let hub = hubOption else { fail(usage) }
            let name = option("--name") ?? Host.current().localizedName ?? ProcessInfo.processInfo.hostName
            // Enrolling again keeps this Mac's UUID, so the hub keeps its history.
            let uuid = HostIdentity.load(path: path)?.hostUUID ?? UUID().uuidString.lowercased()
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "cli"
            switch HubClient(baseURL: hub).enroll(code: code, request: EnrollRequest(hostUUID: uuid, name: name, appVersion: version)) {
            case .success(let reply):
                do { try HostIdentity(hostUUID: uuid, name: name, hubURL: hub, hostToken: reply.hostToken, readerToken: reply.readerToken ?? HostIdentity.load(path: path)?.readerToken).save(path: path) }
                catch { fail("enrolled, but could not save \(path): \(error)") }
                print("Enrolled as \"\(name)\". UTM Watch starts reporting to \(hub) the next time it opens.")
            case .failure(.unreachable): fail("no answer from \(hub). Check the address and that this Mac can reach it.")
            case .failure(.rejected(_, let message)): fail(message)
            }
            exit(0)

        case "view":
            // Lets this Mac read the whole fleet (the MCP server now, the fleet window later). It does not have to report itself.
            guard let token = option("--token") else { fail(usage) }
            var id = HostIdentity.load(path: path) ?? HostIdentity(hostUUID: "", name: "", hubURL: "", hostToken: "")
            if let hub = option("--hub") { id.hubURL = hub }
            guard !id.hubURL.isEmpty else { fail("--hub is required: this Mac does not know a hub yet") }
            switch HubClient(baseURL: id.hubURL).hosts(token: token) {
            case .success(let hosts):
                id.readerToken = token
                do { try id.save(path: path) } catch { fail("could not save \(path): \(error)") }
                print("This Mac can now read the fleet at \(id.hubURL): \(hosts.count) Mac\(hosts.count == 1 ? "" : "s") enrolled.")
            case .failure(.unreachable): fail("no answer from \(id.hubURL). Check the address and that this Mac can reach it.")
            case .failure(.rejected(_, let message)): fail(message)
            }
            exit(0)

        case "status":
            guard let id = HostIdentity.load(path: path) else { print("This Mac is not in a fleet."); exit(0) }
            if id.hostToken.isEmpty { print("This Mac does not report to the fleet.\nHub:   \(id.hubURL)") }
            else { print("Name:  \(id.name)\nUUID:  \(id.hostUUID)\nHub:   \(id.hubURL)") }
            print("Reading the fleet: \(id.readerToken == nil ? "no (see `utmwatch fleet view`)" : "yes")")
            switch HubClient(baseURL: id.hubURL).health() {
            case .success: print("Hub reachable.")
            case .failure(.unreachable): print("Hub not reachable right now. UTM Watch keeps recording and catches up later.")
            case .failure(.rejected(_, let message)): print("Hub answered unexpectedly: \(message)")
            }
            if let store = try? HistoryStore(readOnly: true), let cursor = store.uploadCursor(), cursor.sampleTs > 0 {
                let behind = max(0, Date().msSince1970 - cursor.sampleTs) / 1000
                print("History uploaded up to \(behind) s ago.")
            }
            exit(0)

        case "leave":
            guard HostIdentity.load(path: path) != nil else { print("This Mac is not in a fleet."); exit(0) }
            HostIdentity.remove(path: path)
            print("Left the fleet. UTM Watch stops reporting the next time it opens; history already on the hub stays there until it ages out.")
            exit(0)

        case "sim":
            guard let hub = option("--hub") else { fail(usage) }
            let codes = options("--code")
            guard !codes.isEmpty else { fail(usage) }
            FleetSim.run(hub: hub, codes: codes, seconds: option("--seconds").flatMap(Double.init))

        default:
            fail(usage)
        }
    }
}

/// Imitates several Macs for testing a hub and the fleet view: each gets its own temporary history database, records
/// made-up samples into it and uploads them with the real uploader, so everything after the sampler is the real path.
enum FleetSim {
    static func run(hub: String, codes: [String], seconds: Double?) -> Never {
        let dir = NSTemporaryDirectory() + "utmwatch-sim-\(ProcessInfo.processInfo.processIdentifier)/"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let gb: UInt64 = 1 << 30
        var macs: [(name: String, store: HistoryStore, uploader: Uploader, vms: Int)] = []
        for (i, code) in codes.enumerated() {
            let name = "Sim Mini \(i + 1)"
            let uuid = "sim-\(i + 1)-" + UUID().uuidString.lowercased().prefix(8)
            guard case .success(let reply) = HubClient(baseURL: hub).enroll(code: code, request: EnrollRequest(hostUUID: uuid, name: name, appVersion: "sim")) else {
                FleetCommand.fail("could not enrol \(name) at \(hub): the code was refused or the hub did not answer")
            }
            guard let store = try? HistoryStore(path: dir + "\(i).sqlite") else { FleetCommand.fail("could not create a temporary database") }
            let uploader = Uploader(store: store, client: HubClient(baseURL: hub), token: reply.hostToken, appVersion: "sim")
            macs.append((name, store, uploader, 2 + i % 3))
            print("\(name) enrolled as \(uuid)")
        }
        let started = Date()
        var tick = 0
        while seconds.map({ Date().timeIntervalSince(started) < $0 }) ?? true {
            let now = Date()
            for (m, mac) in macs.enumerated() {
                let rows = (0..<mac.vms).map { v -> VMRow in
                    let wave = (sin(Double(tick) / 20 + Double(m * 3 + v)) + 1) / 2
                    var row = VMRow(id: "/Users/sim/Library/Containers/com.utmapp.UTM/Data/Documents/VM \(v + 1).utm", name: "VM \(v + 1)",
                                    backend: v % 2 == 0 ? .apple : .qemu, status: .running, pid: Int32(1000 + m * 10 + v), identified: true, isMacOS: v % 2 == 0,
                                    cpuCores: 0.2 + wave * 3, cpuAllocated: 4, memoryBytes: UInt64(Double(4 * gb) + wave * Double(3 * gb)), memoryAllocatedBytes: 8 * gb,
                                    downRate: wave * 2e6, upRate: wave * 3e5, downTotal: UInt64(tick) * 100_000, upTotal: UInt64(tick) * 20_000)
                    row.residentBytes = UInt64(Double(3 * gb) + wave * Double(2 * gb))
                    return row
                }
                let used = UInt64(mac.vms) * 6 * gb + 10 * gb
                let host = HostSummary.compute(totalMemory: 48 * gb, hostUsed: used, vmFootprints: UInt64(mac.vms) * 6 * gb, runningAllocated: UInt64(mac.vms) * 8 * gb,
                                               pressure: m == 1 && tick % 60 > 45 ? .warning : .normal, swapUsed: gb / 2, swapTotal: 4 * gb,
                                               physicalCores: 14, allocatedCores: mac.vms * 4, macOSRunning: (mac.vms + 1) / 2)
                let snap = Snapshot(timestamp: now, intervalSeconds: 2, rows: rows, host: host, notices: [])
                var link = LinkInfo(kind: "ethernet", interface: "en0"); link.speedMbps = 1000
                var probes: [ProbeResult] = []
                if tick % 5 == 0 {
                    probes = [ProbeResult(timestamp: now, vmPing: Dictionary(uniqueKeysWithValues: rows.map { ($0.id, Double?.some(0.5)) }), gatewayTried: true, gatewayMs: 1.2,
                                          internetTried: true, internetMs: 12, link: link)]
                    mac.uploader.setLive(link: link)
                }
                mac.store.write(snapshots: [snap], probes: probes)
                mac.uploader.setLive(snapshot: snap)
                if tick % 5 == 4 {
                    let status = mac.uploader.runOnce()
                    if status.state != .upToDate { print("\(mac.name): \(status.state)") }
                }
            }
            tick += 1
            Thread.sleep(forTimeInterval: 2)
        }
        try? FileManager.default.removeItem(atPath: dir)
        exit(0)
    }
}
