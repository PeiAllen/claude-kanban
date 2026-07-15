# Transcript-Anchored Image Preview Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let Orchestra agents publish a validated PNG or JPEG reference in their terminal transcript, then open that temporary image through one daemon RPC on macOS and iOS.

**Architecture:** The daemon owns a session-scoped `MediaStore`, and the CLI prints an opaque OSC 8 plus visible URL marker after publishing. `OrchestraKit` owns the wire types, URL grammar, marker renderer, and capture tokenizer; the desktop and phone each resolve the same opaque identifier through `media`, never through a filesystem path. The desktop-specific cache-eviction policy joins that shared module when the desktop export cache is introduced. The two terminal integrations only intercept the exact Orchestra URL and leave all other links on their existing path.

**Tech Stack:** Swift 6, SwiftPM, `Testing`/XCTest, tmux, SwiftTerm, AppKit, SwiftUI, UIKit.

## Global Constraints

- The agent-visible entry point is exactly `orchestra publish-image <absolute-image-path> [--caption <text>]`; it requires `ORCHESTRA_TASK_ID` and prints the transcript marker itself.
- Only regular PNG and JPEG source files are accepted; reject symlinks, unsupported bytes, files above 4 MiB, and publishes that would exceed 50 MiB for one card session.
- The daemon stores only opaque UUID references under `<runtimeStateDir>/media/<card-id>/<session-epoch>/`; no client receives a source or daemon filesystem path.
- Relaunch entry removes prior epochs, archive removes the whole card directory, and daemon boot reconciliation retains only a live card's current epoch.
- `publish-image` uses `CommandExposure.terminalOnly`: CLI and daemon dispatch it, while the MCP tool list excludes it. `media` is an app-only, read-only RPC.
- macOS activation remains Command-click; do not forward passive hover events to tmux or introduce a click path that reaches a provider TUI.
- The phone uses the native `UIActivityViewController` image share sheet for Copy and system image actions; it writes no Orchestra-managed image file.
- Keep rejected `notes/designs/2026-07-15-agent-image-media-shelf.md` and `notes/images/` untracked and untouched.
- Use `./scripts/test.sh` for unit work, add `--contract` for isolated tmux coverage, and run `scripts/typecheck-app.sh`, `scripts/typecheck-ios-ui.sh`, and `scripts/typecheck-ios.sh` before handoff.

---

## File Structure

| File | Responsibility |
| --- | --- |
| `Sources/OrchestraKit/TranscriptImage.swift` | Public image reference/payload wire types, exact URL parser, marker renderer, capture tokenizer, and later pure desktop cache policy. |
| `Sources/OrchestraCore/MediaStore.swift` | Validates source bytes, atomically stores index and image records, resolves payloads, applies quota, epoch/card cleanup, and boot reconciliation. |
| `Sources/OrchestraCore/OrchestraService+Media.swift` | Service-facing publish/fetch/reconcile operations that bind media to task state. |
| `Sources/OrchestraCore/CommandRegistry.swift`, `Sources/OrchestraKit/CommandCatalog.swift` | Terminal-only publish command schema and handler. |
| `Sources/OrchestraCore/Control/ControlServer.swift`, `Sources/OrchestraKit/Control/ControlClient.swift`, `Sources/orchestra/CLIRunner.swift` | Read-only media RPC plus CLI marker output. |
| `Sources/OrchestraCore/Agents/ImageDocs.swift`, resources | Agent-neutral publishing instruction, delivered as Claude skill and Codex AGENTS section. |
| `App/TranscriptImagePreview.swift` | AppKit popover, fit/zoom/pan preview, real-pixel copy/open actions, and bounded exported-file cache. |
| `App/Views/AgentTerminalView.swift`, `App/Views/InspectorView.swift` | Exact link interception and a media-loading closure into the desktop preview. |
| `App-iOS/Views/TranscriptImagePreview.swift` | Full-screen UIKit scroll-view image preview and native share sheet. |
| `App-iOS/Views/CardDetail/*.swift`, `App-iOS/Terminal/*.swift` | Capture fallback links, live terminal link forwarding, and one card-detail image route. |

## Task 1: Define the shared opaque-reference contract

**Files:**
- Create: `Sources/OrchestraKit/TranscriptImage.swift`
- Test: `Tests/UnitTests/OrchestraKit/TranscriptImageTests.swift`

