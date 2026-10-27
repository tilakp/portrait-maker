// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "PortraitMaker",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "PortraitMaker"),
        .testTarget(name: "PortraitMakerTests", dependencies: ["PortraitMaker"], path: "Tests/PortraitMakerTests"),
    ]
)
