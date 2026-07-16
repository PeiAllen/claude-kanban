# Automatic Orchestra MCP Card Setup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Configure the local `orchestra` MCP server for every Claude and Codex card launch, with an opt-in add-only installer for missing global entries.

**Architecture:** Keep MCP serialization and global-file mutation in a focused `OrchestraCore` helper. Extend `AdapterContext` and the daemon's launch context with the resolved `orchestra-mcp` sibling path plus the persisted global-install flag; Claude emits inline `--mcp-config`, while Codex adds the server to its existing per-card profile. The global installer is invoked from each adapter's existing `prepareToLaunch` seam and fails closed for the optional global convenience step.

**Tech Stack:** Swift 6, Foundation `JSONSerialization`, existing Codex TOML emitter, Swift Testing, SwiftUI settings, Markdown docs.

## Global Constraints

- Use the canonical MCP server name `orchestra` for both agents.
- Local launch configuration must override a same-name global entry while preserving unrelated global servers.
- `autoInstallMCPGlobally` defaults to `false` and global installation is add-only; never replace an existing same-name entry.
- Resolve `orchestra-mcp` through the existing sibling-binary/PATH lookup and do not add a separate CLI installation mechanism.
- Preserve legacy `config.json` files by decoding a missing `autoInstallMCPGlobally` key as `false`.
- Follow the repository test script (`./scripts/test.sh`) and keep every test-first cycle visibly red before production code.

---

### Task 1: Define the persisted setting and launch-context seams

**Files:**
- Modify: `Sources/OrchestraKit/Config.swift`
- Modify: `Sources/OrchestraCore/Agents/Adapter.swift`
- Modify: `Sources/OrchestraCore/OrchestraService.swift`
- Modify: `Sources/OrchestraCore/OrchestraService+Converge.swift`
- Test: `Tests/UnitTests/OrchestraKit/ConfigTimeoutTests.swift`
- Test: `Tests/UnitTests/OrchestraCore/Agents/CapabilitiesTests.swift`

**Interfaces:**
- `Config.autoInstallMCPGlobally: Bool` is persisted and defaults to `false`.
- `AdapterContext.orchestraMCPBin: String` carries the resolved MCP executable path and defaults to `siblingBinary("orchestra-mcp")`.
- `AdapterContext.autoInstallMCPGlobally: Bool` carries the opt-in setting and defaults to `false`.
- `OrchestraService.orchestraMCPBin` is injected like `orchestraBin` and is copied into both blank and resume launch contexts.

- [ ] **Step 1: Write failing Codable and context tests.**

Add assertions that `Config()` disables global installation, a configured `Config(autoInstallMCPGlobally: true)` round-trips through JSON, and a legacy payload without the key decodes to `false`. Add context assertions such as:

```swift
@Test("MCP global installation defaults off and survives Codable")
func mcpGlobalInstallSettingRoundTrips() throws {
    #expect(Config().autoInstallMCPGlobally == false)
    let configured = Config(autoInstallMCPGlobally: true)
    #expect(try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(configured)) == configured)
}

@Test("AdapterContext carries the MCP executable and opt-in setting")
func mcpLaunchContext() {
    let context = AdapterContext(cwd: "/wt", orchestraMCPBin: "/bin/orchestra-mcp",
                                 autoInstallMCPGlobally: true)
    #expect(context.orchestraMCPBin == "/bin/orchestra-mcp")
    #expect(context.autoInstallMCPGlobally)
}
```

- [ ] **Step 2: Run the focused tests and verify the expected red failure.**

Run `./scripts/test.sh --filter ConfigTimeoutTests --filter CapabilitiesTests`. Expect compilation failures naming the missing setting and context parameters, rather than a test-runner or fixture failure.

- [ ] **Step 3: Add the Codable fields and thread the launch values.**