**Interfaces:**
- Produces `TranscriptImageReference`, `TranscriptImagePayload`, `TranscriptImageLink`, `TranscriptImageMarker`, and `TranscriptImageTextTokenizer` for all later tasks.
- `TranscriptImageLink.referenceID(from:) -> UUID?` accepts only `https://orchestra.invalid/media/<UUID>` with no query, fragment, user info, or extra path segment.

- [ ] **Step 1: Write the failing contract tests**

```swift
@Test("only the exact opaque Orchestra media URL resolves")
func exactURLOnly() {
    let id = UUID()
    #expect(TranscriptImageLink.referenceID(from: "https://orchestra.invalid/media/\(id.uuidString)") == id)
    #expect(TranscriptImageLink.referenceID(from: "file:///tmp/image.png") == nil)
    #expect(TranscriptImageLink.referenceID(from: "https://orchestra.invalid/media/\(id.uuidString)?x=1") == nil)
}

@Test("marker has OSC 8 open and close sequences plus visible fallback")
func markerHasBothForms() {
    let id = UUID()
    let line = TranscriptImageMarker.render(referenceID: id, caption: "diagram")
    #expect(line.contains("\u{1B}]8;id=orchestra-\(id.uuidString.lowercased());https://orchestra.invalid/media/\(id.uuidString.lowercased())\u{1B}\\"))
    #expect(line.contains("▣ Image: diagram · preview"))
    #expect(line.contains("https://orchestra.invalid/media/\(id.uuidString.lowercased())"))
}
```

- [ ] **Step 2: Run the focused tests and verify they fail because the image contract is absent**

Run: `./scripts/test.sh --filter TranscriptImageTests`

Expected: compile failure naming missing `TranscriptImageLink` and `TranscriptImageMarker`.

- [ ] **Step 3: Implement the smallest shared contract**

```swift
public struct TranscriptImageReference: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let cardId: UUID
    public let sessionEpoch: Int
    public let caption: String
    public let mimeType: String
    public let filename: String
}

public struct TranscriptImagePayload: Codable, Sendable, Equatable {
    public let reference: TranscriptImageReference
    public let dataBase64: String
}

public enum TranscriptImageLink {
    public static func url(for id: UUID) -> String
    public static func referenceID(from raw: String) -> UUID?
}
```

Implement `TranscriptImageMarker.render` with the exact OSC 8 open/close sequence and a control-character-stripped, bounded caption. Tokenize only strings accepted by `TranscriptImageLink`, preserving every non-link substring verbatim.

- [ ] **Step 4: Run the focused tests and verify they pass**

Run: `./scripts/test.sh --filter TranscriptImageTests`

Expected: PASS, including rejection of ordinary web, file, malformed, and query-bearing URLs.

- [ ] **Step 5: Commit the shared contract**

```bash
git add Sources/OrchestraKit/TranscriptImage.swift Tests/UnitTests/OrchestraKit/TranscriptImageTests.swift
git commit -m "feat: add transcript image reference contract"
```

## Task 2: Add daemon-owned media storage and lifecycle cleanup

**Files:**
- Create: `Sources/OrchestraCore/MediaStore.swift`
- Create: `Sources/OrchestraCore/OrchestraService+Media.swift`
- Modify: `Sources/OrchestraCore/OrchestraService.swift`
- Modify: `Sources/OrchestraCore/OrchestraService+Lifecycle.swift`
- Modify: `Sources/OrchestraCore/OrchestraService+Reconcile.swift`
- Modify: `Sources/orchestrad/main.swift`
- Test: `Tests/UnitTests/OrchestraCore/MediaStoreTests.swift`
- Test: `Tests/UnitTests/OrchestraCore/Service/TranscriptImageLifecycleTests.swift`

**Interfaces:**
- Consumes `TranscriptImageReference` and `TranscriptImagePayload` from Task 1.
- Produces `OrchestraService.publishImage(_:sourcePath:caption:)`, `transcriptImage(_:referenceID:)`, and `reconcileTranscriptMediaAtBoot()`.
- `MediaStore(root:)` is injected into `OrchestraService` only as an optional test seam; production defaults to `"\(config.runtimeStateDir)/media"`.

- [ ] **Step 1: Write failing source-validation and retrieval tests**

