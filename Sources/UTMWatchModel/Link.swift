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

    public init(timestamp: Date, vmPing: [String: Double?], gatewayTried: Bool, gatewayMs: Double?, internetTried: Bool, internetMs: Double?,
                link: LinkInfo, anchorMs: [String: Double?] = [:]) {
        self.timestamp = timestamp; self.vmPing = vmPing; self.gatewayTried = gatewayTried; self.gatewayMs = gatewayMs
        self.internetTried = internetTried; self.internetMs = internetMs; self.link = link; self.anchorMs = anchorMs
    }
}
