import SwiftUI
import OrchestraKit
import OrchestraUI

/// The phone's Notes tab: a thin navigation wrapper around the SHARED reader.
///
/// Everything that used to live here — the file switcher, the markdown rendering, the content fetch —
/// now lives in `OrchestraUI.NoteReaderView`, which the desktop inspector uses too. One renderer, one
/// selection model, one comment flow; the only per-platform difference is the gesture, and that is
/// handled inside the webview.
struct NotesPage: View {
    let task: Task
    @Environment(\.theme) private var theme: Theme

    var body: some View {
        NoteReaderView(task: task)
            .background(theme.winBg)
            .navigationTitle("Notes")
            .navigationBarTitleDisplayMode(.inline)
    }
}