```swift
@Test("publish stores a bounded PNG under the card current epoch and fetches base64 bytes")
func publishesCurrentEpochPNG() async throws {
    let env = TestEnv.make()
    let card = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "p", repo: TestEnv.repo(env.base), branch: "b"))
    let source = try writeTinyPNG(to: env.base + "/source.png")
    let ref = try await env.svc.publishImage(card.id, sourcePath: source, caption: "chart")
    let payload = try await env.svc.transcriptImage(card.id, referenceID: ref.id)
    #expect(payload.reference == ref)
    #expect(Data(base64Encoded: payload.dataBase64) != nil)
}

@Test("symlink, non-image, oversized source, and over-quota publish fail without a record")
func rejectsUnsafeOrOverQuotaSources() async throws {
    let env = TestEnv.make()
    let card = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "p", repo: TestEnv.repo(env.base), branch: "b"))
    let text = env.base + "/not-image.txt"
    try Data("not an image".utf8).write(to: URL(fileURLWithPath: text))
    await #expect(throws: OrchestraError.self) { try await env.svc.publishImage(card.id, sourcePath: text, caption: nil) }
    let link = env.base + "/link.png"
    try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: text)
    await #expect(throws: OrchestraError.self) { try await env.svc.publishImage(card.id, sourcePath: link, caption: nil) }
    let tooLarge = env.base + "/large.png"
    try Data(repeating: 0, count: 4 * 1024 * 1024 + 1).write(to: URL(fileURLWithPath: tooLarge))
    await #expect(throws: OrchestraError.self) { try await env.svc.publishImage(card.id, sourcePath: tooLarge, caption: nil) }
}

private func writeTinyPNG(to path: String) throws -> String {
    let bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    try Data(bytes).write(to: URL(fileURLWithPath: path))
    return path
}
```

- [ ] **Step 2: Run the focused tests and verify they fail because media service methods do not exist**

Run: `./scripts/test.sh --filter 'MediaStoreTests|TranscriptImageLifecycleTests'`

Expected: compile failure naming missing `publishImage`, `transcriptImage`, and `MediaStore`.

- [ ] **Step 3: Implement the isolated `MediaStore` actor and service boundary**

```swift
actor MediaStore {
    init(root: String)
    func publish(cardId: UUID, sessionEpoch: Int, sourcePath: String, caption: String?) throws -> TranscriptImageReference
    func payload(cardId: UUID, sessionEpoch: Int, referenceID: UUID) throws -> TranscriptImagePayload
    func removePriorEpochs(cardId: UUID, keeping epoch: Int)
    func removeCard(_ cardId: UUID)
    func reconcile(activeCards: [UUID: Int])
}
```

Use `lstat` to reject symlinks and non-regular files; read at most 4 MiB, sniff PNG/JPEG magic bytes, derive only `.png` or `.jpg`, and write the asset and `index.json` atomically inside the card epoch directory. Count indexed current-epoch bytes before writing and reject a publish above 50 MiB. `payload` must verify index, current card/epoch identity, MIME, and byte limit before Base64 encoding; stale/missing data throws one expired-reference error.

Inject `mediaStore` into `OrchestraService`. After a successful transition into `.creatingWorktree` or `.relaunching`, delete every prior epoch; after a transition into `.archivedPending`, delete the whole card directory. Add boot reconciliation after `reconcilePhasesAtBoot()` so absent/archived cards and non-current epochs are removed while a surviving live current epoch remains.

- [ ] **Step 4: Run the focused tests and verify they pass**

Run: `./scripts/test.sh --filter 'MediaStoreTests|TranscriptImageLifecycleTests'`

Expected: PASS for atomic current-epoch fetch, source rejection, 50 MiB ceiling, relaunch expiry, archive cleanup, and restart reconciliation.

- [ ] **Step 5: Commit daemon storage and cleanup**

```bash
git add Sources/OrchestraCore/MediaStore.swift Sources/OrchestraCore/OrchestraService+Media.swift Sources/OrchestraCore/OrchestraService.swift Sources/OrchestraCore/OrchestraService+Lifecycle.swift Sources/OrchestraCore/OrchestraService+Reconcile.swift Sources/orchestrad/main.swift Tests/UnitTests/OrchestraCore/MediaStoreTests.swift Tests/UnitTests/OrchestraCore/Service/TranscriptImageLifecycleTests.swift
git commit -m "feat: store transcript image media by session"
```

