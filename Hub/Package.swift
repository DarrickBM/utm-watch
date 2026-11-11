// swift-tools-version:5.10
import PackageDescription

// The fleet hub's HTTP server. It lives in its own package so that its dependency on Hummingbird (and through it
// swift-nio) never reaches the Mac app, which builds from the root package with no third-party code.
// All hub logic is in the root package's UTMWatchFleet; this is only the network shell and the command line.
let package = Package(
    name: "UTMWatchHub",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(name: "UTMWatch", path: ".."),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
    ],
    targets: [
        .executableTarget(name: "utmwatch-hub", dependencies: [
            .product(name: "UTMWatchFleet", package: "UTMWatch"),
            .product(name: "UTMWatchStore", package: "UTMWatch"),
            .product(name: "UTMWatchModel", package: "UTMWatch"),
            .product(name: "Hummingbird", package: "hummingbird"),
        ]),
    ]
)
