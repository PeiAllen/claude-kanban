// OrchestraUI — the shared SwiftUI layer for the Orchestra board (macOS + iOS).
//
// Holds the design tokens (`Theme`), the board view-model (`BoardModel`), and the four platform
// protocols (`Clipboard` / `SystemOpener` / `WindowConfig` / `TerminalHost`) that let the same
// view-model drive an AppKit desktop and a UIKit phone client. It depends only on the client-safe
// `OrchestraKit`; the daemon/CLI never link it, so no SwiftUI reaches the Linux build.
//
// (Scaffolding placeholder — the real types land in the following layers.)