## Task 3: Expose publishing through CLI and retrieval through the shared RPC

**Files:**
- Modify: `Sources/OrchestraKit/CommandCatalog.swift`
- Modify: `Sources/OrchestraCore/CommandRegistry.swift`
- Modify: `Sources/OrchestraCore/Control/ControlServer.swift`
- Modify: `Sources/OrchestraKit/Control/ControlClient.swift`
- Modify: `Sources/orchestra/CLIRunner.swift`
- Modify: `Sources/orchestra/CLIHelp.swift`
- Test: `Tests/UnitTests/OrchestraCore/CommandRegistryCatalogTests.swift`
- Test: `Tests/UnitTests/OrchestraCore/Control/ControlServerTests.swift`
- Test: `Tests/UnitTests/OrchestraKit/Control/ControlClientTests.swift`

**Interfaces:**
- Consumes Task 1 marker renderer and Task 2 service methods.
- `CommandExposure` gains `.terminalOnly`; `CommandCatalog.mcpExposed` remains exactly `.all`.
- `ControlClient.media(ref:referenceID:) async throws -> TranscriptImagePayload` is the only client fetch API.

- [ ] **Step 1: Write failing wire and exposure tests**

```swift
func testPublishImageIsTerminalOnlyNotMCPExposed() {
    XCTAssertNotNil(CommandRegistry().command("publish-image"))
    XCTAssertFalse(CommandCatalog.mcpExposed.map(\.name).contains("publish-image"))
}

@Test("media RPC scopes an opaque reference to the requested card")
func mediaRPCRejectsReferenceFromAnotherCard() async throws {
    let env = TestEnv.make()
    let repo = TestEnv.repo(env.base)
    let first = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "a", repo: repo, branch: "a"))
    let second = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "b", repo: repo, branch: "b"))
    let source = try writeTinyPNG(to: env.base + "/a.png")
    let ref = try await env.svc.publishImage(first.id, sourcePath: source, caption: nil)
    await #expect(throws: OrchestraError.self) { try await env.svc.transcriptImage(second.id, referenceID: ref.id) }
}
```

- [ ] **Step 2: Run the focused tests and verify they fail because the command and RPC are absent**

Run: `./scripts/test.sh --filter 'CommandRegistryCatalogTests|ControlServer.*media|ControlClient.*media'`

Expected: FAIL naming `terminalOnly`, `publish-image`, or `media` as missing.

- [ ] **Step 3: Implement the command and RPC**

```swift
public enum CommandExposure: Sendable, Equatable { case all, appOnly, terminalOnly }

// Catalog schema: required ref + absolute path, optional caption; exposure terminalOnly; gate gLiveDead.
"publish-image": { svc, p, _ in
    let card = try await svc.resolveRef(try p.string("ref"))
    return try JSONValue(encodable: try await svc.publishImage(card.id,
        sourcePath: try p.string("path"), caption: p.optString("caption")))
}
```

Route `media` directly in `ControlServer` as app-only: decode `ref` and UUID `id`, resolve the card, and return `service.transcriptImage`. Add the typed `ControlClient.media` helper. The CLI must require nonempty `ORCHESTRA_TASK_ID`, require an absolute positional path, call `publish-image` with that ref, and print `TranscriptImageMarker.render(referenceID:caption:)` as one line. Add the command to help without exposing a raw `ref` argument to agents.

- [ ] **Step 4: Run the focused tests and verify they pass**

Run: `./scripts/test.sh --filter 'CommandRegistryCatalogTests|ControlServer.*media|ControlClient.*media|TranscriptImageTests'`

Expected: PASS; MCP excludes the command, daemon returns no path, and the exact marker is emitted by the shared renderer.

- [ ] **Step 5: Commit the control-plane contract**

```bash
git add Sources/OrchestraKit/CommandCatalog.swift Sources/OrchestraCore/CommandRegistry.swift Sources/OrchestraCore/Control/ControlServer.swift Sources/OrchestraKit/Control/ControlClient.swift Sources/orchestra/CLIRunner.swift Sources/orchestra/CLIHelp.swift Tests/UnitTests/OrchestraCore/CommandRegistryCatalogTests.swift Tests/UnitTests/OrchestraCore/Control/ControlServerTests.swift Tests/UnitTests/OrchestraKit/Control/ControlClientTests.swift
git commit -m "feat: publish transcript image references through orchestra"
```

