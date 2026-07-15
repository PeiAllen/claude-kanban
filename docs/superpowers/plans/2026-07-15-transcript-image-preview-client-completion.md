# Transcript-Anchored Image Preview Client Completion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Complete temporary transcript-anchored image previews on the macOS embedded terminal and iPhone card detail, using the committed opaque media-publishing foundation.

**Architecture:** The daemon, CLI, marker grammar, lifecycle cleanup, agent instructions, and isolated tmux proof are already implemented on this branch. Clients add one card-scoped fetch through BoardStore, then render only returned PNG/JPEG bytes with native UI. A reference stays plain transcript text unless its target exactly matches https://orchestra.invalid/media/<UUID>; no client accepts an image path or parses provider-specific tool output.

**Tech Stack:** Swift 6, SwiftPM Testing/XCTest, SwiftUI, AppKit, UIKit, SwiftTerm, tmux.

## Global Constraints

- Retain the completed foundation in commits 2f903a4, 53bd090, d765cbe, and 5bda41d unless a focused test demonstrates a defect.
- The agent-facing entry point remains exactly orchestra publish-image <absolute-image-path> [--caption <text>].
- Resolve only the exact opaque Orchestra media URL through media. Reject local paths, file URLs, ordinary web links, queries, fragments, ports, user-info, and extra path segments.
- Keep the 4 MiB source limit, 50 MiB card-session quota, session-epoch expiry, and daemon-owned storage from the existing foundation.
- The preview is temporary and transcript-anchored: do not add a shelf, gallery, row overlay, passive hover, terminal image protocol, or automatic path detection.
- macOS uses deliberate SwiftTerm link activation. Preserve the existing hover-motion suppression and never forward popup input to tmux.
- iPhone capture links only the exact visible opaque fallback URL. Live iPhone terminals forward only a validated opaque id.
- iPhone sharing uses UIActivityViewController with a decoded image. It never shares a path or media URL and writes no Orchestra-managed file.
- Keep notes/designs/2026-07-15-agent-image-media-shelf.md and notes/images/ untracked and untouched.
- Do not interact with a user’s existing terminal or phone. Any manual acceptance happens only on an explicitly approved disposable card.

---

## Current Checkpoint

These pieces are present and must pass their focused checks before client work begins:

| Area | Source | Invariant |
| --- | --- | --- |
| Opaque contract | Sources/OrchestraKit/TranscriptImage.swift | OSC 8 marker and visible fallback carry only a UUID-based Orchestra URL. |
| Storage/lifecycle | Sources/OrchestraCore/MediaStore.swift | Daemon copies bounded PNG/JPEG bytes under card/session storage and removes stale epochs. |
| CLI/RPC | Sources/orchestra/CLIRunner.swift, ControlServer.swift | publish-image emits the marker; media returns a card-scoped payload. |
| Agent/tmux delivery | ImageDocs.swift, embedded.conf, HyperlinkTransportTests.swift | Both adapters receive the CLI instruction and an isolated tmux server preserves OSC 8. |

Run before modifying client code:

    ./scripts/test.sh --filter 'TranscriptImageTests|MediaStoreTests|TranscriptImageLifecycleTests|TranscriptImageControlTests|ImageDocsTests'
    ./scripts/test.sh --contract --filter HyperlinkTransportTests

Expected: PASS. A failure is fixed in its owning foundation component before a client task begins.

## File Structure

| File | Responsibility |
| --- | --- |
| Sources/OrchestraUI/BoardStore.swift | One app-facing card-scoped media fetch API. |
| Tests/UnitTests/OrchestraUI/TranscriptImageBoardStoreTests.swift | Hermetic proof of the BoardStore-to-media RPC boundary. |
| Sources/OrchestraKit/TranscriptImage.swift | Existing reference grammar plus pure desktop cache eviction policy. |
| Tests/UnitTests/OrchestraKit/TranscriptImageTests.swift | URL/tokenizer and cache-policy regressions. |
| App/OrchestraApp.swift | Invokes the desktop export-cache prune once during app startup. |
| App/TranscriptImagePreview.swift | AppKit popover, payload decoding, zoom/pan, Copy/Open, and export cache. |
| App/Views/AgentTerminalView.swift | SwiftTerm link callback, deliberate activation anchor, and preview lifetime. |
| App/Views/InspectorView.swift, App/Views/ShellTabsView.swift | Card-scoped image loader injection for every desktop terminal. |
| App-iOS/Views/TranscriptImagePreview.swift | Full-screen UIKit viewer, Share sheet, and selectable capture-text bridge. |
| App-iOS/Views/CardDetail/CardDetailView.swift, AgentTab.swift, TerminalTab.swift, AgentTakeoverView.swift | One image route and all iPhone activation sources. |
| App-iOS/Terminal/IOSTerminalView.swift, IOSTerminalHost.swift | Narrow live-terminal image link forwarding. |

