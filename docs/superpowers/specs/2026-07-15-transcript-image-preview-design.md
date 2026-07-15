# Transcript-Anchored Image Preview Design

**Date:** 2026-07-15
**Status:** Approved for implementation

## Goal

Let any Orchestra-hosted agent publish an image as a short reference at the exact place it was produced
in its terminal transcript. Activating that reference opens a temporary native preview. The reference
scrolls with tmux history; the preview is not a persistent attachment, gallery, or terminal-image
protocol feature.

The initial surfaces are the macOS embedded terminal and the iPhone card detail. They work for both Codex
and Claude. The feature is deliberately agent-neutral: the contract is an Orchestra CLI command and a
daemon-owned media record, not a parser for provider-specific tool text or file paths.

## Current constraints

`AgentTerminalView` attaches SwiftTerm directly to tmux, so the daemon never receives or owns the PTY
byte stream. This rules out a daemon-side parser that retrospectively locates arbitrary agent output.
tmux owns the 50,000-line scrollback, and the app forwards scrolling to tmux while the alternate screen
is active.

The terminal also swallows passive mouse-move events: allowing them through makes SwiftTerm encode hover
as an SGR mouse release, which Claude interprets as a click. A passive hover preview is therefore out of
scope for the first version. The first activation is SwiftTerm's deliberate link activation (Command-click
on macOS); a click-only interaction can be considered only after it is shown not to leak a mouse event to
the agent TUI.

## Chosen approach: an explicit terminal link with a visible fallback

Add an agent-facing command:

```text
orchestra publish-image <absolute-image-path> [--caption <text>]
```

It requires `ORCHESTRA_TASK_ID`, copies the image into daemon-owned temporary storage, and prints one
single-line reference to its own stdout. Because the command itself prints the line, the terminal records
the reference at the correct causal point without an overlay having to infer a row or a byte offset.

Its daemon verb uses a new `terminalOnly` catalog exposure: the regular `orchestra` CLI can call it, but
the generated MCP tool list does not advertise it in this first version. An MCP tool result is not
guaranteed to be rendered as raw terminal output by either provider, while the CLI's stdout is precisely
the stream this feature needs to anchor. Both agents are instructed to invoke the CLI through their normal
shell tool.

The line has two forms at once:

1. An OSC 8 hyperlink whose target is an opaque, app-owned URL such as
   `https://orchestra.invalid/media/<reference-id>` and whose visible label is
   `▣ Image: architecture diagram · preview`.
2. The same short `https://orchestra.invalid/media/<reference-id>` target as visible text after the
   label. If an agent TUI sanitizes OSC control bytes while rendering command output, SwiftTerm's implicit
   URL recognition can still make the fallback target activatable.

`reference-id` is a random UUID, never a source path. A terminal line can therefore be copied, displayed,
or sent to another client without exposing a local filesystem location. The OSC 8 link includes a stable
`id=orchestra-<reference-id>` parameter so the terminal keeps one semantic link across line wrapping.

This is selected over two rejected alternatives:

- Parsing any text that resembles a Codex/Claude image path would be provider-specific, would expose
  arbitrary paths, and could never reliably distinguish a genuine asset from ordinary terminal text.
- Drawing an AppKit overlay at a guessed terminal row would break on tmux copy mode, terminal resizing,
  wrapping, and scrollback changes. It is especially unsuitable because the app deliberately does not
  proxy terminal bytes.

## Media lifecycle and retrieval

`MediaStore` owns a session-scoped record:

```swift
struct TranscriptImageReference: Codable, Sendable, Equatable {
    let id: UUID
    let cardId: UUID
    let sessionEpoch: Int
    let caption: String
    let mimeType: String
    let filename: String
}
```

The daemon copies the source image atomically to
`Config.dataDir/media/<card-id>/<session-epoch>/<reference-id>.<extension>` and persists the corresponding
metadata index beside it. It accepts regular PNG or JPEG files only; it rejects a missing,
symlinked, unsupported, or over-4-MiB source before creating a record. A card session may retain at most
50 MiB of published images; a publish that would exceed that ceiling fails rather than silently evicting
a reference that tmux still shows.