## Task 4: Deliver the agent instruction and prove tmux preserves links

**Files:**
- Create: `Sources/OrchestraCore/Agents/ImageDocs.swift`
- Create: `Sources/OrchestraCore/Resources/image-publishing-skill.md`
- Create: `Sources/OrchestraCore/Resources/image-publishing-agents.md`
- Modify: `Package.swift`
- Modify: `Sources/OrchestraCore/Agents/ClaudeCodeAdapter.swift`
- Modify: `Sources/OrchestraCore/Agents/CodexAdapter.swift`
- Modify: `Sources/OrchestraCore/Resources/embedded.conf`
- Test: `Tests/UnitTests/OrchestraCore/Service/ImageDocsTests.swift`
- Test: `Tests/UnitTests/OrchestraCore/Agents/CodexAdapterTests.swift`
- Test: `Tests/ContractTests/Terminal/TranscriptImageHyperlinkContractTests.swift`

**Interfaces:**
- Consumes the existing `TreeDocs`/`AgentsFileComposer` installation pattern.
- Claude installs `.claude/skills/orchestra-image-publishing/SKILL.md`; Codex upserts an `image-publishing` section into its Orchestra-owned `AGENTS.md`.

- [ ] **Step 1: Write failing delivery and isolated-tmux tests**

```swift
@Test("both agent instruction variants tell an agent to publish a human-inspection image through the CLI")
func imageDocsContainCLIContract() throws {
    for doc in [try #require(ImageDocs.load(.claudeSkill)), try #require(ImageDocs.load(.codexAgents))] {
        #expect(doc.contains("orchestra publish-image"))
        #expect(doc.contains("human to inspect"))
    }
}

@Test("embedded tmux preserves explicit OSC 8 link metadata")
func hyperlinkSurvivesIsolatedServer() throws {
    let socket = "orch-image-test-\(UUID().uuidString.lowercased())"
    defer { _ = try? Proc.run(["tmux", "-L", socket, "kill-server"], timeout: .seconds(5)) }
    let config = try #require(Bundle.module.url(forResource: "embedded", withExtension: "conf"))
    let id = "00000000-0000-0000-0000-000000000001"
    let marker = "\u{1B}]8;id=orchestra-test;https://orchestra.invalid/media/\(id)\u{1B}\\\\preview\u{1B}]8;;\u{1B}\\\\"
    _ = try Proc.run(["tmux", "-L", socket, "-f", config.path, "new-session", "-d", "-s", "probe", "cat"], timeout: .seconds(5))
    _ = try Proc.run(["tmux", "-L", socket, "send-keys", "-t", "probe", "-l", marker], timeout: .seconds(5))
    let capture = try Proc.run(["tmux", "-L", socket, "capture-pane", "-p", "-e", "-t", "probe"], timeout: .seconds(5)).stdout
    #expect(capture.contains("id=orchestra-test"))
    #expect(capture.contains("https://orchestra.invalid/media/\(id)"))
}
```

- [ ] **Step 2: Run the focused tests and verify they fail before the resources/configuration exist**

Run: `./scripts/test.sh --contract --filter 'ImageDocsTests|TranscriptImageHyperlinkContractTests'`

Expected: FAIL because `ImageDocs` and the `hyperlinks` terminal feature are absent. The contract test uses a unique `tmux -L` socket and never attaches to the user's server.

- [ ] **Step 3: Implement delivery and transport support**

Add `ImageDocs` following `TreeDocs` verbatim, with both resource variants naming only the CLI path, absolute source path, optional caption, and the rule that arbitrary paths or tool image blocks remain un-published. Install it from each adapter next to its existing delegation/tree guidance. Add `image-publishing-skill.md` and `image-publishing-agents.md` to `Package.swift` resources, and add `hyperlinks` to the existing xterm terminal-features entry without removing `sixel` or `allow-passthrough on`.

The tmux contract test starts a fresh `tmux -L orch-image-test-<UUID>` server with the bundled config, sends a known OSC 8 marker, captures with escape output enabled, and asserts the captured bytes retain both `id=orchestra-...` and `https://orchestra.invalid/media/...`; it tears down only that unique server in `defer`.

- [ ] **Step 4: Run the focused tests and verify they pass**

