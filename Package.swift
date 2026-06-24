// swift-tools-version: 6.0
import PackageDescription

// Orchestra — a local-only macOS agent-orchestration board.
//
// The buildable/testable surface is dependency-free so it compiles offline:
//   * OrchestraCore  — the shared library (all business logic, fully unit-tested)
//   * orchestrad     — the background daemon (launchd LaunchAgent)
//   * orchestra      — the CLI client
//   * orchestra-mcp  — the MCP stdio bridge (hand-rolled JSON-RPC, no SDK dependency)
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
    targets: [
        .target(
            name: "OrchestraCore",
            resources: [
                .copy("Resources/embedded.conf"),
                .copy("Resources/claude-hooks.json"),
                .copy("Resources/com.orchestra.daemon.plist"),
            ]
        ),
        .executableTarget(name: "orchestrad", dependencies: ["OrchestraCore"]),
        .executableTarget(name: "orchestra", dependencies: ["OrchestraCore"]),
        .executableTarget(name: "orchestra-mcp", dependencies: ["OrchestraCore"]),
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
