import Foundation

/// The fleet HTTP API: what a Mac sends to its hub and what the hub answers. All times are milliseconds since 1970.
public enum FleetAPI {
    public static let version = 1

    public static func encode<T: Encodable>(_ value: T) -> Data { (try? JSONEncoder().encode(value)) ?? Data("{}".utf8) }
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? { try? JSONDecoder().decode(type, from: data) }
}

/// How far a Mac has uploaded its local history. Events use their row id: one can be written late with an old time.
public struct UploadCursor: Codable, Equatable {
    public var sampleTs: Int64
    public var probeTs: Int64
    public var eventId: Int64
    public init(sampleTs: Int64 = 0, probeTs: Int64 = 0, eventId: Int64 = 0) {
        self.sampleTs = sampleTs; self.probeTs = probeTs; self.eventId = eventId
    }
}

/// One upload from a Mac. Sample rows are arrays in a fixed column order to keep the payload small.
public struct IngestBatch: Codable, Equatable {
    public struct VM: Codable, Equatable {
        public var key: String, name: String, backend: String
        public init(key: String, name: String, backend: String) { self.key = key; self.name = name; self.backend = backend }
    }
    public struct Config: Codable, Equatable {
        /// Index into `vms`.
        public var vm: Int
        public var ts: Int64
        public var cores: Int?
        public var mem: Double?
        public init(vm: Int, ts: Int64, cores: Int?, mem: Double?) { self.vm = vm; self.ts = ts; self.cores = cores; self.mem = mem }
    }
    public struct Link: Codable, Equatable {
        public var ts: Int64
        public var kind: String
        public var iface: String?
        public var rssi: Double?, noise: Double?, txRate: Double?
        public var channel: Int?
        public var speed: Double?
        public init(ts: Int64, kind: String, iface: String?, rssi: Double?, noise: Double?, txRate: Double?, channel: Int?, speed: Double?) {
            self.ts = ts; self.kind = kind; self.iface = iface; self.rssi = rssi; self.noise = noise
            self.txRate = txRate; self.channel = channel; self.speed = speed
        }
    }
    public struct Event: Codable, Equatable {
        public var ts: Int64
        public var kind: String
        public var vmKey: String?
        public var label: String
        public var detail: String?
        public init(ts: Int64, kind: String, vmKey: String?, label: String, detail: String?) {
            self.ts = ts; self.kind = kind; self.vmKey = vmKey; self.label = label; self.detail = detail
        }
    }

    public var apiVersion = FleetAPI.version
    /// The sender's clock when it sent this; the hub compares it with its own to measure clock skew.
    public var sentAt: Int64 = 0
    public var appVersion = ""
    public var intervalS: Double = 2
    public var vms: [VM] = []
    public var configs: [Config] = []
    /// [vm index, ts, cpu, mem, down, up, downTotal, upTotal, diskRead, diskWrite, res]
    public var samples: [[Double?]] = []
    /// [vm index, ts, diskUsed, diskSize] for the samples that carry a disk reading. Sent beside `samples` rather than
    /// as extra columns so a hub that predates it still stores the rest; absent from Macs that predate it.
    public var disks: [[Double?]]?
    /// [ts, used, other, allocatable, pressure, swapUsed, swapTotal, cores, cpu]
    public var host: [[Double?]] = []
    public var targets: [String] = []
    /// [target index, ts, rtt, ok]
    public var probes: [[Double?]] = []
    public var link: [Link] = []
    public var events: [Event] = []
    /// The Mac's state right now, for the fleet overview.
    public var snapshot: Snapshot?
    public var linkNow: LinkInfo?
    /// Where the sender's cursors stand once this batch is stored.
    public var cursor: UploadCursor

    public init(cursor: UploadCursor) { self.cursor = cursor }

    /// True when the batch carries no recorded history (it may still carry the current snapshot).
    public var hasNoHistory: Bool { samples.isEmpty && host.isEmpty && probes.isEmpty && link.isEmpty && events.isEmpty }
}

public struct EnrollRequest: Codable, Equatable {
    public var hostUUID: String
    public var name: String
    public var appVersion: String
    public init(hostUUID: String, name: String, appVersion: String) { self.hostUUID = hostUUID; self.name = name; self.appVersion = appVersion }
}

public struct EnrollReply: Codable, Equatable {
    public var hostToken: String
    /// Lets the new Mac read the fleet too, so any Mac in a fleet can open the fleet view.
    public var readerToken: String?
    public init(hostToken: String, readerToken: String? = nil) { self.hostToken = hostToken; self.readerToken = readerToken }
}

