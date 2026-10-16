// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PulseMobile",
    platforms: [.macOS(.v14), .iOS(.v18)],
    products: [
        .library(name: "PulseMobile", targets: ["PulseMobile"])
    ],
    dependencies: [
        .package(path: "../PulseCore")
    ],
    targets: [
        .target(name: "PulseMobile", dependencies: ["PulseCore"]),
        .testTarget(name: "PulseMobileTests", dependencies: ["PulseMobile", "PulseCore"])
    ]
)
