// swift-tools-version: 6.0
import PackageDescription

// Orchestra — a local-only macOS agent-orchestration board.
//
// The core, daemon, and CLI are dependency-free (offline builds). Only orchestra-mcp pulls a
// dependency (the official MCP swift-sdk), so the first build needs network to resolve it.
//   * OrchestraCore  — the shared library (all business logic, fully unit-tested)
//   * orchestrad     — the background daemon (launchd LaunchAgent)
//   * orchestra      — the CLI client
//   * orchestra-mcp  — the MCP stdio bridge (official modelcontextprotocol/swift-sdk)
//
// The SwiftUI app (App/) is built separately (it needs SwiftTerm + an app bundle); it is
// intentionally NOT a SwiftPM target here so `swift build` / `swift test` stay offline-green.
let package = Package(
    name: "Orchestra",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OrchestraCore", targets: ["OrchestraCore"]),
        .executable(name: "orchestrad", targets: ["orchestrad"]),
        .executable(name: "orchestra", targets: ["orchestra"]),
        .executable(name: "orchestra-mcp", targets: ["orchestra-mcp"]),
    ],
    dependencies: [
        // Used ONLY by the orchestra-mcp target — the core/daemon/CLI stay dependency-free so they
        // build offline. Run `swift build` once with network access to populate Package.resolved.
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk", from: "0.9.0"),
    ],
    targets: [
        .target(
            name: "OrchestraCore",
            resources: [
                .copy("Resources/embedded.conf"),
                .copy("Resources/claude-hooks.json"),
                .copy("Resources/claude-code-models.json"),
                .copy("Resources/com.orchestra.daemon.plist"),
            ]
        ),
        .executableTarget(name: "orchestrad", dependencies: ["OrchestraCore"]),
        .executableTarget(name: "orchestra", dependencies: ["OrchestraCore"]),
        .executableTarget(
            name: "orchestra-mcp",
            dependencies: ["OrchestraCore", .product(name: "MCP", package: "swift-sdk")]
        ),
        .testTarget(
            name: "OrchestraCoreTests",
            dependencies: ["OrchestraCore"]
        ),
        .testTarget(
            name: "IntegrationTests",
            dependencies: ["OrchestraCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