Media is not card state and is never rendered in the board or inspector. It is valid only for the card's
monotonic session epoch that published it, so Codex's briefly unavailable native session ID is never a
lifecycle dependency. An agent relaunch increments that epoch and removes the prior epoch's media
directory; archiving a card removes the card's whole media directory. A daemon restart preserves media
for the current active epoch, then runs an idempotent reconciliation after task state loads: it removes a
media directory whose card is absent or archived, or whose epoch is no longer the card's current epoch.
If an old terminal marker remains visible after its record has been removed, activation shows a small
"Image preview expired" message rather than following a file path or failing silently.

The app resolves the opaque URL through a read-only `media` RPC, not by opening the asset path itself.
The response carries bounded Base64 image bytes plus caption and MIME type, so the exact same mechanism
works when the daemon is remote. Both apps cancel a pending media request when its preview route closes
and retain decoded data only while that preview, or the phone's Share sheet, remains presented.

## macOS interaction

Configure SwiftTerm to track explicit links (with implicit URL recognition retained for the fallback) and
handle `requestOpenLink` in `AgentTerminalView.Coordinator`.

- Only the `https://orchestra.invalid/media/<UUID>` form is intercepted. Any other link retains
  SwiftTerm's current behavior.
- Command-clicking a valid reference fetches the media record and presents an AppKit popover anchored at
  the activation point. It contains a fit-to-window image preview, the caption, and compact Copy and Open
  actions.
- The popover closes on Escape, clicking outside it, selecting another reference, changing cards, or
  scrolling the terminal. Closing on scroll is intentional: the reference has moved, so the preview never
  looks pinned to unrelated transcript content.
- Failure, expiry, MIME rejection, or a transport error produces brief in-place feedback and leaves the
  terminal unchanged.

## Preview actions, zoom, and pan

The popover's image is a native AppKit preview rather than an image embedded in the terminal grid.

- **Copy image** writes an actual image to `NSPasteboard`, using the exact PNG source bytes when available
  and a PNG representation generated from the decoded image for JPEG. It does not copy the media URL,
  caption, or a temporary filesystem path. The action briefly changes to "Copied" after a successful
  pasteboard write.
- **Open** materializes the exact fetched bytes in an app-owned temporary preview cache with a safe UUID
  filename and the validated `.png` or `.jpg` extension, then calls `NSWorkspace.shared.open`. macOS
  selects the user's default image viewer. The cache never deletes a file on popover close or app exit:
  launch-time cleanup removes files older than seven days, then evicts least-recently-modified remaining
  files only if the cache exceeds 256 MiB. This allows an external viewer to finish loading an image while
  still bounding abandoned local copies.
- The image starts fitted inside a bounded preview area. A native `NSScrollView` hosts the image and
  supports pinch magnification plus compact minus, reset-to-fit, and plus controls. Magnification ranges
  from fit to the larger of 8× fit and the image's native 1:1 scale.
- Once magnified above fit, dragging directly on the image pans its scroll view; trackpad scrolling and
  the scroll bars pan as well. At fit, drag does nothing, so it cannot look like a terminal drag or move
  the popover away from its transcript reference.
- Copy, Open, zoom, and pan all live inside the popover. They never send a mouse event to tmux or the
  provider TUI.

The embedded tmux configuration advertises `hyperlinks` in addition to its current `sixel` feature and
keeps `allow-passthrough on`. A proof test must verify the full embedded path rather than assuming that
either capability alone makes an agent TUI preserve OSC 8 bytes.

## iOS interaction

The same `media` RPC and opaque URL are the only image transport for the phone. The iPhone never receives
a daemon filesystem path or a second image-specific endpoint.

`CardDetailView` owns one `TranscriptImageReference` route and presents it with a full-screen cover. Both
phone terminal surfaces feed that route:

- The default Agent tab is a text-only `capture-pane` render, which cannot retain OSC 8 metadata. Its
  renderer tokenizes only the exact visible `https://orchestra.invalid/media/<UUID>` fallback emitted by
  `publish-image`; that token becomes a tappable image reference. It does not attempt to recognize
  ordinary URLs or filesystem-looking text.
- The opt-in live shell and full-screen agent takeover retain SwiftTerm's link callbacks. Their
  `requestOpenLink` delegate forwards only the same validated Orchestra media URL to the card-detail
  route. The existing empty callback becomes this narrow handler; all other links keep their current
  terminal behavior.

