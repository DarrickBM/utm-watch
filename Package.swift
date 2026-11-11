// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "UTMWatch",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "UTMWatchCore", targets: ["UTMWatchCore"]),
        .executable(name: "utmwatch", targets: ["utmwatch"]),
    ],
    targets: [
        .target(name: "CSysShim"),
        .target(name: "UTMWatchCore", dependencies: ["CSysShim"]),
        .executableTarget(name: "utmwatch", dependencies: ["UTMWatchCore"]),
        // Menu bar app. Packaged into UTMWatch.app by Scripts/make-app.sh.
        .target(name: "UTMWatchStore", dependencies: ["UTMWatchCore"]),
        .executableTarget(name: "UTMWatchApp", dependencies: ["UTMWatchCore", "UTMWatchStore"]),
        // MCP server over stdio: lets an AI agent read the recorded history. Shipped inside the app bundle.
        .executableTarget(name: "utmwatch-mcp", dependencies: ["UTMWatchCore", "UTMWatchStore"]),
        // Unit checks as a plain executable: Command Line Tools ship neither XCTest nor Swift Testing.
        .executableTarget(name: "selftest", dependencies: ["UTMWatchCore", "UTMWatchStore"]),
    ]
)
