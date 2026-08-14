import SwiftUI
import OrchestraKit
import OrchestraUI

/// The phone's Docs tab: a thin navigation wrapper around the SHARED reader.
///
/// Everything that used to live here — the file switcher, the markdown rendering, the content fetch —
/// now lives in `OrchestraUI.DocumentReaderView`, which the desktop inspector uses too. One renderer, one
/// selection model, one comment flow; the only per-platform difference is the gesture, and that is
/// handled inside the webview.
struct DocumentsPage: View {
    let task: Task
    @Environment(\.theme) private var theme: Theme

    var body: some View {
        // .id(task.id): see InspectorView — the reader must not carry state across cards.
        DocumentReaderView(task: task)
            .id(task.id)
            .background(theme.winBg)
            .navigationTitle("Docs")
            .navigationBarTitleDisplayMode(.inline)
    }
}
