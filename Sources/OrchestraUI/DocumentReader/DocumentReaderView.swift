import SwiftUI
import OrchestraKit

/// The document reader, shared by the desktop inspector tab and the phone's Notes tab.
///
/// One surface for the whole loop: browse the workspace's documents, read one, pick a passage, write a
/// comment, send it to this card's agent — and watch the document refresh itself as the agent edits.
@MainActor
public struct DocumentReaderView: View {
    public let task: Task
    @EnvironmentObject private var model: BoardModel
    @Environment(\.theme) private var theme: Theme
    @StateObject private var reader = DocumentReaderModel()
    @FocusState private var composeFocused: Bool

    public init(task: Task) { self.task = task }

    public var body: some View {
        content
            .task(id: task.id) {
                await reader.loadList(fetch: fetchList)
                // Open straight into the only document, or into the most relevant one — the daemon
                // sorts changed-first, so `.first` is what the reviewer came for. Done HERE rather
                // than in the model so the content fetch is awaited with it.
                if reader.selected == nil, let first = reader.documents.first {
                    await reader.open(first, fetch: fetchBody)
                }
            }
            // A live change for THIS card. The model holds it while composing so text cannot move
            // under the user mid-sentence.
            .onChange(of: model.documentChanges[task.id]) { _, change in
                guard let change else { return }
                _Concurrency.Task {
                    await reader.changed(path: change.path, list: fetchList, read: fetchBody)
                }
            }
            // Events broadcast while the link was down are not replayed, so coming back online
            // reloads once. That is the whole reconnect story — the daemon watches on its own
            // account, so there is no watch to re-register.
            .onChange(of: model.connected) { _, online in
                guard online else { return }
                _Concurrency.Task { await reader.loadList(fetch: fetchList) }
            }
    }

    private func fetchList() async -> [DocRef] { await model.listDocuments(task.id) }
    private func fetchBody(_ path: String) async -> String? {
        await model.readDocument(task.id, path: path)
    }

    @ViewBuilder private var content: some View {
        if reader.loadingList {
            centered { ProgressView() }
        } else if reader.documents.isEmpty {
            emptyState
        } else {
            VStack(spacing: 0) {
                documentBar
                Divider().overlay(theme.hair)
                if reader.browsing || reader.selected == nil {
                    documentList
                } else {
                    documentBody
                    if reader.comment != nil { composeBar }
                }
            }
        }
    }

    // MARK: - picking a document