Run: `./scripts/test.sh --contract --filter 'ImageDocsTests|CodexDelegationTests|TranscriptImageHyperlinkContractTests'`

Expected: PASS; both adapters install instruction once and the isolated tmux server preserves the marker.

- [ ] **Step 5: Commit agent delivery and tmux support**

```bash
git add Package.swift Sources/OrchestraCore/Agents/ImageDocs.swift Sources/OrchestraCore/Resources/image-publishing-skill.md Sources/OrchestraCore/Resources/image-publishing-agents.md Sources/OrchestraCore/Agents/ClaudeCodeAdapter.swift Sources/OrchestraCore/Agents/CodexAdapter.swift Sources/OrchestraCore/Resources/embedded.conf Tests/UnitTests/OrchestraCore/Service/ImageDocsTests.swift Tests/UnitTests/OrchestraCore/Agents/CodexAdapterTests.swift Tests/ContractTests/Terminal/TranscriptImageHyperlinkContractTests.swift
git commit -m "feat: teach agents to publish transcript images"
```

## Task 5: Add the phone route, capture fallback, live-link forwarding, and viewer

**Files:**
- Modify: `Sources/OrchestraUI/BoardStore.swift`
- Modify: `App-iOS/Views/CardDetail/CardDetailView.swift`
- Modify: `App-iOS/Views/CardDetail/AgentTab.swift`
- Modify: `App-iOS/Views/CardDetail/TerminalTab.swift`
- Modify: `App-iOS/Views/AgentTakeoverView.swift`
- Modify: `App-iOS/Terminal/IOSTerminalView.swift`
- Modify: `App-iOS/Terminal/IOSTerminalHost.swift`
- Create: `App-iOS/Views/TranscriptImagePreview.swift`
- Test: `Tests/UnitTests/OrchestraUI/BoardStoreTests.swift`
- Test: `Tests/UnitTests/OrchestraKit/TranscriptImageTests.swift`

**Interfaces:**
- Consumes `ControlClient.media` and `TranscriptImageTextTokenizer`.
- `BoardStore.transcriptImage(_ cardId: UUID, referenceID: UUID) async throws -> TranscriptImagePayload` is the shared app-facing retrieval method.
- `CardDetailView` owns `@State private var imageRoute: TranscriptImageRoute?`; every phone source invokes `openImage(_:)` with a validated reference id.

- [ ] **Step 1: Write failing phone-route and tokenizer tests**

```swift
@Test("capture tokenization turns only a valid Orchestra media fallback into an image reference")
func captureTokenizerKeepsOrdinaryURLsAsText() {
    let id = UUID()
    let segments = TranscriptImageTextTokenizer.tokenize("web https://example.com/x media https://orchestra.invalid/media/\(id)")
    #expect(segments.contains(.reference(id)))
    #expect(segments.contains(.text("web https://example.com/x media ")))
}

@Test("BoardStore asks the shared client for a card-scoped image payload")
func boardStoreFetchesTranscriptImage() async throws {
    let cardID = UUID()
    let reference = TranscriptImageReference(id: UUID(), cardId: cardID, sessionEpoch: 1,
        caption: "chart", mimeType: "image/png", filename: "chart.png")
    let transport = ImmediateMediaTransport(reply: TranscriptImagePayload(reference: reference, dataBase64: "iVBORw0KGgo="))
    let store = BoardStore()
    let client = ControlClient(transport: { transport })
    store.injectClientForTesting(client)
    try client.connect()
    defer { client.close() }
    #expect(try await store.transcriptImage(cardID, referenceID: reference.id).reference == reference)
    #expect(transport.lastMethod == "media")
}
```

Define `ImmediateMediaTransport` in `BoardStoreTests.swift` as the test-local `Transport`: it returns the normal `version` response during `ControlClient.connect()`, records the next request method, and returns the supplied `TranscriptImagePayload` only for `media`. Its `readLine()` blocks on a semaphore and `close()` wakes it, matching the existing `EventStreamConsumerTests.FakeTransport` pattern.

- [ ] **Step 2: Run the focused tests and verify they fail before the route exists**

Run: `./scripts/test.sh --filter 'TranscriptImageTests|BoardStoreTests.*TranscriptImage'`

Expected: FAIL naming the missing tokenizer or `BoardStore.transcriptImage` method.

- [ ] **Step 3: Implement one route and native iOS behavior**

