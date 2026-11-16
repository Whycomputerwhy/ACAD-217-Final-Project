// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RealityKitContent",
    platforms: [.visionOS(.v2)],
    products: [
        .library(name: "RealityKitContent", targets: ["RealityKitContent"])
    ],
    targets: [
        .target(name: "RealityKitContent")
    ]
)

