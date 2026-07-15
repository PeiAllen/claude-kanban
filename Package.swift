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
        // Test-only. A load-time constructor that makes the test bundle hermetic w.r.t. git (no
        // system/global config, no credential helper, no prompts, fixed identity), so the ~116 git
        // forks a test run makes — from tests AND from the production code under test, all via
        // Proc.run — can never read the developer's ~/.gitconfig. It lives under Tests/ and is
        // depended on ONLY by the test targets, so it cannot reach orchestrad/orchestra/orchestra-mcp:
        // production still reads the user's real gitconfig. See Tests/GitHermeticBootstrap/bootstrap.c
        // and notes/designs/2026-07-11-test-suite-git-hermeticity.md.
        //
        // NEVER add this to a non-test target's dependencies — that is the one thing that would let it
        // reach production. All three test targets list it, even OrchestraUITests, which forks no git:
        // SwiftPM merges every test target into ONE bundle today, so a single dependency would in fact
        // suffice — declaring it on all three is cheap insurance against a future SwiftPM that builds a
        // bundle per test target.
        .target(name: "GitHermeticBootstrap", path: "Tests/GitHermeticBootstrap"),
        // Pure test-support code shared by every test target: the fake clock, the gateable
        // fake process runner, and the yield-based wait helper. Depends on OrchestraCore only
        // for ProcResult/ProcRunning. NEVER a dependency of a product target.
        .target(name: "TestSupport",
                dependencies: ["OrchestraCore"],
                path: "Tests/TestSupport"),
        // The FAST tier: pure unit tests (FakeProc, per-test roots, no real git/tmux fork), mirroring
        // Sources/ under Tests/UnitTests/. This is what `./scripts/test.sh` runs by default.
        .testTarget(
            name: "UnitTests",
            // OrchestraKit is a direct dep so tests can `@testable import OrchestraKit` for the few
            // internal helpers (e.g. Config.dataDir(isLinux:home:env:)) that moved to Kit in F1 —
            // keeping those helpers internal instead of forcing them into Kit's public surface.
            dependencies: ["OrchestraCore", "OrchestraKit", "OrchestraUI",
                           "TestSupport", "GitHermeticBootstrap"],
            path: "Tests/UnitTests"
        ),
        // The CONTRACT tier: real git / real tmux / real fds, pinning the fidelity the unit fakes stand
        // in for. Selected via `./scripts/test.sh --contract`.
        .testTarget(
            name: "ContractTests",
            dependencies: ["OrchestraCore", "OrchestraKit",
                           "TestSupport", "GitHermeticBootstrap"],
            path: "Tests/ContractTests",
            resources: [.copy("Fixtures")]
        ),
        // The E2E tier: built binaries + slow-repo fixture. Selected via `./scripts/test.sh --e2e`.
        .testTarget(
            name: "E2ETests",
            dependencies: ["OrchestraCore", "OrchestraKit",
                           "TestSupport", "GitHermeticBootstrap"],
            path: "Tests/E2ETests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