Add `autoInstallMCPGlobally` to `Config`, its initializer, `CodingKeys`, and custom decoder with `decodeIfPresent(... ) ?? false`. Add the two defaulted `AdapterContext` properties. Add an injected `orchestraMCPBin` property/initializer argument to `OrchestraService`, and include both values in the `.blank` and `.resume` contexts in `launchAndConfirm`:

```swift
let ctx = AdapterContext(
    cwd: task.cwd, repo: task.repo, model: launchModel, startIn: task.startIn,
    sessionId: task.agentSessionId, prompt: prompt, name: task.title,
    orchestraBin: orchestraBin, orchestraMCPBin: orchestraMCPBin,
    access: task.access, trustCwd: trustDecision == .trusted,
    autoInstallMCPGlobally: config.autoInstallMCPGlobally)
```

The resume context uses the same `orchestraMCPBin` and setting. Preserve the fields in the reduced contexts used by each adapter's `sessionInfo` so displayed resume commands use the same executable path.

- [ ] **Step 4: Run the focused tests and verify green.**

Run `./scripts/test.sh --filter ConfigTimeoutTests --filter CapabilitiesTests`. Expect all tests in both suites to pass.

- [ ] **Step 5: Commit the seam changes.**

```bash
git add Sources/OrchestraKit/Config.swift Sources/OrchestraCore/Agents/Adapter.swift Sources/OrchestraCore/OrchestraService.swift Sources/OrchestraCore/OrchestraService+Converge.swift Tests/UnitTests/OrchestraKit/ConfigTimeoutTests.swift Tests/UnitTests/OrchestraCore/Agents/CapabilitiesTests.swift
git commit -m "feat: add MCP launch configuration seams"
```

### Task 2: Add local MCP serialization and add-only global installers

**Files:**
- Create: `Sources/OrchestraCore/Agents/MCPConfiguration.swift`
- Create: `Tests/UnitTests/OrchestraCore/Agents/MCPConfigurationTests.swift`

**Interfaces:**
- `MCPConfiguration.serverName == "orchestra"`.
- `MCPConfiguration.claudeJSON(command:) -> String` returns the inline Claude `--mcp-config` JSON.
- `MCPConfiguration.codexTOML(command:) -> String` returns the Codex `[mcp_servers.orchestra]` table.
- `MCPConfiguration.installClaudeGlobally(command:at:) -> Bool` adds the missing entry to a Claude global JSON file and returns whether it changed the file.
- `MCPConfiguration.installCodexGlobally(command:at:) -> Bool` appends the missing Codex table and returns whether it changed the file.

- [ ] **Step 1: Write failing serialization and installer tests.**

Create a temporary directory per test. Parse Claude JSON with `JSONSerialization` and assert the `mcpServers.orchestra.type`, `command`, and empty `args`; assert Codex TOML contains the exact table and escaped command. For each global format test, cover missing file creation, unrelated settings preservation, and existing same-name byte-for-byte no-op:

```swift
private func temporaryFile(_ name: String) throws -> String {
    let root = NSTemporaryDirectory() + "mcp-config-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    return "\(root)/\(name)"
}

@Test("Claude global install adds orchestra without replacing unrelated servers")
func installClaudeGlobalAddsOnlyMissingServer() throws {
    let path = try temporaryFile("claude.json")
    defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
    try #require(MCPConfiguration.installClaudeGlobally(command: "/bin/orchestra-mcp", at: path))
    let before = try String(contentsOfFile: path, encoding: .utf8)
    #expect(before.contains("orchestra"))
    #expect(MCPConfiguration.installClaudeGlobally(command: "/other", at: path) == false)
    #expect(try String(contentsOfFile: path, encoding: .utf8) == before)
}

@Test("Codex global install appends once and preserves existing text")
func installCodexGlobalIsAddOnly() throws {
    let path = try temporaryFile("config.toml")
    defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
    try "model = \"gpt-5\"\n".write(toFile: path, atomically: true, encoding: .utf8)
    #expect(MCPConfiguration.installCodexGlobally(command: "/bin/orchestra-mcp", at: path))
    let once = try String(contentsOfFile: path, encoding: .utf8)
    #expect(once.hasPrefix("model = \"gpt-5\"\n"))
    #expect(MCPConfiguration.installCodexGlobally(command: "/other", at: path) == false)
    #expect(try String(contentsOfFile: path, encoding: .utf8) == once)
}
```