### Task 1: Expose a card-scoped media fetch to app views

**Files:**

- Modify: Sources/OrchestraUI/BoardStore.swift:889-895
- Create: Tests/UnitTests/OrchestraUI/TranscriptImageBoardStoreTests.swift

**Interfaces:**

- Consumes ControlClient.media(ref:referenceID:) async throws -> TranscriptImagePayload.
- Produces BoardStore.transcriptImage(_ cardID: UUID, referenceID: UUID) async throws -> TranscriptImagePayload.
- App and App-iOS never call ControlClient.media directly.

- [x] **Step 1: Write a failing BoardStore transport test**

Create an XCTest using a test-local semaphore-backed Transport. It decodes outgoing RPCRequest values, records method/params, returns a normal version response, returns one supplied payload for media, and returns an RPC error for every other method.

    @MainActor
    final class TranscriptImageBoardStoreTests: XCTestCase {
        func testFetchUsesOnlyTheSelectedCardAndOpaqueReference() async throws {
            let cardID = UUID()
            let reference = TranscriptImageReference(
                id: UUID(), cardId: cardID, sessionEpoch: 4,
                caption: "architecture", mimeType: "image/png", filename: "image.png"
            )
            let transport = ImmediateMediaTransport(
                payload: TranscriptImagePayload(reference: reference, dataBase64: "iVBORw0KGgo=")
            )
            let store = BoardStore(platform: .noop)
            let client = ControlClient(transport: { transport }, source: .app)
            store.injectClientForTesting(client)
            try client.connect()
            defer { client.close() }

            let payload = try await store.transcriptImage(cardID, referenceID: reference.id)

            XCTAssertEqual(payload.reference, reference)
            XCTAssertEqual(transport.lastMethod, "media")
            XCTAssertEqual(transport.lastParams?["ref"], .string(cardID.uuidString))
            XCTAssertEqual(transport.lastParams?["id"], .string(reference.id.uuidString))
        }
    }

Define the test transport in that file as:

    final class ImmediateMediaTransport: Transport, @unchecked Sendable {
        private let lock = NSLock()
        private let semaphore = DispatchSemaphore(value: 0)
        private var lines: [Data] = []
        private var eof = false
        let payload: TranscriptImagePayload
        private(set) var lastMethod: String?
        private(set) var lastParams: [String: JSONValue]?

        init(payload: TranscriptImagePayload) { self.payload = payload }
        func open() throws {}
        func write(_ data: Data) -> Bool {
            guard let request = try? RPCCodec.decoder.decode(RPCRequest.self, from: data),
                  let id = request.id else { return false }
            let params: [String: JSONValue]?
            if case let .object(value)? = request.params { params = value } else { params = nil }
            lock.withLock { lastMethod = request.method; lastParams = params }
            let response: RPCResponse
            switch request.method {
            case "version":
                response = RPCResponse(id: id, result: .object(["version": .string("fake")]))
            case "media":
                guard let result = try? JSONValue(encodable: payload) else { return false }
                response = RPCResponse(id: id, result: result)
            default:
                response = RPCResponse(id: id, result: nil,
                                       error: RPCError(code: -32000, message: "unexpected RPC"))
            }
            lock.withLock { lines.append((try? RPCCodec.line(response)) ?? Data()) }
            semaphore.signal()
            return true
        }
        func readLine() -> Data? {
            while true {
                semaphore.wait()
                let result: Data?? = lock.withLock {
                    if !lines.isEmpty { return .some(lines.removeFirst()) }
                    return eof ? .some(nil) : nil
                }
                if let result { return result }
            }
        }
        func shutdown() { close() }
        func close() { lock.withLock { eof = true }; semaphore.signal() }
    }

The transport records the selected ref and id before it returns its payload. Its close implementation wakes a blocked reader, matching EventStreamConsumerTests.FakeTransport, so this test cannot leave a ControlClient reader running.

- [x] **Step 2: Run the focused test before implementation**

Run:

    ./scripts/test.sh --filter TranscriptImageBoardStoreTests