`CardDetailView` presents `MobileTranscriptImagePreview` with `.fullScreenCover(item:)`. Pass an `openImage(UUID)` closure through `AgentTab`, `TerminalTab`, and `AgentTakeoverView`. On live SwiftTerm surfaces, add an `onOpenLink` closure to `IOSTerminalView.Coordinator`; parse through `TranscriptImageLink.referenceID(from:)` before calling upward and ignore unrelated URLs. Thread that closure through `IOSTerminalHost` without changing its SSH attach recipe.

Replace the capture `Text` with a selectable UIKit text view whose attributed `.link` ranges come only from `TranscriptImageTextTokenizer`; its delegate consumes only a validated media URL and calls `openImage`. Keep all non-reference text plain and selectable.

Implement `MobileTranscriptImagePreview` using a `UIScrollView` + image view that starts at fit, supports pinch zoom, direct drag pan when zoomed, plus/minus/fit controls, caption, loading, and expired/error state. Its Share button presents `UIActivityViewController` with a decoded `UIImage` from the fetched validated payload. Hold image bytes/`UIImage` only while the viewer or its activity sheet is visible, then release them; do not use `UIPasteboard`, `UIDocumentInteractionController`, or a local cache.

- [ ] **Step 4: Run focused tests and both iOS compile gates**

Run: `./scripts/test.sh --filter 'TranscriptImageTests|BoardStoreTests.*TranscriptImage' && ./scripts/typecheck-ios-ui.sh && ./scripts/typecheck-ios.sh`

Expected: all pass; the iOS target compiles without an AppKit reference and all phone paths use one `media` RPC.

- [ ] **Step 5: Commit phone preview support**

```bash
git add Sources/OrchestraUI/BoardStore.swift App-iOS/Views/CardDetail/CardDetailView.swift App-iOS/Views/CardDetail/AgentTab.swift App-iOS/Views/CardDetail/TerminalTab.swift App-iOS/Views/AgentTakeoverView.swift App-iOS/Terminal/IOSTerminalView.swift App-iOS/Terminal/IOSTerminalHost.swift App-iOS/Views/TranscriptImagePreview.swift Tests/UnitTests/OrchestraUI/BoardStoreTests.swift Tests/UnitTests/OrchestraKit/TranscriptImageTests.swift
git commit -m "feat: preview transcript images on ios"
```

## Task 6: Add the desktop transcript popover and safe exported-file cache

**Files:**
- Create: `App/TranscriptImagePreview.swift`
- Modify: `App/Views/AgentTerminalView.swift`
- Modify: `App/Views/InspectorView.swift`
- Modify: `Sources/OrchestraKit/TranscriptImage.swift`
- Test: `Tests/UnitTests/OrchestraKit/TranscriptImageTests.swift`

**Interfaces:**
- Consumes `TranscriptImageLink`, `TranscriptImagePayload`, and `BoardStore.transcriptImage`.
- `AgentTerminalView` accepts a card id and `loadTranscriptImage: (UUID) async throws -> TranscriptImagePayload`; it never accepts a filesystem path.
- Adds `TranscriptImageCacheEntry` and `TranscriptImageCachePolicy` to the existing `TranscriptImage.swift` shared module so cache-age/LRU behavior has a unit-testable, filesystem-independent seam.

- [ ] **Step 1: Write failing cache-policy and desktop link-policy tests**

```swift
@Test("cache policy removes stale entries before least-recently-modified overflow")
func cachePolicyIsAgeThenLRU() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let old = TranscriptImageCacheEntry(url: URL(fileURLWithPath: "/tmp/old.png"), byteCount: 8,
        modifiedAt: now.addingTimeInterval(-8 * 24 * 60 * 60))
    let oldestRemaining = TranscriptImageCacheEntry(url: URL(fileURLWithPath: "/tmp/a.png"), byteCount: 200,
        modifiedAt: now.addingTimeInterval(-3 * 24 * 60 * 60))
    let newestRemaining = TranscriptImageCacheEntry(url: URL(fileURLWithPath: "/tmp/b.png"), byteCount: 100,
        modifiedAt: now.addingTimeInterval(-60))
    let result = TranscriptImageCachePolicy.filesToRemove(entries: [newestRemaining, old, oldestRemaining], now: now,
        maxAge: 7 * 24 * 60 * 60, maxBytes: 256 * 1024 * 1024)
    #expect(result == [old.url])

    let overflow = TranscriptImageCachePolicy.filesToRemove(entries: [newestRemaining, oldestRemaining], now: now,
        maxAge: 7 * 24 * 60 * 60, maxBytes: 250)
    #expect(overflow == [oldestRemaining.url])
}

@Test("only an opaque Orchestra URL can request a preview")
func desktopLinkPolicyRejectsWebAndFileLinks() {
    #expect(TranscriptImageLink.referenceID(from: "https://example.com") == nil)
    #expect(TranscriptImageLink.referenceID(from: "file:///tmp/x.png") == nil)
}
```

