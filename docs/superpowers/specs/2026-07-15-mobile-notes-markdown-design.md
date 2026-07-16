# Mobile Notes Markdown Rendering Design

**Status:** Approved by delegation to choose the simplest reliable implementation.

## Problem

The iOS Notes page uses a hand-written block parser. It deliberately recognizes only a small
subset of Markdown, so a GFM table is rendered as ordinary paragraph text. The current inline
path delegates to Foundation's `AttributedString(markdown:)`, which covers common emphasis,
code, and link spans but has no math renderer and no test matrix for the notes syntax.

## Goals

- Render the GFM features expected in project notes: headings, paragraphs, hard breaks, fenced
  code, blockquotes, ordered and unordered lists, task-list markers, strikethrough, tables with
  alignment, images, inline links/autolinks, and thematic breaks.
- Render Obsidian/KaTeX-style math delimiters: `$...$`, `$$...$$`, `\\(...\\)`, and `\\[...\\]`.
- Keep math rendering offline by using a native bundled renderer rather than a WebView that loads
  JavaScript or fonts from the network.
- Preserve the existing Orchestra theme and Notes page file-switching behavior.
- Preserve source text when input is malformed or a feature is outside the supported GFM surface.

## Non-goals

- Raw HTML execution or arbitrary embedded HTML widgets. Raw HTML remains visible as escaped/plain
  content so notes cannot inject web content into the app.
- Obsidian-specific features outside the agreed Markdown/math surface, such as wikilinks,
  transclusions, callouts, and footnote navigation.
- Editing, task-state persistence, image caching, or a backend/RPC change.

## Options considered

### 1. Extend the existing native parser and add native math (chosen)

Move the pure Markdown block/inline model into the client-safe `OrchestraKit` target, where it can
be tested without SwiftUI. Keep the app-specific rendering in `MarkdownRender.swift`, add table and
math views, and add the pinned `SwiftMath` iOS package for LaTeX math layout.

This keeps the current visual treatment, makes the parser independently testable, keeps formulas
offline, and limits the change to the notes surface. The parser is intentionally a practical GFM
renderer rather than a promise of every Markdown extension.

### 2. Replace the renderer with an all-in-one Markdown/KaTeX WebView package

This would minimize local parser code, but it would replace the current native styling and make
rendering dependent on the package's WebView lifecycle, HTML sizing, JavaScript, and asset policy.
The package examined for this option loads KaTeX assets from a CDN, which is an unacceptable runtime
dependency for a remote-phone notes view.

### 3. Keep the parser dependency-free and display math as source text

This has the smallest dependency diff, but it does not satisfy the request to make KaTeX-style math
read correctly. It is rejected even though tables and links could be fixed with less code.

## Architecture and data flow

`NotesPage` continues to fetch `[NoteFile]` and select the current file. `MarkdownView` parses the
selected content into value-type blocks and renders each block with the existing theme.

- `OrchestraKit/Markdown`: pure `MarkdownBlock`, table/list/math models, and parser helpers. It
  normalizes line endings, recognizes tables before paragraphs, handles escaped table pipes, splits
  inline math without treating code spans as math, and preserves unrecognized source.
- `MarkdownRender.swift`: SwiftUI block views, Foundation inline `AttributedString` styling, a
  wrapping inline-flow layout for text/math segments, horizontally scrollable tables, `AsyncImage`
  for image blocks, and a `UIViewRepresentable` wrapper around `SwiftMath.MTMathUILabel`.
- `App-iOS/project.yml`: pin SwiftMath to a known tag and link its product only to the iOS app.
- `App-iOS/Tests` and SwiftPM unit tests: parser behavior and link-attribute coverage; the iOS
  compile gate verifies the SwiftMath bridge and the final app target.

Tables render in a horizontal scroll view so narrow phones do not collapse column content. Table
cells reuse the same inline renderer as paragraphs, including links, emphasis, code, strikethrough,
images, and math segments. A failed image displays its alt text; an invalid equation displays its
original source; an invalid table is left as paragraph text.

## Supported syntax contract

| Syntax | Behavior |
| --- | --- |
| `#` headings and setext headings | Styled heading blocks |
| Paragraphs and two-space hard breaks | Themed wrapped text |
| Fenced code with info string | Existing monospaced code block |
| `>`, nested `>` quotes | Themed quote block |
| Ordered/unordered/nested lists | Indented list rows; task markers become checkboxes |
| `~~strike~~`, emphasis, inline code | Foundation attributed spans |
| `[label](url)` and autolinks | Tappable system links using `openURL` |
| `![alt](url)` | Async image; alt text on failure |
| Pipe tables and `:---` alignment markers | Scrollable, styled table |
| `$...$`, `\\(...\\)` | Inline native math |
| `$$...$$`, `\\[...\\]` | Display native math |
| Raw HTML and unknown extensions | Escaped/plain source text |

## Error handling and safety

The parser never throws. It falls back to a paragraph when a table delimiter is missing, a fence
is unterminated, or a math delimiter is unmatched. `SwiftMath` receives only extracted math text;
parse failures keep the original delimiter/source visible. Remote images and links remain ordinary
URL-driven UI behavior, with no HTML or JavaScript execution in the Notes renderer.

## Testing and verification

The red/green test sequence starts with parser tests for tables, alignment, escaped pipes, task
markers, math delimiters, code-span protection, links, and malformed-input fallbacks. Existing
heading/list/quote/fence behavior gets regression cases in the same suite. The app test target
adds a link-attribute assertion and compiles the native math bridge. Verification runs the focused
SwiftPM unit tier, the iOS typecheck/build script, and a simulator Notes fixture containing a table,
links, task items, images, inline math, and display math.

