import SwiftUI
import OrchestraKit
import OrchestraUI

// M2 shipped the tabbed shell. The **Agent** tab now lives in `AgentTab.swift` (T3) and the **Terminal**
// tab in `TerminalTab.swift` (T2) — both real (design §3's three-tier Agent/Terminal/Takeover model). The
// **Notes page** (M6) is now built too — see `NotesPage.swift`. The one remaining hook this file holds is
// **Recovery** (dead card → M7; consumed by the Agent tab).

// The Terminal tab (T2) is now built — see `TerminalTab.swift`. Its stub lived here in M2.

// MARK: - Recovery hook (→ M7, built)

/// HOOK for the dead-card **Recovery** view: design §3's recovery panel (why it died · preserved work ·
/// original prompt + Copy prompt · Start new / Try resume / Archive). Built in M7 — the real panel lives in
/// `RecoveryView.swift`; this hook just points the dead-card path at it (the stable call site T3 renders).
struct RecoveryHook: View {
    let task: Task
    var body: some View { RecoveryView(task: task) }
}

// The Notes page (M6) is now built — see `NotesPage.swift` (rendered in-app; Info's "Open notes" pushes
// it). Its hook lived here in M2.
