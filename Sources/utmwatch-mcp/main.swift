// utmwatch-mcp: a Model Context Protocol server over standard input/output.
// It lets an AI agent read UTM Watch's recorded history. Read-only; it never changes VMs, settings or data.
// Protocol: JSON-RPC 2.0, one message per line (MCP stdio transport).
import Foundation
import UTMWatchCore
import UTMWatchStore

let serverVersion = "0.1.0"
// Inside the app bundle this process shares the app's bundle identifier, so the standard defaults are the app's own.
let appDefaults: UserDefaults? = Bundle.main.bundleIdentifier == "com.darrick.utmwatch" ? .standard : UserDefaults(suiteName: "com.darrick.utmwatch")

/// JSONSerialization prints doubles at full precision (6.7530000000000001). Trim them: fewer tokens for the agent.
func compactJSON(_ object: Any) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    let text = String(decoding: data, as: UTF8.self)
    let regex = try NSRegularExpression(pattern: #"(?<=[:\[,])(-?\d+\.\d{4,})(?=[,\]}])"#)
    var out = "", last = text.startIndex
    for m in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
        guard let r = Range(m.range(at: 1), in: text), let v = Double(text[r]) else { continue }
        out += text[last..<r.lowerBound]
        var num = String(format: "%.3f", v)
        while num.hasSuffix("0") { num.removeLast() }
        if num.hasSuffix(".") { num.removeLast() }
        out += num
        last = r.upperBound
    }
    return out + text[last...]
}

// MARK: - Output

func send(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

func reply(_ id: Any, _ result: [String: Any]) { send(["jsonrpc": "2.0", "id": id, "result": result]) }
func fail(_ id: Any, _ code: Int, _ message: String) { send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]) }

struct ToolError: Error { var message: String }

// MARK: - Helpers

let iso = Diagnostics.iso
let r3 = Diagnostics.round3
let gib = 1_073_741_824.0

/// Accepts "now", relative forms like "-2h" / "-30m" / "-7d", and ISO 8601 or "yyyy-MM-dd HH:mm" in local time.
func parseTime(_ value: Any?, default fallback: Int64? = nil, now: Int64) throws -> Int64 {
    guard let raw = value as? String, !raw.isEmpty else {
        if let fallback { return fallback }
        throw ToolError(message: "a time is required")
    }
    let s = raw.trimmingCharacters(in: .whitespaces)
    if s.lowercased() == "now" { return now }
    if s.hasPrefix("-"), let unit = s.last, let n = Double(s.dropFirst().dropLast()) {
        let seconds: Double? = ["s": 1, "m": 60, "h": 3600, "d": 86400][String(unit)]
        if let seconds { return now - Int64(n * seconds * 1000) }
    }
    for options: ISO8601DateFormatter.Options in [[.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds]] {
        let f = ISO8601DateFormatter(); f.formatOptions = options
        if let d = f.date(from: s) { return d.msSince1970 }
    }
    for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .current; f.dateFormat = format
        if let d = f.date(from: s) { return d.msSince1970 }
    }
    throw ToolError(message: "cannot read the time \"\(raw)\". Use ISO 8601 such as 2026-11-10T21:40:00+08:00, a local time such as 2026-11-10 21:40, or a relative form such as -2h.")
}

func openStore() throws -> HistoryStore {
    if appDefaults?.object(forKey: "allowAgents") as? Bool == false {
        throw ToolError(message: "Access for AI agents is switched off in UTM Watch's Settings (AI diagnosis > Let AI agents read history).")
    }
    guard FileManager.default.fileExists(atPath: HistoryStore.defaultPath) else {
        throw ToolError(message: "No history found. Open UTM Watch once so it starts recording.")
    }
    do { return try HistoryStore(readOnly: true) } catch { throw ToolError(message: "Cannot open the history database: \(error)") }
}

