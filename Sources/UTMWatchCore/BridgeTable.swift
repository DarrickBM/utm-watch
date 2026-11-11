import Foundation

/// Maps VM MAC addresses to `vmenetN` members by reading the bridge's learned-address table.
public enum BridgeTable {
    /// Parses the "Address cache:" section of `ifconfig bridgeN` output into MAC -> interface.
    public static func parseAddressCache(_ output: String) -> [String: String] {
        var result: [String: String] = [:]
        var inCache = false
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Address cache:") { inCache = true; continue }
            guard inCache else { continue }
            // Lines look like: "02:1a:2b:3c:4d:5e Vlan1 vmenet1 1200 flags=0<>"
            let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard fields.count >= 3, fields[0].filter({ $0 == ":" }).count == 5 else {
                inCache = false // left the indented block
                continue
            }
            // Column layout: <mac> <vlan> <member interface> <age> <flags>
            result[MACAddress.normalize(fields[0])] = fields[2]
        }
        return result
    }

    /// Bridge interfaces created by the Virtualization framework (bridge100, bridge101, ...).
    public static func vmBridges(from interfaceNames: some Sequence<String>) -> [String] {
        interfaceNames.filter { $0.hasPrefix("bridge") && Int($0.dropFirst(6)).map { $0 >= 100 } == true }.sorted()
    }

    public static func read(bridges: [String]) -> [String: String] {
        var merged: [String: String] = [:]
        for bridge in bridges {
            let result = Shell.run("/sbin/ifconfig", [bridge], timeout: 3)
            guard result.status == 0 else {
                FileLog.shared.log("ifconfig \(bridge) failed: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
                continue
            }
            merged.merge(parseAddressCache(result.stdout)) { _, new in new }
        }
        return merged
    }
}