- [ ] **Step 2: Run the new tests and verify the expected red failure.**

Run `./scripts/test.sh --filter MCPConfigurationTests`. Expect compilation failures because the helper does not exist yet.

- [ ] **Step 3: Implement the focused helper.**

Build the Claude object with `JSONSerialization` and `.sortedKeys`, build Codex values through `TOMLOverride`, and write only after confirming the global entry is absent. Claude should return false for unreadable, non-object, or malformed existing content. Codex should detect canonical and quoted `mcp_servers.orchestra` table headers before appending. Use parent-directory creation plus atomic writes; never remove or rewrite an existing same-name entry.

- [ ] **Step 4: Run the new tests and verify green.**

Run `./scripts/test.sh --filter MCPConfigurationTests`. Expect all serialization and add-only cases to pass.

- [ ] **Step 5: Commit the helper.**

```bash
git add Sources/OrchestraCore/Agents/MCPConfiguration.swift Tests/UnitTests/OrchestraCore/Agents/MCPConfigurationTests.swift
git commit -m "feat: add MCP local and global configuration helpers"
```

### Task 3: Wire Claude and Codex launches to the MCP helper

**Files:**
- Modify: `Sources/OrchestraCore/Agents/ClaudeCodeAdapter.swift`
- Modify: `Sources/OrchestraCore/Agents/CodexAdapter.swift`
- Modify: `Sources/OrchestraCore/Agents/CodexLaunchConfiguration.swift`
- Modify: `Tests/UnitTests/OrchestraCore/Agents/AdapterTests.swift`
- Modify: `Tests/UnitTests/OrchestraCore/Agents/CodexAdapterTests.swift`

**Interfaces:**
- Claude `start` and `resume` append `--mcp-config <MCPConfiguration.claudeJSON(command: ctx.orchestraMCPBin)>` while leaving `--strict-mcp-config` absent.
- Codex profile TOML contains `MCPConfiguration.codexTOML(command: context.orchestraMCPBin)` and the same profile is selected for start and resume.
- Both `prepareToLaunch` implementations call the matching global installer only when `ctx.autoInstallMCPGlobally` is true, swallowing failures as they do for other optional preparation steps.

- [ ] **Step 1: Write failing adapter-boundary tests.**

Update Claude argv tests to construct a deterministic MCP path and parse the JSON immediately after `--mcp-config`; assert start and resume each carry the `orchestra` server and never carry strict mode. Update Codex profile tests to pass `orchestraMCPBin: "/abs/orchestra-mcp"` and assert the selected profile contains:

```swift
#expect(lines.contains("[mcp_servers.orchestra]"))
#expect(lines.contains("command = \"/abs/orchestra-mcp\""))
```

Add tests that call each adapter's `prepareToLaunch` with the global flag disabled and verify preparation remains successful; the helper's direct tests cover global-file mutation without touching the real user configuration.

- [ ] **Step 2: Run the adapter suites and verify the expected red failure.**

Run `./scripts/test.sh --filter ClaudeCodeAdapter --filter CodexAdapter`. Expect failures on missing `--mcp-config`/MCP profile lines and missing global-preparation behavior, not unrelated hook or transcript failures.

- [ ] **Step 3: Implement Claude local flags and optional global setup.**