Tapping either reference fetches the image through the shared `media` RPC and opens `MobileImagePreview`
full screen. It has a close control, caption, loading/error state, and a UIKit `UIScrollView` image host:
pinch zoom and direct drag pan are native, and the image initially fits the available screen. Returning
closes the viewer and leaves the terminal/capture at its existing position. A failed or expired reference
shows an in-place error and never opens an arbitrary URL.

The phone viewer uses the standard iOS image action sheet rather than recreating its actions as custom
buttons. Its toolbar has a single Share control that presents `UIActivityViewController` with a decoded
`UIImage` made only from fetched, validated PNG or JPEG data. The system sheet supplies Copy and its
normal share, save, and compatible-app actions in one place; the exact app-specific choices vary with the
installed apps and iOS version. It never shares the Orchestra media URL, a daemon path, or an unvalidated
type. This also means the app does not own a separate `UIPasteboard` or document-interaction-controller
flow on phone. It holds the `UIImage` until both the full-screen preview and the presented Share sheet
have dismissed, then releases it; no Orchestra-managed image file is written on iOS.

**Zoom and pan** remain inside the full-screen `UIScrollView`: pinch changes magnification and direct
dragging pans only the magnified image. The viewer provides compact zoom-out, fit, and zoom-in controls
alongside the gesture support.

## Agent delivery

Both adapters receive the same short standing instruction: when they create an image intended for the
human to inspect, run `orchestra publish-image` on the generated file and use its terminal reference in
the response. Claude receives it as a project skill; Codex receives it as a named Orchestra-owned
`AGENTS.md` section, following the existing delegation/tree document delivery pattern.

The command remains usable without that instruction, and it is the only behavior that creates a preview.
Existing `view_image` messages and arbitrary model-generated paths remain ordinary transcript text until
the agent explicitly publishes the file. This prevents accidental previews and keeps the behavior
consistent across providers.

## Proof and tests

The implementation begins with a non-user-facing proof of the actual render path before relying on it:

1. A temporary isolated tmux server preserves the explicit OSC 8 marker through its configured history,
   verified by capture output that retains the link metadata.
2. A controlled card for each supported agent runs `orchestra publish-image`; the reference is visible in
   the embedded desktop terminal and Command-click opens the correct image. This is a manual acceptance
   check on a dedicated test card, never an automatic interaction with the user's active terminal.
3. If either agent renderer strips OSC 8, the same controlled check proves the visible
   `orchestra.invalid` fallback still resolves through SwiftTerm's implicit-link callback. If neither
   representation survives, the feature stops at the proof task rather than adding fragile row parsing.

Automated coverage includes:

- media-source validation, bounded copy, opaque URL construction, session cleanup, expiry, remote
  retrieval, and startup reconciliation that preserves only a current active epoch;
- `publish-image` command schema/registry/CLI rendering, including the exact OSC 8 open/close sequence
  and plain-text fallback;
- the client link policy, which accepts only valid Orchestra media URLs and rejects ordinary web or file
  links;
- temporary macOS preview-cache naming, seven-day and 256-MiB cleanup behavior, plus the image-copy
  conversion policy for PNG and JPEG;
- phone capture tokenization, live-terminal link forwarding, and the one shared full-screen media route;
- phone share-sheet item construction, including a validated image representation rather than a media
  URL or daemon path, and release after both the share sheet and viewer dismiss;
- existing-command compatibility and the agent-instruction document installation paths.

Native SwiftTerm popover placement and the two real agent renderers remain manual acceptance coverage,
because they depend on the actual AppKit terminal and provider TUI rather than a fake terminal buffer.
Manual acceptance also confirms that Copy pastes pixels into another image-capable app, Open uses the
configured default viewer, and a magnified image pans under both mouse drag and trackpad scroll.
On iPhone it confirms a captured fallback reference and a live-terminal reference both open the same
full-screen preview, which pinch-zooms and drag-pans without changing the terminal's position. It also
confirms that the native Share sheet provides Copy plus device-provided image actions without exposing a
daemon path.

## Scope and non-goals

This feature does not add a persistent image shelf, a rich transcript renderer, Sixel/Kitty/iTerm image
interchange, automatic parsing of paths, direct filesystem URL handling, or passive hover activation. It
does not alter the existing image-paste behavior. The iOS full-screen viewer, native image Share sheet,
and zoom/pan are in scope and share the same RPC; passive hover remains out of scope.