func range(_ args: [String: Any], defaultFrom: String, now: Int64) throws -> (Int64, Int64) {
    let to = try parseTime(args["to"], default: now, now: now)
    let from = try parseTime(args["from"] ?? defaultFrom, now: now)
    guard from < to else { throw ToolError(message: "\"from\" must be earlier than \"to\"") }
    return (from, min(to, now))
}

/// Resolution suited to analysis: about 10 s for short ranges, 1 minute or coarser for long ones.
func analysisPoints(_ from: Int64, _ to: Int64) -> Int {
    let span = to - from
    return span <= HistoryStore.rollupThresholdMs ? max(60, Int(span / 10_000)) : min(2000, max(120, Int(span / 60_000)))
}

func parsedDetail(_ detail: String?) -> Any? {
    guard let detail, let data = detail.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data)
}

func eventJSON(_ e: HistoryEvent, names: [String: String]) -> [String: Any] {
    var d: [String: Any] = ["time": iso(e.ts), "kind": e.kind, "label": e.label]
    if let key = e.vmKey { d["vm"] = names[key] ?? (key as NSString).lastPathComponent }
    if let detail = parsedDetail(e.detail) { d["processesAtTheTime"] = detail }
    return d
}

/// Folds repeats of the same event into one line with a count, so a burst of identical events stays short.
func groupedEvents(_ events: [HistoryEvent], names: [String: String]) -> [[String: Any]] {
    var order: [String] = []
    var groups: [String: [HistoryEvent]] = [:]
    for e in events {
        let key = e.kind + "|" + (e.vmKey ?? "")
        if groups[key] == nil { order.append(key) }
        groups[key, default: []].append(e)
    }
    return order.map { key -> [String: Any] in
        let list = groups[key]!
        var d: [String: Any] = ["kind": list[0].kind, "label": list[0].label, "time": iso(list[0].ts)]
        if let vm = list[0].vmKey { d["vm"] = names[vm] ?? (vm as NSString).lastPathComponent }
        if list.count > 1 { d["count"] = list.count; d["lastTime"] = iso(list[list.count - 1].ts) }
        return d
    }
}

/// A short fingerprint of a captured process list: the same set of names means the same picture.
func processSignature(_ detail: String?) -> String? {
    guard let obj = parsedDetail(detail) as? [String: Any] else { return nil }
    let names = (["topMemory", "topCPU"].flatMap { (obj[$0] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String } })
    return names.isEmpty ? nil : names.sorted().joined(separator: ",")
}

func linkJSON(_ l: LinkPoint) -> [String: Any] {
    var d: [String: Any] = ["kind": l.kind]
    if let v = l.interface { d["interface"] = v }
    if let v = l.rssi { d["signalDbm"] = Int(v.rounded()) }
    if let v = l.noise { d["noiseDbm"] = Int(v.rounded()) }
    if let v = l.txRate { d["linkSpeedMbps"] = Int(v.rounded()) }
    if let v = l.channel { d["channel"] = v }
    if let v = l.speed { d["speedMbps"] = Int(v.rounded()) }
    return d
}

func nearest<P>(_ points: [P], _ t: Int64, within: Int64, time: (P) -> Int64) -> P? {
    guard let best = points.min(by: { abs(time($0) - t) < abs(time($1) - t) }), abs(time(best) - t) <= within else { return nil }
    return best
}