Expected: compile failure naming the missing BoardStore.transcriptImage method.

- [x] **Step 3: Add the single BoardStore boundary**

Add this next to captureAgentPane:

    /// Resolves an opaque, temporary transcript image for one selected card. No filesystem path crosses
    /// this UI boundary.
    public func transcriptImage(_ cardID: UUID, referenceID: UUID) async throws -> TranscriptImagePayload {
        try await client.media(ref: cardID.uuidString, referenceID: referenceID)
    }

Do not swallow the error. The relevant platform preview needs to render expiry or transport feedback while leaving the terminal unchanged.

- [x] **Step 4: Run the unit proof**

Run:

    ./scripts/test.sh --filter 'TranscriptImageBoardStoreTests|TranscriptImageTests'

Expected: PASS. The only request made by the new BoardStore API is media for the requested card and id.

- [x] **Step 5: Commit the data boundary**

    git add Sources/OrchestraUI/BoardStore.swift Tests/UnitTests/OrchestraUI/TranscriptImageBoardStoreTests.swift
    git commit -m "feat: expose transcript images to app clients"

### Task 2: Add the iPhone route, exact fallback links, and native image viewer

**Files:**

- Create: App-iOS/Views/TranscriptImagePreview.swift
- Modify: App-iOS/Views/CardDetail/CardDetailView.swift:19-58
- Modify: App-iOS/Views/CardDetail/AgentTab.swift:22-220
- Modify: App-iOS/Views/CardDetail/TerminalTab.swift:24-34, 370-553
- Modify: App-iOS/Views/AgentTakeoverView.swift:19-142
- Modify: App-iOS/Terminal/IOSTerminalView.swift:14-158, 375-410
- Modify: App-iOS/Terminal/IOSTerminalHost.swift:26-104
- Modify: Tests/UnitTests/OrchestraKit/TranscriptImageTests.swift

**Interfaces:**

- Consumes BoardStore.transcriptImage, TranscriptImageLink.referenceID(from:), and TranscriptImageTextTokenizer.tokenize(_:).
- Produces TranscriptImageRoute(cardID:referenceID:), MobileTranscriptImagePreview, and CapturePaneText(text:onOpenImage:).
- CardDetailView owns @State private var imageRoute: TranscriptImageRoute?; child views receive an onOpenImage closure.
- IOSTerminalView accepts onOpenImage: ((UUID) -> Void)? and invokes it only after exact URL validation.

- [x] **Step 1: Add a pure tokenizer regression first**

Add this to TranscriptImageTests:

    @Test("capture tokenizer rejects a query, fragment, and extra media path")
    func tokenizerRejectsURLContinuations() {
        let id = UUID()
        let base = TranscriptImageLink.url(for: id)
        for invalid in ["\(base)?download=1", "\(base)#preview", "\(base)/full"] {
            #expect(TranscriptImageTextTokenizer.tokenize(invalid) == [.text(invalid)])
        }
    }

- [x] **Step 2: Run the tokenizer test**

Run:

    ./scripts/test.sh --filter TranscriptImageTests

Expected: PASS after the existing continuation guard is exercised. If it fails, fix only TranscriptImageTextTokenizer until this exact rejection behavior holds.

- [x] **Step 3: Introduce one card-detail route and capture-text activation**

Add this route in App-iOS/Views/TranscriptImagePreview.swift:

    struct TranscriptImageRoute: Identifiable, Equatable {
        let cardID: UUID
        let referenceID: UUID
        var id: String { "\(cardID.uuidString)-\(referenceID.uuidString)" }
    }

In CardDetailView, attach one full-screen presentation and pass the same closure to AgentTab, TerminalTab, and AgentTakeoverView:

    @State private var imageRoute: TranscriptImageRoute?

    private func openImage(_ referenceID: UUID, for task: Task) {
        imageRoute = TranscriptImageRoute(cardID: task.id, referenceID: referenceID)
    }

    .fullScreenCover(item: $imageRoute) { route in
        MobileTranscriptImagePreview(route: route).environmentObject(model)
    }

