import CSysShim
import CoreWLAN
import Foundation

/// Measures each network segment the Mac can see: host to VM, host to router, host to internet, and the link itself.
/// `run` blocks for up to about a second per unanswered ping, so call it off the main thread.
public final class NetProbe {
    public var anchors: [String]
    public var timeoutMs: Int32 = 1000

    private var route: (gateway: String?, interface: String?) = (nil, nil)
    private var routeAt = Date.distantPast
    private var arp: [String: BridgeHost] = [:]   // normalized MAC -> address on a VM bridge
    private var arpAt = Date.distantPast
    private var routes: [String: (via: String?, at: Date)] = [:]   // VM IPv4 -> interface its route leaves by

    public init(anchors: [String] = ["1.1.1.1", "223.5.5.5"]) { self.anchors = anchors }

    /// A host on a VM bridge: its IPv4 address and the bridge it sits on.
    public struct BridgeHost: Equatable {
        public var ip: String
        public var interface: String
    }

    /// Pings `ip`, out of `interface` when given rather than wherever the routing table points.
    public static func ping(_ ip: String, interface: String? = nil, timeoutMs: Int32 = 1000) -> Double? {
        var rtt = 0.0
        return shim_ping(ip, interface, timeoutMs, &rtt) == 0 ? rtt : nil
    }

    /// One line describing what the last round saw; changes are worth logging.
    public private(set) var diagnostics = ""

    /// "gateway: 192.168.1.1" and "interface: en1" from `route -n get default`.
    public static func parseRoute(_ output: String) -> (gateway: String?, interface: String?) {
        var gateway: String?, interface: String?
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            if parts[0] == "gateway" { gateway = parts[1] }
            if parts[0] == "interface" { interface = parts[1] }
        }
        return (gateway, interface)
    }

    /// MAC -> address and bridge for hosts on the VM bridges, from `arp -an`.
    public static func parseARP(_ output: String) -> [String: BridgeHost] {
        var map: [String: BridgeHost] = [:]
        for line in output.split(separator: "\n") {
            // ? (192.168.64.3) at 02:1a:2b:3c:4d:5e on bridge100 ifscope [bridge]
            let f = line.split(separator: " ").map(String.init)
            guard f.count >= 6, f[2] == "at", f[4] == "on", f[5].hasPrefix("bridge"), f[3].contains(":") else { continue }
            let ip = f[1].trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            map[MACAddress.normalize(f[3])] = BridgeHost(ip: ip, interface: f[5])
        }
        return map
    }

    /// The interface `route -n get` picks for an address; nil when it fails or there is no route.
    private func routeVia(_ ip: String, now: Date) -> String? {
        if let r = routes[ip], now.timeIntervalSince(r.at) < 30 { return r.via }
        let r = Shell.run("/sbin/route", ["-n", "get", ip], timeout: 3)
        let via = r.status == 0 ? NetProbe.parseRoute(r.stdout).interface : nil
        routes[ip] = (via, now)
        return via
    }

    /// An interface's IPv4 network as "192.168.64.0/24".
    public static func subnet(of interface: String) -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return nil }
        defer { freeifaddrs(list) }
        var cursor = list
        while let a = cursor?.pointee {
            cursor = a.ifa_next
            guard String(cString: a.ifa_name) == interface, let addr = a.ifa_addr, let mask = a.ifa_netmask,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let m = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let net = ip & m
            return "\(net >> 24).\((net >> 16) & 255).\((net >> 8) & 255).\(net & 255)/\(m.nonzeroBitCount)"
        }
        return nil
    }

    private func refreshRoute(now: Date) {
        guard now.timeIntervalSince(routeAt) >= 60 || route.gateway == nil else { return }
        routeAt = now
        let r = Shell.run("/sbin/route", ["-n", "get", "default"], timeout: 3)
        route = r.status == 0 ? NetProbe.parseRoute(r.stdout) : (nil, nil)
    }

    private func refreshARP(now: Date, force: Bool) {
        guard force || now.timeIntervalSince(arpAt) >= 60 else { return }
        arpAt = now
        let r = Shell.run("/usr/sbin/arp", ["-an"], timeout: 3)
        if r.status == 0 { arp = NetProbe.parseARP(r.stdout) }
    }

    public func linkInfo() -> LinkInfo {
        guard let iface = route.interface else { return LinkInfo(kind: "none") }
        if let wifi = CWWiFiClient.shared().interface(), wifi.interfaceName == iface, wifi.powerOn() {
            var info = LinkInfo(kind: "wifi", interface: iface)
            let rssi = wifi.rssiValue()
            if rssi != 0 { info.rssi = rssi; info.noise = wifi.noiseMeasurement() }
            let rate = wifi.transmitRate()
            if rate > 0 { info.txRateMbps = rate }
            info.channel = wifi.wlanChannel()?.channelNumber
            return info
        }
        var info = LinkInfo(kind: iface.hasPrefix("en") ? "ethernet" : "other", interface: iface)
        var baud: UInt64 = 0, ierr: UInt64 = 0, oerr: UInt64 = 0
        if shim_if_link(iface, &baud, &ierr, &oerr) == 0 {
            if baud > 0 { info.speedMbps = Double(baud) / 1e6 }
            info.errors = ierr &+ oerr
        }
        return info
    }

    public func run(targets: [(key: String, name: String, macs: [String])]) -> ProbeResult {
        let now = Date()
        refreshRoute(now: now)
        let missing = targets.contains { t in !t.macs.contains { arp[$0] != nil } }
        refreshARP(now: now, force: missing && now.timeIntervalSince(arpAt) >= 10)

        var vmPing: [String: Double?] = [:]
        var vmRoute: [String: VMRoute] = [:]
        routes = routes.filter { now.timeIntervalSince($0.value.at) < 300 }
        for t in targets {
            // A VM with no ARP entry yet has not spoken on the network; skip it, do not count it as lost.
            guard let host = t.macs.compactMap({ arp[$0] }).first else { continue }
            // Out the VM's own bridge: a VPN or exit node can drop or override the route to it (the VM is fine meanwhile).
            vmPing[t.key] = .some(NetProbe.ping(host.ip, interface: host.interface, timeoutMs: timeoutMs))
            vmRoute[t.key] = VMRoute(ip: host.ip, bridge: host.interface, via: routeVia(host.ip, now: now), subnet: NetProbe.subnet(of: host.interface))
        }
        let gateway = route.gateway.flatMap { NetProbe.ping($0, timeoutMs: timeoutMs) }
        var internet: Double?
        var perAnchor: [String: Double?] = [:]
        if route.gateway != nil {
            for a in anchors { perAnchor[a] = .some(NetProbe.ping(a, timeoutMs: timeoutMs)) }
            // Best of the anchors: one unreachable anchor should not look like a broken line.
            internet = perAnchor.values.compactMap { $0 }.min()
        }
        diagnostics = "gateway \(route.gateway ?? "none") via \(route.interface ?? "-"), \(arp.count) bridge hosts known, \(vmPing.count) of \(targets.count) VMs pinged, \(vmRoute.values.filter { !$0.ok }.count) without a route back, gateway \(gateway == nil ? "no reply" : "ok"), internet \(internet == nil ? "no reply" : "ok")"
        return ProbeResult(timestamp: now, vmPing: vmPing, gatewayTried: route.gateway != nil, gatewayMs: gateway,
                           internetTried: route.gateway != nil && !anchors.isEmpty, internetMs: internet, link: linkInfo(), anchorMs: perAnchor, vmRoute: vmRoute)
    }
}
