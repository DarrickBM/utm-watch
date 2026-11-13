// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "UTMWatch",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "UTMWatchCore", targets: ["UTMWatchCore"]),
        .library(name: "UTMWatchModel", targets: ["UTMWatchModel"]),
        .library(name: "UTMWatchStore", targets: ["UTMWatchStore"]),
        .library(name: "UTMWatchFleet", targets: ["UTMWatchFleet"]),
    ],
    targets: [
        .target(name: "CSysShim"),
        // Foundation-only types shared by the app, the store and the hub. Builds on Linux.
        .target(name: "UTMWatchModel"),
        // System SQLite for Linux; macOS uses the SDK's SQLite3 module.
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3", providers: [.apt(["libsqlite3-dev"])]),
        .target(name: "UTMWatchCore", dependencies: ["CSysShim", "UTMWatchModel"]),
        // Menu bar app. Packaged into UTMWatch.app by Scripts/make-app.sh.
        .target(name: "UTMWatchStore", dependencies: [
            "UTMWatchModel", .target(name: "CSQLite", condition: .when(platforms: [.linux])),
        ]),
        // Fleet: the hub's API and the client side of it. Foundation only, so the hub can build on Linux.
        .target(name: "UTMWatchFleet", dependencies: ["UTMWatchModel", "UTMWatchStore"]),
        .executableTarget(name: "UTMWatchApp", dependencies: ["UTMWatchCore", "UTMWatchStore", "UTMWatchFleet"]),
        // MCP server over stdio: lets an AI agent read the recorded history. Shipped inside the app bundle.
        .executableTarget(name: "utmwatch-mcp", dependencies: ["UTMWatchCore", "UTMWatchStore", "UTMWatchFleet"]),
        // Unit checks as a plain executable: Command Line Tools ship neither XCTest nor Swift Testing.
        .executableTarget(name: "selftest", dependencies: ["UTMWatchCore", "UTMWatchStore", "UTMWatchFleet"]),
    ]
)