Replace the capture Text with a non-editable selectable UITextView bridge. Its updateUIView builds an NSMutableAttributedString from TranscriptImageTextTokenizer.tokenize(text): .text keeps the current monospaced style; .reference(id) appends TranscriptImageLink.url(for: id) with a .link attribute. Its delegate calls onOpenImage(id) and returns false only when TranscriptImageLink.referenceID(from:) succeeds. It returns true for any other link and never scans arbitrary text itself.

    struct CapturePaneText: UIViewRepresentable {
        let text: String
        let onOpenImage: (UUID) -> Void

        func makeUIView(context: Context) -> UITextView {
            let view = UITextView()
            view.isEditable = false
            view.isSelectable = true
            view.isScrollEnabled = false
            view.backgroundColor = .clear
            view.textContainerInset = .zero
            view.textContainer.lineFragmentPadding = 0
            view.delegate = context.coordinator
            return view
        }
    }

- [x] **Step 4: Thread exact live-terminal link handling**

Extend the representable and coordinator:

    struct IOSTerminalView: UIViewRepresentable {
        let makeChannel: () -> TerminalByteChannel
        var onOpenImage: ((UUID) -> Void)? = nil
    }

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let id = TranscriptImageLink.referenceID(from: link) else { return }
        onOpenImage?(id)
    }

Keep the closure on the coordinator and refresh it in updateUIView so a changed card cannot invoke a stale route. Add concrete IOSTerminalHost overloads for live shell and takeover that accept the closure and pass it to terminalView. TerminalTab.LiveShellView and AgentTakeoverView call those overloads only for IOSTerminalHost; the generic TerminalHost fallback preserves its existing attach behavior.

- [x] **Step 5: Implement MobileTranscriptImagePreview**

The new view loads only through the BoardStore method and validates payload metadata before it enters UIKit:

    private enum TranscriptImagePreviewError: Error { case invalidPayload }

    @MainActor
    private func load(_ route: TranscriptImageRoute) async {
        do {
            let payload = try await model.transcriptImage(route.cardID, referenceID: route.referenceID)
            guard payload.reference.mimeType == "image/png" || payload.reference.mimeType == "image/jpeg",
                  let data = Data(base64Encoded: payload.dataBase64),
                  let image = UIImage(data: data) else {
                throw TranscriptImagePreviewError.invalidPayload
            }
            self.image = image
            self.caption = payload.reference.caption
        } catch {
            self.errorMessage = "Image preview expired"
        }
    }

Start load with `.task(id: route)`, which SwiftUI cancels when the full-screen cover closes or switches routes; check `Task.isCancelled` before assigning fetched state. Render a close control, caption, loading state, and error state. Host UIImageView in UIScrollView, start fit-to-screen, implement viewForZooming(in:), allow pinch from fit to max(8 * fitScale, nativeScale), and allow direct drag pan only while magnified. Provide compact minus, fit, and plus buttons that set zoomScale. Share presents UIActivityViewController(activityItems: [image], applicationActivities: nil). Retain the decoded UIImage until both viewer and share sheet dismiss; clear it in onDisappear. Do not use UIPasteboard, UIDocumentInteractionController, or an iOS image cache.

- [x] **Step 6: Compile and test the iPhone path**

Run:

    ./scripts/test.sh --filter TranscriptImageTests
    ./scripts/typecheck-ios-ui.sh
    ./scripts/typecheck-ios.sh

Expected: PASS. The app target includes the UIKit viewer and SwiftTerm forwarding; OrchestraUI stays AppKit-free.

- [x] **Step 7: Commit iPhone preview support**

    git add App-iOS/Views/TranscriptImagePreview.swift \
      App-iOS/Views/CardDetail/CardDetailView.swift \
      App-iOS/Views/CardDetail/AgentTab.swift \
      App-iOS/Views/CardDetail/TerminalTab.swift \
      App-iOS/Views/AgentTakeoverView.swift \
      App-iOS/Terminal/IOSTerminalView.swift \
      App-iOS/Terminal/IOSTerminalHost.swift \
      Tests/UnitTests/OrchestraKit/TranscriptImageTests.swift
    git commit -m "feat: preview transcript images on ios"

### Task 3: Add the macOS popover, safe export cache, and deliberate link handling

**Files:**

- Modify: Sources/OrchestraKit/TranscriptImage.swift:1-128
- Modify: Tests/UnitTests/OrchestraKit/TranscriptImageTests.swift
- Modify: App/OrchestraApp.swift
- Create: App/TranscriptImagePreview.swift
- Modify: App/Views/AgentTerminalView.swift:11-317, 362-447
- Modify: App/Views/InspectorView.swift:361-390
- Modify: App/Views/ShellTabsView.swift:42-58

**Interfaces:**