    /// The current document plus the affordance to browse. A workspace can hold hundreds of documents,
    /// so the picker is a searchable list rather than a chip bar — a chip bar works for three files and
    /// falls apart past that.
    private var documentBar: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { reader.browsing.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "doc.text").font(.footnote).foregroundStyle(theme.text2)
                Text(reader.selected?.name ?? "Choose a document")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(theme.text)
                    .lineLimit(1).truncationMode(.middle)
                if let s = reader.selected?.status { statusBadge(s) }
                Spacer(minLength: 6)
                Text("\(reader.documents.count)")
                    .font(.caption2.monospacedDigit()).foregroundStyle(theme.text3)
                Image(systemName: reader.browsing ? "chevron.up" : "chevron.down")
                    .font(.caption2).foregroundStyle(theme.text2)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var documentList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.footnote).foregroundStyle(theme.text3)
                TextField("Filter documents…", text: $reader.search)
                    .textFieldStyle(.plain)
                    .font(.footnote)
                    .foregroundStyle(theme.text)
                if !reader.search.isEmpty {
                    Button { reader.search = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.footnote)
                            .foregroundStyle(theme.text3)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider().overlay(theme.hair)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(reader.visibleDocuments) { doc in
                        Button {
                            _Concurrency.Task { await reader.open(doc, fetch: fetchBody) }
                        } label: {
                            HStack(spacing: 8) {
                                // A status badge only where git has something to say. MOST documents
                                // have none — discovery is git-independent — and that is correct
                                // rather than missing data.
                                if let s = doc.status { statusBadge(s) } else { statusSpacer }
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(doc.name).font(.footnote)
                                        .foregroundStyle(theme.text).lineLimit(1)
                                    let dir = (doc.path as NSString).deletingLastPathComponent
                                    if !dir.isEmpty {
                                        Text(dir).font(.caption2).foregroundStyle(theme.text3)
                                            .lineLimit(1).truncationMode(.head)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(doc.path == reader.selected?.path ? theme.chip : .clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if reader.visibleDocuments.isEmpty {
                        Text("No documents match “\(reader.search)”")
                            .font(.footnote).foregroundStyle(theme.text3)
                            .padding(.horizontal, 12).padding(.vertical, 10)
                    }
                }
            }
        }
    }

    // MARK: - reading

    @ViewBuilder private var documentBody: some View {
        if let doc = reader.selected, let body = reader.content {
            DocumentWebView(markdown: body,
                        documentPath: doc.path,
                        theme: theme,
                        assetProvider: { asset in
                            await model.documentAsset(task.id, note: doc.path, asset: asset)
                        },
                        onSelect: { reader.select($0); composeFocused = true })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if reader.loadingContent {
            centered { ProgressView() }
        } else {
            centered {
                Text("Couldn’t read this document.")
                    .font(.footnote).foregroundStyle(theme.text3)
            }
        }
    }

    /// A NATIVE compose field. There is deliberately no quote preview: the selected block is already
    /// highlighted in the page, so a preview would only duplicate it.
    private var composeBar: some View {
        VStack(spacing: 0) {
            Divider().overlay(theme.hair)
            HStack(spacing: 8) {
                TextField("Comment on this passage…", text: $reader.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .focused($composeFocused)
                    .font(.callout)
                    .foregroundStyle(theme.text)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(theme.field)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.fieldBorder, lineWidth: 0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                Button("Cancel") { reader.cancelComment(); applyDeferred() }
                    .buttonStyle(.plain).font(.footnote).foregroundStyle(theme.text2)

                Button {
                    _Concurrency.Task {
                        await reader.send { message in
                            await model.send(task.id, message)
                            return true
                        }
                        applyDeferred()
                    }
                } label: {
                    Text(reader.sending ? "Sending…" : "Send")
                        .font(.footnote.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 14).frame(height: 30)
                        .background(theme.accent.opacity(reader.canSend ? 1 : 0.4))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                // The ONLY double-send guard. A comment carries no dedup key on purpose: a deliberate
                // re-send is meaningful and must never be silently swallowed.
                .disabled(!reader.canSend)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(theme.card)
        }
    }

    /// Closing the compose field releases any refresh that arrived while it was open.
    private func applyDeferred() {
        _Concurrency.Task { await reader.applyPendingRefresh(list: fetchList, read: fetchBody) }
    }

    // MARK: - chrome

    private var emptyState: some View {
        centered {
            VStack(spacing: 8) {
                Image(systemName: "doc.text").font(.system(size: 40)).foregroundStyle(theme.text3)
                Text("No documents").font(.callout.weight(.medium)).foregroundStyle(theme.text2)
                Text("This card’s working directory has no markdown documents.")
                    .font(.footnote).foregroundStyle(theme.text3)
                    .multilineTextAlignment(.center).padding(.horizontal, 36)
            }
        }
    }

    private func statusBadge(_ status: DocumentStatus) -> some View {
        let c: SemColor = status == .added ? theme.green : theme.amber
        return Text(status.rawValue)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(c.text)
            .frame(width: 16, height: 16)
            .background(c.tint)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    /// Keeps names aligned whether or not git had anything to say about a document.
    private var statusSpacer: some View { Color.clear.frame(width: 16, height: 16) }

    private func centered<C: View>(@ViewBuilder _ body: () -> C) -> some View {
        body().frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