/// Every value at (or nearest to) one moment.
func momentJSON(_ h: History, at t: Int64) -> [String: Any] {
    var vms: [[String: Any]] = []
    for vm in h.vms {
        var d: [String: Any] = ["name": vm.name, "backend": vm.backend]
        let cfg = h.config(for: vm.key, at: t)
        if let c = cfg?.cores { d["coresAllocated"] = c }
        if let m = cfg?.memBytes { d["memoryAllocatedGB"] = r3(m / gib) }
        if let p = nearest(h.series[vm.key] ?? [], t, within: 30_000, time: { $0.t }) {
            d["state"] = "running"
            if let v = p.cpu { d["cpuCores"] = r3(v) }
            if let v = p.mem { d["memoryGB"] = r3(v / gib) }
            if let v = p.res { d["memoryInRAMGB"] = r3(v / gib) }
            if let v = p.down { d["downloadKBps"] = r3(v / 1000) }
            if let v = p.up { d["uploadKBps"] = r3(v / 1000) }
            if let v = p.diskRead { d["diskReadKBps"] = r3(v / 1000) }
            if let v = p.diskWrite { d["diskWriteKBps"] = r3(v / 1000) }
        } else {
            d["state"] = "not running, or no sample near this time"
        }
        if let p = nearest(h.probes[ProbeTarget.vm(vm.key)] ?? [], t, within: 30_000, time: { $0.t }) {
            if let rtt = p.rtt { d["pingMs"] = r3(rtt) } else { d["ping"] = "no reply" }
        }
        vms.append(d)
    }
    var out: [String: Any] = ["time": iso(t), "vms": vms]
    if let p = nearest(h.host, t, within: 30_000, time: { $0.t }) {
        var host: [String: Any] = [
            "sampleTime": iso(p.t),
            "allocatableMemoryGB": r3(p.allocatable / gib),
            "memoryUsedOutsideVMsGB": r3(p.other / gib),
            "memoryUsedGB": r3(p.used / gib),
            "totalMemoryGB": r3(Double(HostStats.totalMemory) / gib),
            "memoryPressure": p.pressure == 2 ? "critical" : p.pressure == 1 ? "warning" : "normal",
            "swapUsedGB": r3(p.swapUsed / gib), "swapTotalGB": r3(p.swapTotal / gib),
            "coresAllocatedToVMs": p.cores, "physicalCores": HostStats.physicalCores,
        ]
        if let cpu = p.cpu { host["cpuCoresBusy"] = r3(cpu) }
        out["host"] = host
    } else {
        out["host"] = "no sample within 30 s of this time: the Mac was asleep or UTM Watch was not running"
    }
    var net: [String: Any] = [:]
    if let l = nearest(h.link, t, within: 45_000, time: { $0.t }) { net["link"] = linkJSON(l) }
    for (name, target) in [("routerPing", ProbeTarget.gateway), ("internetPing", ProbeTarget.internet)] {
        if let p = nearest(h.probes[target] ?? [], t, within: 30_000, time: { $0.t }) {
            net[name + (p.rtt == nil ? "" : "Ms")] = p.rtt.map { r3($0) as Any } ?? "no reply"
        }
    }
    if !net.isEmpty { out["network"] = net }
    return out
}

// MARK: - Tools

let timeHelp = "ISO 8601 (2026-11-10T21:40:00+08:00), local time (2026-11-10 21:40), relative (-2h, -30m, -7d) or \"now\"."

