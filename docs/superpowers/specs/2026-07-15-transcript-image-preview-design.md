# Transcript-Anchored Image Preview Design

**Date:** 2026-07-15
**Status:** Approved direction; awaiting review of this written spec

## Goal

Let any Orchestra-hosted agent publish an image as a short reference at the exact place it was produced
in its terminal transcript. Activating that reference opens a temporary native preview. The reference
scrolls with tmux history; the preview is not a persistent attachment, gallery, or terminal-image
protocol feature.

The initial surface is the macOS embedded terminal and works for both Codex and Claude. It is deliberately
agent-neutral: the contract is an Orchestra CLI command and a daemon-owned media record, not a parser for
provider-specific tool text or file paths.

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
lifecycle dependency. A relaunch/restart replaces the prior epoch's media directory, and archive removes
the card's media directory. If an old terminal marker remains visible after its record has been removed,
activation shows a small "Image preview expired" message rather than following a file path or failing
silently.

The app resolves the opaque URL through a read-only `media` RPC, not by opening the asset path itself.
The response carries bounded Base64 image bytes plus caption and MIME type, so the exact same mechanism
works when the daemon is remote. The app keeps decoded image data in memory only for the lifetime of an
open preview.

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
- **Open** materializes the exact fetched bytes in an app-owned temporary preview cache with a safe
  UUID filename and the validated `.png` or `.jpg` extension, then calls `NSWorkspace.shared.open`. macOS
  selects the user's default image viewer. Cache files stay available until the next app launch's
  age-based cleanup, so an external viewer never races a file deletion.
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

- media-source validation, bounded copy, opaque URL construction, session cleanup, expiry, and remote
  retrieval;
- `publish-image` command schema/registry/CLI rendering, including the exact OSC 8 open/close sequence
  and plain-text fallback;
- the client link policy, which accepts only valid Orchestra media URLs and rejects ordinary web or file
  links;
- temporary preview-cache naming and cleanup, plus the image-copy conversion policy for PNG and JPEG;
- existing-command compatibility and the agent-instruction document installation paths.

Native SwiftTerm popover placement and the two real agent renderers remain manual acceptance coverage,
because they depend on the actual AppKit terminal and provider TUI rather than a fake terminal buffer.
Manual acceptance also confirms that Copy pastes pixels into another image-capable app, Open uses the
configured default viewer, and a magnified image pans under both mouse drag and trackpad scroll.

## Scope and non-goals

This feature does not add a persistent image shelf, a rich transcript renderer, Sixel/Kitty/iTerm image
interchange, automatic parsing of paths, direct filesystem URL handling, or passive hover activation. It
does not alter the existing image-paste behavior. iOS receives the opaque-link resolver only after the
macOS proof succeeds; mobile tap/hover, copy, open, and zoom semantics are intentionally a follow-up
rather than a second unproven input path in this change.
