import Foundation
import UTMWatchCore

struct CLIOptions {
    var interval: RefreshInterval = .two
    var once = false
    var json = false
    var units: RateUnits = .bytes
    var showStopped = true
    var logPath: String?
    var swapDirections = false
    var noUTM = false

    static let usage = """
    utmwatch — per-VM CPU, memory and network for UTM virtual machines

    USAGE: utmwatch [options]

    OPTIONS:
      --interval <1|2|5>   Refresh interval in seconds (default 2)
      --once               Print one table and exit (samples twice, <interval> apart)
      --json               With --once: print the snapshot as JSON
      --units <mb|mbps>    Network units: MB/s (default) or Mbps
      --hide-stopped       Start with stopped VMs hidden
      --no-utm             Skip the UTM AppleScript query (names from .utm bundles only)
      --swap-directions    Treat vmenet in/out the other way round (see README, R1)
      --log <path>         Append collector errors to this file
      -h, --help           Show this help

    KEYS (interactive):
      1 2 5  refresh interval      s  cycle sort (name, cpu, mem, net)
      h      hide/show stopped     u  toggle MB/s / Mbps
      r      refresh VM list now   q  quit
    """

    static func parse(_ args: [String]) -> CLIOptions {
        var o = CLIOptions()
        var it = args.dropFirst().makeIterator()
        func fail(_ msg: String) -> Never {
            FileHandle.standardError.write(Data("utmwatch: \(msg)\n\n\(usage)\n".utf8)); exit(2)
        }
        while let a = it.next() {
            switch a {
            case "-h", "--help": print(usage); exit(0)
            case "--interval":
                guard let v = it.next(), let n = Int(v), let r = RefreshInterval(rawValue: n) else { fail("--interval must be 1, 2 or 5") }
                o.interval = r
            case "--once": o.once = true
            case "--json": o.json = true
            case "--units":
                guard let v = it.next() else { fail("--units needs a value") }
                switch v.lowercased() {
                case "mb", "mb/s", "bytes": o.units = .bytes
                case "mbps", "bits": o.units = .bits
                default: fail("--units must be mb or mbps")
                }
            case "--hide-stopped": o.showStopped = false
            case "--no-utm": o.noUTM = true
            case "--swap-directions": o.swapDirections = true
            case "--log":
                guard let v = it.next() else { fail("--log needs a path") }
                o.logPath = v
            default: fail("unknown option \(a)")
            }
        }
        if o.json && !o.once { fail("--json requires --once") }
        return o
    }
}
