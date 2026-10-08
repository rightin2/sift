// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SiftCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "SiftCore", targets: ["SiftCore"])],
    targets: [
        .target(name: "SiftCore"),
        .testTarget(name: "SiftCoreTests", dependencies: ["SiftCore"]),
    ]
)
