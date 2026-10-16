// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PulseSync",
    platforms: [.macOS(.v14), .iOS(.v18)],
    products: [
        .library(name: "PulseSync", targets: ["PulseSync"])
    ],
    dependencies: [
        .package(path: "../PulseCore")
    ],
    targets: [
        .target(
            name: "PulseSync",
            dependencies: [
                .product(name: "PulseCore", package: "PulseCore")
            ]
        ),
        .testTarget(name: "PulseSyncTests", dependencies: ["PulseSync"])
    ]
)
