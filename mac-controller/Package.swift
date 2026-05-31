// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacController",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "MacBridgeCore", targets: ["MacBridgeCore"]),
        .executable(name: "mac-controller", targets: ["MacController"]),
        .executable(name: "mac-controller-tests", targets: ["MacBridgeCoreTestRunner"])
    ],
    targets: [
        .target(name: "MacBridgeCore"),
        .executableTarget(
            name: "MacController",
            dependencies: ["MacBridgeCore"]
        ),
        .executableTarget(
            name: "MacBridgeCoreTestRunner",
            dependencies: ["MacBridgeCore"]
        )
    ]
)
