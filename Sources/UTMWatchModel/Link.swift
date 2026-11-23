import Foundation

/// The Mac's active network link at one moment.
public struct LinkInfo: Codable, Equatable {
    /// "wifi", "ethernet", "other" or "none" (no default route).
    public var kind: String
    public var interface: String?
    public var rssi: Int?            // dBm, Wi-Fi only
    public var noise: Int?           // dBm, Wi-Fi only
    public var txRateMbps: Double?   // Wi-Fi only
    public var channel: Int?         // Wi-Fi only
    public var speedMbps: Double?    // Ethernet only
    public var errors: UInt64?       // Ethernet only: input + output errors since boot

    public init(kind: String, interface: String? = nil) { self.kind = kind; self.interface = interface }
}

/// Where this Mac sends traffic addressed to a VM. Replies to everything the VM sends out through the Mac come back this way,
/// so when the route leaves by another interface (a VPN can take it away) the VM runs but is cut off.
public struct VMRoute: Codable, Equatable {
    public var ip: String
    /// The bridge the VM sits on, e.g. "bridge100".
    public var bridge: String
    /// The interface the Mac's routing table sends the VM's address to; nil when there is no route at all.
    public var via: String?
    /// The bridge's own network, e.g. "192.168.64.0/24".
    public var subnet: String?
    public var ok: Bool { via == bridge }
    public init(ip: String, bridge: String, via: String?, subnet: String?) { self.ip = ip; self.bridge = bridge; self.via = via; self.subnet = subnet }
}

/// One round of connection-quality measurements.
public struct ProbeResult: Equatable {
    public var timestamp: Date
    /// Round-trip time to each running VM in milliseconds; nil value = no reply. Keyed by VM key.
    public var vmPing: [String: Double?]
    public var gatewayTried: Bool
    public var gatewayMs: Double?
    public var internetTried: Bool
    /// Best reply among the internet servers: nil only when none answered, so one dead server is not an outage.
    public var internetMs: Double?
    /// Each internet server on its own (nil value = no reply). Best-of hides jitter; these do not.
    public var anchorMs: [String: Double?]
    public var link: LinkInfo
    /// The Mac's route to each VM that was pinged, keyed by VM key; checked every 30 s.
    public var vmRoute: [String: VMRoute]

    public init(timestamp: Date, vmPing: [String: Double?], gatewayTried: Bool, gatewayMs: Double?, internetTried: Bool, internetMs: Double?,
                link: LinkInfo, anchorMs: [String: Double?] = [:], vmRoute: [String: VMRoute] = [:]) {
        self.timestamp = timestamp; self.vmPing = vmPing; self.gatewayTried = gatewayTried; self.gatewayMs = gatewayMs
        self.internetTried = internetTried; self.internetMs = internetMs; self.link = link; self.anchorMs = anchorMs; self.vmRoute = vmRoute
    }
}