let tools: [[String: Any]] = [
    ["name": "find_incidents",
     "description": "Start here when someone reports slowness but cannot say when. Returns the periods in a time range where something was abnormal, most severe first: a local network that is uneven throughout, slow or lost pings to a VM, to the router or to the internet (many brief spikes are folded into one entry with a count), weak Wi-Fi, the Mac asleep or not recording, memory pressure, swap above 80%, a VM held at its CPU limit. Each incident says which segment was affected (mac, vm:<name>, wifi, lan, internet), carries nearby events with the busiest processes captured at the time, and flags whether a remote session was probably active (inferred from sustained upload from a VM; a heuristic).",
     "inputSchema": ["type": "object", "properties": [
        "from": ["type": "string", "description": "Start of the range. Default -24h. " + timeHelp],
        "to": ["type": "string", "description": "End of the range. Default now."]]]],
    ["name": "get_status",
     "description": "The latest recorded sample (at most about 10 seconds old while UTM Watch is running): each VM's CPU, memory, network, disk and ping time, the Mac's memory headroom, swap, memory pressure and CPU load, and its network link with router and internet ping.",
     "inputSchema": ["type": "object", "properties": [String: Any]()]],
    ["name": "list_events",
     "description": "Timeline events in a range: VM started or stopped, memory pressure changes, swap above 80%, a VM at its CPU limit, Wi-Fi weak or recovered, network link changed or down, Mac went to sleep or woke. Warning events include the busiest processes recorded when they fired.",
     "inputSchema": ["type": "object", "properties": [
        "from": ["type": "string", "description": "Start of the range. Default -24h. " + timeHelp],
        "to": ["type": "string", "description": "End of the range. Default now."]]]],
    ["name": "summarize",
     "description": "Compact statistics for a range: per VM the average, peak and peak time of CPU, memory, network, disk and ping; for the Mac time under memory pressure, swap, memory used outside the VMs and CPU load; for the network router and internet ping with loss, and link quality. Use it to compare a suspect period with a normal one.",
     "inputSchema": ["type": "object", "properties": [
        "from": ["type": "string", "description": "Start of the range. " + timeHelp],
        "to": ["type": "string", "description": "End of the range. Default now."]], "required": ["from"]]],
    ["name": "get_moment",
     "description": "Every recorded value at one moment (nearest sample within 30 seconds), like pinning that moment in UTM Watch's detail window, plus the events within five minutes of it.",
     "inputSchema": ["type": "object", "properties": ["time": ["type": "string", "description": timeHelp]], "required": ["time"]]],
    ["name": "get_metrics",
     "description": "The trend of one metric over a range, reduced to a chosen number of points with the average and peak of each. Metrics per VM: cpu (cores), memory (GB), download, upload, disk_read, disk_write (MB/s), ping (ms from the Mac to the VM). For ping, the target may also be \"router\", \"internet\" (the faster of the servers each round), or one server's address as listed by summarize.",
     "inputSchema": ["type": "object", "properties": [
        "metric": ["type": "string", "enum": ["cpu", "memory", "download", "upload", "disk_read", "disk_write", "ping"]],
        "vm": ["type": "string", "description": "VM name as shown in UTM, or \"router\" / \"internet\" for ping."],
        "from": ["type": "string", "description": "Start of the range. " + timeHelp],
        "to": ["type": "string", "description": "End of the range. Default now."],
        "points": ["type": "integer", "description": "How many points to return, 10 to 500. Default 120."]],
        "required": ["metric", "vm", "from"]]],
]