- Consumes BoardStore.transcriptImage, TranscriptImageLink.referenceID(from:), and TranscriptImagePayload.
- Produces TranscriptImageCacheEntry, TranscriptImageCachePolicy.filesToRemove(entries:now:maxAge:maxBytes:), TranscriptImagePreviewPresenter, and AgentTerminalView.loadTranscriptImage.
- A terminal callback supplies only a UUID and an opaque payload loader; it never sees an image path.

- [ ] **Step 1: Write the cache-policy regression**

Add this pure test before AppKit code:

    @Test("desktop export cache removes expired files before LRU overflow")
    func desktopCacheUsesAgeThenLRU() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let old = TranscriptImageCacheEntry(url: URL(fileURLWithPath: "/tmp/old.png"), byteCount: 8,
                                            modifiedAt: now.addingTimeInterval(-8 * 86_400))
        let oldest = TranscriptImageCacheEntry(url: URL(fileURLWithPath: "/tmp/a.png"), byteCount: 200,
                                               modifiedAt: now.addingTimeInterval(-3 * 86_400))
        let newest = TranscriptImageCacheEntry(url: URL(fileURLWithPath: "/tmp/b.png"), byteCount: 100,
                                               modifiedAt: now.addingTimeInterval(-60))

        #expect(TranscriptImageCachePolicy.filesToRemove(entries: [newest, old, oldest], now: now,
            maxAge: 7 * 86_400, maxBytes: 256 * 1024 * 1024) == [old.url])
        #expect(TranscriptImageCachePolicy.filesToRemove(entries: [newest, oldest], now: now,
            maxAge: 7 * 86_400, maxBytes: 250) == [oldest.url])
    }

- [ ] **Step 2: Run the focused test before implementation**

Run:

    ./scripts/test.sh --filter TranscriptImageTests

Expected: compile failure naming TranscriptImageCacheEntry or TranscriptImageCachePolicy.

- [ ] **Step 3: Implement the pure policy and cache**

Add to TranscriptImage.swift:

    public struct TranscriptImageCacheEntry: Sendable, Equatable {
        public let url: URL
        public let byteCount: Int
        public let modifiedAt: Date
    }

    public enum TranscriptImageCachePolicy {
        public static func filesToRemove(entries: [TranscriptImageCacheEntry], now: Date,
                                         maxAge: TimeInterval, maxBytes: Int) -> [URL] {
            let stale = entries.filter { now.timeIntervalSince($0.modifiedAt) > maxAge }
            let survivors = entries.filter { !stale.contains($0) }
            var retained = survivors.sorted { ($0.modifiedAt, $0.url.path) > ($1.modifiedAt, $1.url.path) }
            var total = retained.reduce(0) { $0 + $1.byteCount }
            var removed = stale.sorted { ($0.modifiedAt, $0.url.path) < ($1.modifiedAt, $1.url.path) }.map(\.url)
            while total > maxBytes, let oldest = retained.popLast() {
                total -= oldest.byteCount
                removed.append(oldest.url)
            }
            return removed
        }
    }

Its implementation removes entries older than maxAge first, then removes remaining files by oldest modification date until retained byte count is at most maxBytes. Use a deterministic URL-path tie-breaker.

Create TranscriptImagePreviewCache under the app Application Support directory. Add `TranscriptImagePreviewCache.pruneAtLaunch()` and call it once from OrchestraApp initialization, before the app mounts terminal views. It enumerates only regular cache files, builds entries from size and modification date, and removes exactly the paths selected by the policy with 7 days and 256 MiB. Open creates a fresh UUID filename with only the validated png or jpg extension, writes the fetched bytes, then calls NSWorkspace.shared.open. It never deletes the file on popover close or app exit.

- [ ] **Step 4: Implement one terminal-local AppKit presenter**

Create:

    @MainActor
    final class TranscriptImagePreviewPresenter {
        func show(referenceID: UUID, from terminal: NSView, anchor: NSPoint,
                  load: @escaping (UUID) async throws -> TranscriptImagePayload)
        func dismiss()
    }

show dismisses an existing popover and cancels its prior load Task, then loads bytes through the injected closure. dismiss cancels the current Task before closing the popover. The presenter accepts only image/png or image/jpeg plus valid Base64 and NSImage decoding, and then presents a transient NSPopover anchored at the actual activation point. Its controller has a bounded NSScrollView/NSImageView, initial fit, native pinch zoom, pan above fit, minus/fit/plus controls, and a maximum zoom of max(8 * fitScale, nativeScale). It shows the caption. Copy writes actual pixels to NSPasteboard: raw PNG bytes when PNG, a generated PNG representation when JPEG. Open uses only TranscriptImagePreviewCache. On expiry, bad MIME, bad Base64, or transport failure, present a small transient Image preview expired popover; do not insert feedback into terminal output.

