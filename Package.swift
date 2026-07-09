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
    // Package-level platforms set the *minimum* per-OS deployment target. iOS is declared so the
    // client-safe OrchestraKit target can be compiled against the iOS SDK (scripts/typecheck-kit-ios.sh);
    // the daemon executables are never asked to build for iOS, so this does not make them iOS products.
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "OrchestraKit", targets: ["OrchestraKit"]),
        // Shared SwiftUI layer (Theme + BoardModel + platform protocols). macOS + iOS only; NEVER
        // linked by orchestrad/CLI/MCP, so it is never compiled for Linux (keeps SwiftUI off Linux).
        .library(name: "OrchestraUI", targets: ["OrchestraUI"]),
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
            name: "OrchestraKit",
            // Client-safe: Foundation + POSIX only. Platforms include iOS so a phone client links it.
            // MUST NOT gain Foundation.Process / posix_spawn / AppKit / UIKit references
            // (verified by scripts/typecheck-kit-ios.sh).
            swiftSettings: []
        ),
        .target(
            // Shared SwiftUI view-model + design tokens + the four platform protocols. Depends only on
            // the client-safe OrchestraKit. The macOS-only host/daemon machinery it carries is fenced
            // with `#if os(macOS)`; on macOS those fences resolve against OrchestraCore, pulled in via a
            // platform-conditional dependency so iOS/Linux never see it. (Added in the BoardModel move.)
            name: "OrchestraUI",
            dependencies: [
                "OrchestraKit",
                .target(name: "OrchestraCore", condition: .when(platforms: [.macOS])),
            ]
        ),
        .target(
            name: "OrchestraCore",
            dependencies: ["OrchestraKit"],
            resources: [
                .copy("Resources/embedded.conf"),
                .copy("Resources/claude-hooks.json"),
                .copy("Resources/codex-hooks.json"),
                .copy("Resources/claude-code-models.json"),
                .copy("Resources/codex-models.json"),
                .copy("Resources/com.orchestra.daemon.plist"),
                .copy("Resources/delegation-skill.md"),
                .copy("Resources/delegation-agents.md"),
                .copy("Resources/tree-skill.md"),
                .copy("Resources/tree-agents.md"),
            ]
        ),
        .executableTarget(name: "orchestrad", dependencies: ["OrchestraCore"]),
        .executableTarget(name: "orchestra", dependencies: ["OrchestraCore"]),
        .executableTarget(
            name: "orchestra-mcp",
            // D4: the MCP bridge references only client-safe types (CommandCatalog/ControlClient/
            // Config/JSONValue/RPCError/OrchestraJSON/OrchestraVersion) — all in OrchestraKit.
            dependencies: ["OrchestraKit", .product(name: "MCP", package: "swift-sdk")]
        ),
        .testTarget(
            name: "OrchestraCoreTests",
            // OrchestraKit is a direct dep so tests can `@testable import OrchestraKit` for the few
            // internal helpers (e.g. Config.dataDir(isLinux:home:env:)) that moved to Kit in F1 —
            // keeping those helpers internal instead of forcing them into Kit's public surface.
            dependencies: ["OrchestraCore", "OrchestraKit"]
        ),
        .testTarget(
            name: "IntegrationTests",
            dependencies: ["OrchestraCore", "OrchestraKit"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "OrchestraUITests",
            dependencies: ["OrchestraUI", "OrchestraKit"]
        ),
    ]
)
