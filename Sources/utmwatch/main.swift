import Foundation
import UTMWatchCore

if CommandLine.arguments.contains("--probe") {
    // Diagnostic: one round of the connection-quality probes plus the busiest processes.
    let engine = MonitorEngine()
    _ = engine.tick(interval: 1); Thread.sleep(forTimeInterval: 2.5); let snap = engine.tick(interval: 1)
    print("targets:", engine.networkTargets().map { "\($0.name) \($0.macs)" })
    let result = NetProbe().run(targets: engine.networkTargets())
    print("link:", result.link)
    print("gateway ms:", result.gatewayMs.map { String(format: "%.1f", $0) } ?? "no reply", "| internet ms:", result.internetMs.map { String(format: "%.1f", $0) } ?? "no reply")
    for (key, rtt) in result.vmPing { print("vm ping:", (key as NSString).lastPathComponent, rtt.map { String(format: "%.2f ms", $0) } ?? "no reply") }
    print("host CPU cores:", snap.host.hostCPUCores.map { String(format: "%.1f", $0) } ?? "-")
    for r in snap.rows where r.pid != nil { print("disk:", r.name, "read", Format.rate(r.diskReadRate, units: .bytes), "write", Format.rate(r.diskWriteRate, units: .bytes)) }
    let top = ProcessTop.capture()
    print("top memory:", top.byMemory.map { "\($0.name) \(Format.memory($0.memoryBytes))" }.joined(separator: ", "))
    print("top CPU:", top.byCPU.map { "\($0.name) \($0.cpuCores)" }.joined(separator: ", "))
    exit(0)
}
if CommandLine.arguments.dropFirst().first == "fleet" { FleetCommand.run(Array(CommandLine.arguments.dropFirst(2))) }
let options = CLIOptions.parse(CommandLine.arguments)
if let path = options.logPath { FileLog.shared.open(path: path) }
if options.once {
    OnceRunner.run(options: options)
} else {
    App(options: options).run()
}