- [ ] **Step 5: Wire only valid SwiftTerm links**

Add to AgentTerminalView:

    var loadTranscriptImage: ((UUID) async throws -> TranscriptImagePayload)? = nil

At InspectorView and ShellTabsView terminal mounts, inject:

    loadTranscriptImage: { referenceID in
        try await model.transcriptImage(task.id, referenceID: referenceID)
    }

Set the SwiftTerm terminal delegate while retaining its process delegate. If the terminal’s existing/default link delegate is present, preserve it as the downstream delegate and forward every non-Orchestra link unchanged; the new callback owns only a parsed Orchestra image id. In requestOpenLink, use:

    guard let id = TranscriptImageLink.referenceID(from: link),
          let load = loadTranscriptImage else { return }
    preview.show(referenceID: id, from: source, anchor: terminal.lastActivationPoint, load: load)

Record lastActivationPoint in the existing leftMouseDown monitor before returning the same event to SwiftTerm. Add onTerminalScroll to ScrollableTerminalView and invoke it for every scroll event before alternate-buffer forwarding; it dismisses the current popover. Dismiss on a new link, target/card change, and terminal teardown. Keep mouseMoved returning nil exactly as it does now, consume no click, and do not intercept non-Orchestra links.

    final class ScrollableTerminalView: LocalProcessTerminalView {
        var lastActivationPoint: NSPoint = .zero
        var onTerminalScroll: (() -> Void)?
    }

- [ ] **Step 6: Build the desktop paths**

Run:

    ./scripts/test.sh --filter TranscriptImageTests
    ./scripts/typecheck-app.sh
    xcodegen generate --spec App/project.yml --project App
    xcodebuild -project App/Orchestra.xcodeproj -scheme Orchestra -configuration Debug \
      -destination 'platform=macOS' -derivedDataPath "$PWD/.scratch/transcript-image-macos-build" build

Expected: PASS. The xcodebuild is compile-only: it must not install, launch, attach to tmux, or touch an existing Orchestra.app process. It validates the real SwiftTerm branch that typecheck-app.sh cannot compile without that package.

- [ ] **Step 7: Commit macOS preview support**

    git add Sources/OrchestraKit/TranscriptImage.swift \
      Tests/UnitTests/OrchestraKit/TranscriptImageTests.swift \
      App/OrchestraApp.swift \
      App/TranscriptImagePreview.swift \
      App/Views/AgentTerminalView.swift \
      App/Views/InspectorView.swift \
      App/Views/ShellTabsView.swift
    git commit -m "feat: preview transcript images on macos"

### Task 4: Verify without touching a live user terminal

**Files:**

- Verify only. If a check fails, fix its owning task and rerun that task’s focused test first.

**Interfaces:**

- Consumes the completed foundation, BoardStore fetch, iPhone viewer, and macOS popover.
- Produces a review-ready branch and an explicit manual-acceptance boundary.

- [ ] **Step 1: Run all automated suites**

Run:

    ./scripts/test.sh
    ./scripts/test.sh --contract
    ./scripts/test.sh --all
    ./scripts/typecheck-app.sh
    ./scripts/typecheck-ios-ui.sh
    ./scripts/typecheck-ios.sh

Expected: PASS. The contract suite uses a unique tmux -L test server and never names or attaches to the live Orchestra socket.

- [ ] **Step 2: Inspect the final worktree**

Run:

    git status --short
    git log --oneline --decorate -12

Expected: only intended tracked commits are present. The rejected shelf markdown and notes/images/ stay untracked and unstaged.

- [ ] **Step 3: Record the manual acceptance boundary**

Do not automatically launch the app, attach a terminal, send bytes, resize tmux, or touch a phone. After explicit user approval, use one disposable card per supported agent: generate a small PNG, invoke orchestra publish-image in that card, scroll back to the marker, and prove both the OSC 8 link and its visible fallback behavior survive the real provider renderer. On desktop, Command-click it and verify the correct native preview, Copy/Open, scroll-close, and expiry after relaunch/archive. On phone, verify both the capture fallback and a live-terminal link route to the same full-screen preview, pinch/drag without moving the terminal, and use Share. Confirm that neither hover nor the preview sends a mouse action to the provider TUI.