func callTool(_ name: String, _ args: [String: Any]) throws -> Any {
    let now = Date().msSince1970
    let store = try openStore()
    switch name {
    case "get_status":
        let h = store.load(from: now - 90_000, to: now, maxPoints: nil)
        guard let last = h.host.last else {
            return ["note": "No samples in the last 90 seconds: UTM Watch is not running, or the Mac has just woken up.",
                    "knownVMs": store.knownVMs().map(\.name)]
        }
        var out = momentJSON(h, at: last.t)
        out["sampleAgeSeconds"] = Int((now - last.t) / 1000)
        return out

    case "list_events":
        let (from, to) = try range(args, defaultFrom: "-24h", now: now)
        let h = store.load(from: from, to: to, maxPoints: 10)
        let names = Dictionary(store.knownVMs().map { ($0.key, $0.name) }, uniquingKeysWith: { a, _ in a })
        // The process list is repeated only when it actually changed, or after ten minutes.
        var lastSignature: String?, lastShown: Int64 = 0
        let events = h.events.suffix(300).map { e -> [String: Any] in
            var d = eventJSON(e, names: names)
            if let sig = processSignature(e.detail) {
                if sig == lastSignature, e.ts - lastShown < 10 * 60_000 {
                    d["processesAtTheTime"] = "same as the previous event that lists them"
                } else {
                    lastSignature = sig; lastShown = e.ts
                }
            }
            return d
        }
        return ["from": iso(from), "to": iso(to), "count": h.events.count, "events": events]

    case "summarize":
        let (from, to) = try range(args, defaultFrom: "-1h", now: now)
        return Diagnostics.summary(store.load(from: from, to: to, maxPoints: analysisPoints(from, to)))

    case "get_moment":
        let t = try parseTime(args["time"], now: now)
        let h = store.load(from: t - 300_000, to: t + 300_000, maxPoints: nil)
        var out = momentJSON(h, at: t)
        let names = Dictionary(h.vms.map { ($0.key, $0.name) }, uniquingKeysWith: { a, _ in a })
        out["eventsWithinFiveMinutes"] = h.events.map { eventJSON($0, names: names) }
        return out

    case "get_metrics":
        guard let metric = args["metric"] as? String else { throw ToolError(message: "\"metric\" is required") }
        guard let target = args["vm"] as? String else { throw ToolError(message: "\"vm\" is required") }
        let (from, to) = try range(args, defaultFrom: "-1h", now: now)
        let points = min(500, max(10, (args["points"] as? Int) ?? 120))
        let h = store.load(from: from, to: to, maxPoints: points)
        var out: [String: Any] = ["metric": metric, "from": iso(from), "to": iso(to), "pointSeconds": Int(h.bucketMs / 1000)]
        if metric == "ping" {
            let key: String
            switch target.lowercased() {
            case "router", "gateway": key = ProbeTarget.gateway
            case "internet": key = ProbeTarget.internet
            case let address where h.probes[ProbeTarget.anchor(address)] != nil: key = ProbeTarget.anchor(address)
            default:
                guard let vm = h.vms.first(where: { $0.name.caseInsensitiveCompare(target) == .orderedSame }) else {
                    throw ToolError(message: "No VM named \"\(target)\" in this range. Known: \(store.knownVMs().map(\.name).joined(separator: ", ")), router, internet.")
                }
                key = ProbeTarget.vm(vm.key)
            }
            out["target"] = target; out["unit"] = "ms"
            out["points"] = (h.probes[key] ?? []).map { p -> [String: Any] in
                var d: [String: Any] = ["t": iso(p.t), "sent": p.sent, "lost": p.lost]
                if let v = p.rtt { d["avg"] = r3(v) }
                if let v = p.rttMax { d["peak"] = r3(v) }
                return d
            }
            return out
        }
        guard let vm = h.vms.first(where: { $0.name.caseInsensitiveCompare(target) == .orderedSame }) else {
            throw ToolError(message: "No VM named \"\(target)\" has data in this range. Known VMs: \(store.knownVMs().map(\.name).joined(separator: ", ")).")
        }
        let pick: (VMPoint) -> (Double?, Double?)
        switch metric {
        case "cpu": out["unit"] = "cores"; pick = { ($0.cpu, $0.cpuMax) }
        case "memory": out["unit"] = "GB"; pick = { ($0.mem.map { $0 / gib }, nil) }
        case "download": out["unit"] = "MB/s"; pick = { ($0.down.map { $0 / 1e6 }, $0.downMax.map { $0 / 1e6 }) }
        case "upload": out["unit"] = "MB/s"; pick = { ($0.up.map { $0 / 1e6 }, $0.upMax.map { $0 / 1e6 }) }
        case "disk_read": out["unit"] = "MB/s"; pick = { ($0.diskRead.map { $0 / 1e6 }, nil) }
        case "disk_write": out["unit"] = "MB/s"; pick = { ($0.diskWrite.map { $0 / 1e6 }, nil) }
        default: throw ToolError(message: "Unknown metric \"\(metric)\". Use cpu, memory, download, upload, disk_read, disk_write or ping.")
        }
        out["vm"] = vm.name
        out["points"] = (h.series[vm.key] ?? []).compactMap { p -> [String: Any]? in
            let (avg, peak) = pick(p)
            guard let avg else { return nil }
            var d: [String: Any] = ["t": iso(p.t), "avg": r3(avg)]
            if let peak, peak != avg { d["peak"] = r3(peak) }
            return d
        }
        return out

    case "find_incidents":
        let (from, to) = try range(args, defaultFrom: "-24h", now: now)
        let h = store.load(from: from, to: to, maxPoints: analysisPoints(from, to))
        let names = Dictionary(h.vms.map { ($0.key, $0.name) }, uniquingKeysWith: { a, _ in a })
        let incidents = Diagnostics.incidents(h).map { i -> [String: Any] in
            var d: [String: Any] = [
                "from": iso(i.from), "to": iso(i.to), "durationSeconds": Int((i.to - i.from) / 1000),
                "kind": i.kind, "segment": i.segment, "summary": i.summary, "remoteSessionLikely": i.remoteSessionLikely,
            ]
            if i.occurrences > 1 { d["occurrences"] = i.occurrences }
            // Events are attached only to a single, bounded incident; for a pattern spread over hours they would be noise.
            let bounded = i.occurrences == 1 && i.kind != "local_network_jitter" && i.to - i.from <= 3 * 3600_000
            let near = bounded ? h.events.filter { $0.ts >= i.from - 120_000 && $0.ts <= i.to + 120_000 } : []
            if !near.isEmpty {
                d["relatedEvents"] = Array(groupedEvents(near, names: names).prefix(8))
                // One process list per incident: the first one captured, when the trouble began.
                if let first = near.first(where: { $0.detail != nil }), let detail = parsedDetail(first.detail) {
                    d["processesWhenItBegan"] = detail
                }
            }
            return d
        }
        var out: [String: Any] = [
            "from": iso(from), "to": iso(to), "resolutionSeconds": Int(h.bucketMs / 1000), "incidents": incidents,
            "notes": [
                "remoteSessionLikely is inferred from sustained upload from a VM, not from the remote-desktop software itself.",
                "Not visible from here: the client's own network, the remote-desktop service's relay servers, and anything slow inside a VM after a connection is established.",
            ],
        ]
        if let first = h.host.first, let last = h.host.last {
            out["recordedCoverage"] = ["firstSample": iso(first.t), "lastSample": iso(last.t)]
        } else {
            out["recordedCoverage"] = "no samples recorded in this range"
        }
        if incidents.isEmpty { out["conclusion"] = "Nothing abnormal was recorded on this Mac, its link or its uplink in this range." }
        return out

    default:
        throw ToolError(message: "Unknown tool \"\(name)\"")
    }
}

