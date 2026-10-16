// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PulseActivity",
    platforms: [.macOS(.v14), .iOS(.v18)],
    products: [
        .library(name: "PulseActivity", targets: ["PulseActivity"])
    ],
    targets: [
        .target(name: "PulseActivity"),
        .testTarget(name: "PulseActivityTests", dependencies: ["PulseActivity"])
    ]
)