/// What a Mac needs to join a fleet, packed into one string a person can paste: where the hub is, a single-use
/// enrolment token and, for a fleet that spans networks, the key that lets the Mac onto the fleet's private network.
/// It is a secret from the moment it is shown until it is used or expires.
public struct PairingCode: Codable, Equatable {
    public var hub: String
    public var token: String
    public var authKey: String?
    public init(hub: String, token: String, authKey: String? = nil) { self.hub = hub; self.token = token; self.authKey = authKey }

    static let prefix = "utmw1."

    public var text: String {
        let data = (try? JSONEncoder().encode(self)) ?? Data()
        return PairingCode.prefix + data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    public init?(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(PairingCode.prefix) else { return nil }
        var b64 = String(trimmed.dropFirst(PairingCode.prefix.count)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64), let code = try? JSONDecoder().decode(PairingCode.self, from: data),
              !code.hub.isEmpty, !code.token.isEmpty else { return nil }
        self = code
    }
}

public struct IngestReply: Codable, Equatable {
    public var accepted: UploadCursor
    /// Reserved for remote control; always empty in API version 1.
    public var commands: [String] = []
    public init(accepted: UploadCursor) { self.accepted = accepted }
}

/// One Mac as the fleet overview shows it.
public struct HostStatus: Codable, Equatable {
    public var uuid: String
    public var name: String
    /// "online", "offline", or "asleep" (offline, and the last thing the Mac said was that it was going to sleep). Judged by the hub's own clock.
    public var state: String
    public var lastSeen: Int64?
    /// Hub clock minus the Mac's clock at its last upload.
    public var skewMs: Int64?
    public var appVersion: String?
    public var snapshot: Snapshot?
    public var link: LinkInfo?
    public init(uuid: String, name: String, state: String, lastSeen: Int64?, skewMs: Int64?, appVersion: String?, snapshot: Snapshot?, link: LinkInfo?) {
        self.uuid = uuid; self.name = name; self.state = state; self.lastSeen = lastSeen; self.skewMs = skewMs
        self.appVersion = appVersion; self.snapshot = snapshot; self.link = link
    }
}

public struct FleetEvent: Codable, Equatable {
    /// The hub's own id, increasing in arrival order; pass the last one seen as `after` to poll.
    public var id: Int64
    public var hostUUID: String
    public var hostName: String
    public var ts: Int64
    public var kind: String
    public var vmKey: String?
    public var label: String
    public var detail: String?
    /// "agent" for events a Mac reported, "hub" for ones the hub raised itself.
    public var origin: String
    public init(id: Int64, hostUUID: String, hostName: String, ts: Int64, kind: String, vmKey: String?, label: String, detail: String?, origin: String) {
        self.id = id; self.hostUUID = hostUUID; self.hostName = hostName; self.ts = ts; self.kind = kind
        self.vmKey = vmKey; self.label = label; self.detail = detail; self.origin = origin
    }
}

/// Every hub answer: `data` on success, `error` otherwise.
public struct FleetReply<T: Codable>: Codable {
    public var apiVersion = FleetAPI.version
    public var serverTime: Int64
    public var data: T?
    public var error: String?
    public init(serverTime: Int64, data: T? = nil, error: String? = nil) { self.serverTime = serverTime; self.data = data; self.error = error }
}

/// Secrets handed to Macs and readers. The hub keeps only their SHA-256.
public enum FleetToken {
    public static func make(prefix: String) -> String {
        var rng = SystemRandomNumberGenerator()
        let bytes = (0..<24).map { _ in UInt8.random(in: 0...255, using: &rng) }
        return prefix + bytes.map { String(format: "%02x", $0) }.joined()
    }
    public static func hash(_ token: String) -> String { SHA256.hex(Array(token.utf8)) }
}

/// SHA-256 in plain Swift: CryptoKit does not exist on Linux and the hub takes no dependencies for this.
public enum SHA256 {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    public static func hex(_ bytes: [UInt8]) -> String { hash(bytes).map { String(format: "%02x", $0) }.joined() }

    public static func hash(_ bytes: [UInt8]) -> [UInt8] {
        func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        var msg = bytes
        let bitLength = UInt64(bytes.count) * 8
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) { msg.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift))) }
        var w = [UInt32](repeating: 0, count: 64)
        for chunk in stride(from: 0, to: msg.count, by: 64) {
            for i in 0..<16 {
                let j = chunk + i * 4
                w[i] = UInt32(msg[j]) << 24 | UInt32(msg[j + 1]) << 16 | UInt32(msg[j + 2]) << 8 | UInt32(msg[j + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
            for i in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ maj
                hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
            h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
        }
        return h.flatMap { [UInt8($0 >> 24), UInt8(($0 >> 16) & 0xff), UInt8(($0 >> 8) & 0xff), UInt8($0 & 0xff)] }
    }
}