// MARK: - Main loop

while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty, let data = line.data(using: .utf8),
          let msg = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
    let method = msg["method"] as? String ?? ""
    guard let id = msg["id"] else { continue } // notifications need no reply
    let params = msg["params"] as? [String: Any] ?? [:]
    switch method {
    case "initialize":
        reply(id, [
            "protocolVersion": (params["protocolVersion"] as? String) ?? "2025-06-18",
            "capabilities": ["tools": [String: Any]()],
            "serverInfo": ["name": "utm-watch", "version": serverVersion],
            "instructions": "Read-only access to UTM Watch's recorded history on this Mac: per-VM CPU, memory, network, disk and ping, host memory and CPU, network link quality, and timeline events. When someone reports slowness without a time, call find_incidents first, then get_moment or summarize on what it returns.",
        ])
    case "ping":
        reply(id, [:])
    case "tools/list":
        reply(id, ["tools": tools])
    case "tools/call":
        let name = params["name"] as? String ?? ""
        let args = params["arguments"] as? [String: Any] ?? [:]
        do {
            let result = try callTool(name, args)
            reply(id, ["content": [["type": "text", "text": try compactJSON(result)]], "isError": false])
        } catch let e as ToolError {
            reply(id, ["content": [["type": "text", "text": e.message]], "isError": true])
        } catch {
            reply(id, ["content": [["type": "text", "text": "Internal error: \(error)"]], "isError": true])
        }
    default:
        fail(id, -32601, "Method not found: \(method)")
    }
}
