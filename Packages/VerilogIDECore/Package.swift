// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VerilogIDECore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "VerilogIDECore", targets: ["VerilogIDECore"])
    ],
    targets: [
        .target(name: "VerilogIDECore"),
        .testTarget(name: "VerilogIDECoreTests", dependencies: ["VerilogIDECore"])
    ]
)
