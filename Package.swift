// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AgentIsland",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AgentIsland", targets: ["AgentIsland"]),
        .executable(name: "agent-island-hook", targets: ["AgentIslandHook"]),
    ],
    targets: [
        .target(name: "IslandCore"),
        .target(name: "IslandIntegrations", dependencies: ["IslandCore"]),
        .executableTarget(name: "AgentIsland", dependencies: ["IslandCore", "IslandIntegrations"]),
        .executableTarget(name: "AgentIslandHook", dependencies: ["IslandCore", "IslandIntegrations"]),
        .testTarget(name: "IslandCoreTests", dependencies: ["IslandCore"]),
        .testTarget(name: "IslandIntegrationsTests", dependencies: ["IslandIntegrations", "IslandCore"]),
        .testTarget(name: "IslandAppTests", dependencies: ["AgentIsland", "IslandCore"])
    ]
)
