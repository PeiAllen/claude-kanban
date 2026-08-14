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
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var reader = DocumentReaderModel()
    /// Phone only: whether the comment sheet is raised. The pass outlives it — see `phoneCommentBar`.
    @State private var phoneSheetUp = false

    public init(task: Task) { self.task = task }

    /// What the poll is keyed on. Changing EITHER half restarts `.task`, which is how the poll stops
    /// when the app goes away and resumes — with an immediate ask — when it comes back.
    private struct PollKey: Equatable { let card: UUID; let awake: Bool }

    public var body: some View {
        content
            // `.background` only, never `.inactive`: on the Mac a window that merely lost focus is still
            // on screen, and a reader that stopped updating whenever you clicked another app would be a
            // worse bug than the one this fixes.
            .task(id: PollKey(card: task.id, awake: scenePhase != .background)) {
                // Backgrounded. SwiftUI does NOT cancel `.task` for a scene change, so without this the
                // timer keeps firing at a screen nobody is looking at — on a phone, over cellular, until
                // iOS gets around to suspending the process. The rest of this app already gates on scene
                // phase (the connection reconnects on it, terminals stop painting); the reader was the
                // one surface that ignored it.
                guard scenePhase != .background else { return }
                await reader.loadList(fetch: fetchList)
                // Open straight into the only document, or into the most relevant one — the daemon
                // sorts changed-first, so `.first` is what the reviewer came for. Done HERE rather
                // than in the model so the content fetch is awaited with it.
                if reader.selected == nil, let first = reader.documents.first {
                    await reader.open(first, fetch: fetchBody)
                } else {
                    // Already reading something — so this is a return from the background, and the file
                    // may have moved while we were gone. Ask once now instead of waiting out a tick.
                    await reader.pollContent(fetchBody)
                }
                // THE POLL. It lives inside `.task`, so it runs only while this view is on screen and
                // SwiftUI cancels it on the way out — there is no timer to invalidate and nothing to
                // leak. Two rates, because the two questions cost wildly different amounts: asking
                // whether the open document moved is a validator round trip, while asking whether the
                // document SET moved makes the daemon walk the tree.
                //
                // This is what replaced a filesystem watcher. See `docs/09-design-decisions.md`.
                var ticks = 0
                while !_Concurrency.Task.isCancelled {
                    try? await _Concurrency.Task.sleep(for: .seconds(Self.contentPollSeconds))
                    if _Concurrency.Task.isCancelled { break }
                    await reader.pollContent(fetchBody)
                    ticks += 1
                    if ticks % Self.listPollEveryNTicks == 0 { await reader.pollList(fetchListConditional) }
                }
            }
    }

    /// How often the open document is re-asked about. A validator round trip, so this is cheap enough
    /// to feel live without being a stream.
    static let contentPollSeconds = 2
    /// How many content ticks pass between document-SET polls. The set is the expensive question — a
    /// tree walk, plus two git forks when it actually moved — so it runs on its own much slower clock.
    /// At 2s a tick this is 30s, which is how long a NEWLY created document takes to appear on its own.
    /// Opening the picker asks immediately, for when that is too slow.
    static let listPollEveryNTicks = 15

    private func fetchList(_ ifNoneMatch: String?) async -> DocumentList? {
        await model.listDocuments(task.id, ifNoneMatch: ifNoneMatch)
    }
    /// Same call as `fetchList`; named apart only to make the two poll rates legible at the call site.
    private func fetchListConditional(_ ifNoneMatch: String?) async -> DocumentList? {
        await fetchList(ifNoneMatch)
    }
    private func fetchBody(_ path: String, _ ifNoneMatch: String?) async -> DocumentContent? {
        await model.readDocument(task.id, path: path, ifNoneMatch: ifNoneMatch)
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
                    readingSurface
                }
            }
        }
    }

    /// The document, plus the reading pass beside it.
    ///
    /// On the Mac the rail is a column. On the phone there is no room for one, so the same rail becomes
    /// a sheet the document keeps scrolling behind — one comment model, two containers.
    @ViewBuilder private var readingSurface: some View {
        #if os(macOS)
        HStack(spacing: 0) {
            documentBody
            if !reader.comments.isEmpty {
                Divider().overlay(theme.hair)
                rail.frame(width: Self.railWidth)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.18), value: reader.comments.isEmpty)
        #else
        documentBody
            // Dismissing the sheet HIDES the pass, it does not end it. A swipe down is far too cheap a
            // gesture to destroy something the reviewer has written, and the sheet covers the document
            // they are commenting on — so wanting it out of the way is the common case, not a signal
            // that they are finished. This bar brings it back.
            .overlay(alignment: .bottom) {
                if !phoneSheetUp && !reader.comments.isEmpty { phoneCommentBar }
            }
            .sheet(isPresented: $phoneSheetUp) {
                rail
                    .presentationDetents([.height(280), .large])
                    // The reviewer must be able to keep reading — and keep tapping new passages —
                    // while the sheet is up. Without this the sheet is a modal over the document it
                    // is about.
                    .presentationBackgroundInteraction(.enabled(upThrough: .height(280)))
                    .presentationDragIndicator(.visible)
            }
            // A NEW anchor raises the sheet, so a tap goes straight to a field you can type in.
            .onChange(of: reader.comments.count) { old, new in
                if new > old { phoneSheetUp = true }
            }
        #endif
    }

    /// The phone's way back to a hidden pass. Counts the whole pass, and says how much of it is still
    /// unsent — that is the part that would be lost if the reader walked away.
    private var phoneCommentBar: some View {
        Button { phoneSheetUp = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "text.bubble").font(.caption)
                Text("\(reader.comments.count) comment\(reader.comments.count == 1 ? "" : "s")")
                    .font(.footnote.weight(.semibold))
                if !reader.unsent.isEmpty {
                    Text("· \(reader.unsent.count) unsent")
                        .font(.caption2).foregroundStyle(theme.amber.text)
                }
            }
            .foregroundStyle(theme.text)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(theme.hair, lineWidth: 0.5))
            .padding(.bottom, 14)
        }
        .buttonStyle(.plain)
    }

    /// How wide the rail is. A comment is a sentence or two, so this is sized for that rather than for
    /// the document — it is a margin, not a second pane.
    static let railWidth: CGFloat = 288

    private var rail: some View {
        DocumentCommentRail(
            reader: reader,
            send: { id in
                _Concurrency.Task {
                    // Report the REAL outcome: on failure the model keeps the anchor and the draft, so
                    // a dropped link costs a retry rather than the user's comment.
                    await reader.send(id) { message in await model.send(task.id, message) }
                }
            },
            sendAll: {
                _Concurrency.Task {
                    await reader.sendAll { message in await model.send(task.id, message) }
                }
            })
    }


    // MARK: - picking a document

    /// The current document plus the affordance to browse. A workspace can hold hundreds of documents,
    /// so the picker is a searchable list rather than a chip bar — a chip bar works for three files and
    /// falls apart past that.
    private var documentBar: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { reader.browsing.toggle() }
            // Opening the picker is the impatient path: ask for the set NOW rather than waiting out
            // the slow poll, so a document the agent just created is there when you look for it.
            if reader.browsing { _Concurrency.Task { await reader.loadList(fetch: fetchList) } }
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
                    if reader.canRevealAll && !reader.showingAll {
                        sectionHeader("Changed by this card")
                    }
                    ForEach(reader.browseList) { doc in
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
                    // The untouched majority is one tap away rather than buried above the fold.
                    if reader.canRevealAll {
                        Button {
                            withAnimation(.easeOut(duration: 0.15)) { reader.showingAll.toggle() }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: reader.showingAll ? "chevron.down" : "chevron.right")
                                    .font(.caption2)
                                Text(reader.showingAll
                                     ? "Hide the rest"
                                     : "Show all \(reader.documents.count) documents")
                                    .font(.footnote)
                                Spacer(minLength: 0)
                            }
                            .foregroundStyle(theme.text2)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if reader.browseList.isEmpty {
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
                        highlights: DocumentHighlights(
                            keep: reader.liveHighlights,
                            active: reader.comments.first { $0.id == reader.activeComment }?.highlightID),
                        reveal: reader.revealHighlight,
                        assetProvider: { asset in
                            await model.documentAsset(task.id, note: doc.path, asset: asset)
                        },
                        onSelect: { reader.select($0) },
                        onDetached: { reader.markDetached($0) },
                        // Follow the reading position. Only while nothing is half-written: yanking the
                        // rail around under someone's cursor as they scroll to check a reference is
                        // worse than the cue is worth.
                        onVisible: { id in
                            guard !reader.composing else { return }
                            if let c = reader.comments.first(where: { $0.highlightID == id }) {
                                reader.activeComment = c.id
                            }
                        })
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

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(theme.text3)
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Keeps names aligned whether or not git had anything to say about a document.
    private var statusSpacer: some View { Color.clear.frame(width: 16, height: 16) }

    private func centered<C: View>(@ViewBuilder _ body: () -> C) -> some View {
        body().frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