- [ ] **Step 2: Run the focused tests and verify they fail before the desktop cache policy exists**

Run: `./scripts/test.sh --filter TranscriptImageTests`

Expected: FAIL naming missing `TranscriptImageCacheEntry` or `TranscriptImageCachePolicy`; this policy is intentionally introduced here, after its first red test.

- [ ] **Step 3: Implement desktop interception and popover**

Create a forwarding `TerminalViewDelegate` proxy for `ScrollableTerminalView`: it forwards normal resize/send/clipboard/title callbacks back to the `LocalProcessTerminalView`, intercepts only `TranscriptImageLink.referenceID(from:)`, and delegates all other URLs to `NSWorkspace` as SwiftTerm currently does. Do not replace the global passive-mouse policy; SwiftTerm's default Command-click path triggers `requestOpenLink` on mouse-up and does not require hover forwarding.

Use an `NSPopover` anchored to the current Command-click point inside the terminal. It loads through the injected card-scoped closure, closes on Escape, outside click, terminal scroll, new selection, view teardown, or card change. Add a custom AppKit preview controller with a bounded `NSScrollView`/`NSImageView`, initial fit, pinch magnification, minus/fit/plus controls, and drag/trackpad/scrollbar pan only above fit.

Copy writes actual image pixels: exact PNG data when available, or an AppKit-generated PNG for JPEG. Open writes validated bytes to an app-owned cache path with a UUID and `.png`/`.jpg`, then calls `NSWorkspace.shared.open`. On app launch, apply `TranscriptImageCachePolicy` to delete files older than seven days and then least-recently-modified survivors only over 256 MiB; never delete on popover close or app exit.

- [ ] **Step 4: Run desktop compile and unit tests**

Run: `./scripts/test.sh --filter TranscriptImageTests && ./scripts/typecheck-app.sh`

Expected: PASS; AppKit compiles, and no generic terminal link or hover path changed.

- [ ] **Step 5: Commit desktop preview support**

```bash
git add App/TranscriptImagePreview.swift App/Views/AgentTerminalView.swift App/Views/InspectorView.swift Sources/OrchestraKit/TranscriptImage.swift Tests/UnitTests/OrchestraKit/TranscriptImageTests.swift
git commit -m "feat: preview transcript images on macos"
```

## Task 7: Run integration verification and controlled acceptance checks

**Files:**
- Verify only; do not change files unless a failing check requires a source fix.

**Interfaces:**
- Consumes every completed task.
- Produces a verified branch ready for review; it never uses the user's existing terminal session as a test target.

- [ ] **Step 1: Run the unit tier**

Run: `./scripts/test.sh`

Expected: PASS with no new failures.

- [ ] **Step 2: Run contract and complete-suite checks**

Run: `./scripts/test.sh --contract && ./scripts/test.sh --all`

Expected: PASS; isolated tmux hyperlink test never names or attaches to the live `orchestra` tmux socket.

- [ ] **Step 3: Run all platform compile checks**

Run: `./scripts/typecheck-app.sh && ./scripts/typecheck-ios-ui.sh && ./scripts/typecheck-ios.sh`

Expected: PASS.

- [ ] **Step 4: Record the automated acceptance boundary and inspect the final worktree**

The automated suite proves the daemon contract, isolated tmux transport, exact fallback parsing, cache lifetime policy, and both platform compile surfaces. Do not attach to, send bytes to, resize, or otherwise touch the user's existing terminal or phone. Any later human smoke test must use a disposable card and is outside this autonomous implementation run.

Run: `git status --short && git log --oneline --decorate -8`

Expected: only intended tracked implementation changes are present; the rejected shelf mockup remains untracked and unstaged.
