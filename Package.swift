// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AgentIsland",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "AgentIsland", targets: ["AgentIsland"])],
    targets: [
        .target(name: "IslandCore"),
        .executableTarget(name: "AgentIsland", dependencies: ["IslandCore"]),
        .testTarget(name: "IslandCoreTests", dependencies: ["IslandCore"]),
        .testTarget(name: "IslandAppTests", dependencies: ["AgentIsland", "IslandCore"])
    ]
)