Add a private Claude `mcpFlags(_:)` returning two argv elements, include it in both `start` and `resume`, call `MCPConfiguration.installClaudeGlobally(command: ctx.orchestraMCPBin, at: "\(Config.home)/.claude.json")` only under the flag, and preserve the existing settings flag ordering and access flags. Keep `sessionInfo`'s reduced context populated with `orchestraMCPBin`.

- [ ] **Step 4: Implement Codex profile and optional global setup.**

Append the MCP table to `CodexLaunchConfiguration.profileTOML(context:agentId:)`, call `installCodexGlobally` at `"\(codexHome)/config.toml"` only under the flag, and preserve the existing profile name/`-p` behavior. Keep the profile's local entry after the existing owned values so the same-name launch override is applied by Codex's profile precedence.

- [ ] **Step 5: Run the adapter suites and verify green.**

Run `./scripts/test.sh --filter ClaudeCodeAdapter --filter CodexAdapter`. Expect all adapter launch/profile tests to pass.

- [ ] **Step 6: Commit adapter integration.**

```bash
git add Sources/OrchestraCore/Agents/ClaudeCodeAdapter.swift Sources/OrchestraCore/Agents/CodexAdapter.swift Sources/OrchestraCore/Agents/CodexLaunchConfiguration.swift Tests/UnitTests/OrchestraCore/Agents/AdapterTests.swift Tests/UnitTests/OrchestraCore/Agents/CodexAdapterTests.swift
git commit -m "feat: configure Orchestra MCP on agent launches"
```

### Task 4: Expose the setting and document the install behavior

**Files:**
- Modify: `App/Views/SettingsView.swift`
- Modify: `docs/06-clients-cli-mcp.md`
- Modify: `docs/07-app-ui.md`
- Modify: `App/README.md`

**Interfaces:**
- Settings exposes an auto-saved `Auto-install Orchestra MCP globally` toggle in the Agent section, defaulting from `Config.autoInstallMCPGlobally`.
- Documentation says card launches configure MCP automatically, same-name local entries override global entries, global installation is opt-in/add-only, and the CLI/MCP binaries ship together.

- [ ] **Step 1: Add the setting UI binding.**

Add `@State private var autoInstallMCPGlobally = false`, load/save it with the other daemon fields, schedule saves on change, and render a `toggleRow` with a concise explanation that enabling it adds missing global entries without replacing existing ones. Increase the Settings window height enough to show the new row without clipping.

- [ ] **Step 2: Update client and app documentation.**

Replace the manual-registration sentence in `docs/06-clients-cli-mcp.md` with the automatic per-card behavior and an explicit optional-global-install subsection. Update the Settings inventory in `docs/07-app-ui.md` and `App/README.md` to mention the new Agent toggle and the local-versus-global behavior.

- [ ] **Step 3: Run documentation and UI-adjacent checks.**

Run `git diff --check` and the focused config/adapter suites. Verify the docs contain no statement that contradicts automatic card setup or the bundled sibling-binary layout.

- [ ] **Step 4: Commit the setting and docs.**

```bash
git add App/Views/SettingsView.swift docs/06-clients-cli-mcp.md docs/07-app-ui.md App/README.md
git commit -m "feat: expose opt-in global MCP installation"
```

### Task 5: Run the merge gate and review the final diff

**Files:**
- Verify: all changed files from Tasks 1–4

- [ ] **Step 1: Run the unit suite.**

Run `./scripts/test.sh`. Expect the unit suite to pass with no new warnings.

- [ ] **Step 2: Run the full merge gate.**

Run `./scripts/test.sh --all`. Expect unit, contract, and integration suites to pass.

- [ ] **Step 3: Inspect the final diff.**

Run `git diff HEAD~4..HEAD --stat`, `git diff --check`, and `git status --short`. Confirm only the MCP setting, launch configuration, tests, and targeted docs changed; confirm no global user file was touched during tests.

- [ ] **Step 4: Move the card to Review.**

After the fresh verification output is green, move this Orchestra card to Review and report the exact test commands and commit range.
