import Foundation
import Testing
@testable import OrchestraCore
@testable import OrchestraKit
import TestSupport

/// Fake `FileWatching`: records registrations and lets a test fire a batch synchronously. No real
/// FSEvents, no filesystem, no wall-clock — the real stream is pinned in ContractTests instead.
final class FakeWatcher: FileWatching, @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [String: @Sendable (FileWatchEvent) -> Void] = [:]
    private var _cancelCount = 0
    var cancelCount: Int { lock.withLock { _cancelCount } }
    var watchedDirs: [String] { lock.withLock { Array(handlers.keys) } }

    private final class Token: FileWatchToken {
        let onCancel: @Sendable () -> Void
        init(_ c: @escaping @Sendable () -> Void) { onCancel = c }
        func cancel() { onCancel() }
    }

    func watch(directory: String,
               onChange: @escaping @Sendable (FileWatchEvent) -> Void) -> FileWatchToken {
        lock.withLock { handlers[directory] = onChange }
        return Token { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.handlers[directory] = nil; self._cancelCount += 1 }
        }
    }

    /// Fire a normal path-carrying batch at whichever watched root contains `absPath`.
    func fire(_ absPath: String) {
        let h = lock.withLock { handlers.first { absPath.hasPrefix($0.key + "/") }?.value }
        h?(FileWatchEvent(paths: [absPath], needsRescan: false))
    }

    /// Fire an OVERFLOW batch: the OS dropped events, so the paths are incomplete or useless.
    func fireOverflow(inDirectory dir: String) {
        lock.withLock { handlers[dir] }?(FileWatchEvent(paths: ["/"], needsRescan: true))
    }
}

/// The daemon-owned note watcher. There is no per-client registration here by design — the daemon
/// watches every live worktree card for its OWN reasons, exactly as it derives `shellsChanged` from
/// tmux — so this suite has no subscribers, no refcounts, and no connection identity to exercise.
@Suite struct DocumentWatchServiceTests {
    private let card = UUID()
    /// What a card's `cwd` looks like BEFORE canonicalization. `/tmp` is a symlink to `/private/tmp` on
    /// macOS, so using it here is deliberate: it proves the service canonicalizes, which is the whole
    /// reason a symlinked worktree still fires. A test that used an already-canonical path would pass
    /// even if the canonicalization were removed.
    private let wtInput = "/tmp/wt"
    private var wt: String { PathResolver.canonical(wtInput) }
    private let rel = "notes/a.md"
    private var abs: String { wt + "/" + rel }

    // NOTE ON SYNCHRONIZATION — read before editing any test here.
    // `FakeWatcher.fire()` is SYNCHRONOUS, but the watch closure hops back onto the actor with
    // `Task { await self.observe(...) }`. So `observe` has NOT run when the next line executes.
    // Asserting directly after `fire()` would make an "is empty" expectation pass whether or not the
    // behavior works, and make a "did emit" expectation flake. So:
    //   positive ("it emitted")      -> pollUntil
    //   negative ("it did not emit") -> yieldBriefly, which drains the hop without a wall-clock sleep

    private func makeService(_ w: FakeWatcher, hash: Locked<String?>)
        -> (DocumentWatchService, Locked<[DocumentChange]>) {
        let got = Locked<[DocumentChange]>([])
        let svc = DocumentWatchService(watcher: w,
                                   hash: { _ in hash.withLock { $0 } },
                                   emit: { c in got.withLock { $0.append(c) } })
        return (svc, got)
    }

    // MARK: - what reaches a client

    @Test("a changed note emits once, with its new hash")
    func emitsWhenAWatchedDocumentChanges() async throws {
        let w = FakeWatcher(); let hash = Locked<String?>("h1")
        let (svc, got) = makeService(w, hash: hash)
        await svc.sync(cards: [(id: card, worktree: wtInput)])
        w.fire(abs)                                    // first observation seeds and emits
        try await pollUntil("first observation emits", timeout: .seconds(5)) { got.withLock { $0.count } == 1 }
        hash.withLock { $0 = "h2" }
        w.fire(abs)
        try await pollUntil("the change is emitted", timeout: .seconds(5)) { got.withLock { $0.count } == 2 }
        #expect(got.withLock { $0.last?.path } == rel)
        #expect(got.withLock { $0.last?.contentHash } == "h2")
        #expect(got.withLock { $0.last?.cardId } == card)
    }

    @Test("identical bytes never wake a client")
    func suppressesAnUnchangedHash() async throws {
        let w = FakeWatcher(); let hash = Locked<String?>("same")
        let (svc, got) = makeService(w, hash: hash)
        await svc.sync(cards: [(id: card, worktree: wtInput)])
        w.fire(abs)
        try await pollUntil("seed emit", timeout: .seconds(5)) { got.withLock { $0.count } == 1 }
        w.fire(abs); w.fire(abs)                       // a touch, a rewrite with the same content
        await yieldBriefly()
        #expect(got.withLock { $0.count } == 1)
    }

    @Test("non-markdown churn never reaches the hash step")
    func ignoresNonMarkdownWrites() async {
        // The cheap gate that keeps a build from costing anything: a worktree root is watched
        // recursively, so .git / .build / node_modules churn must be discarded before any file read.
        let w = FakeWatcher(); let hash = Locked<String?>("h")
        let (svc, got) = makeService(w, hash: hash)
        await svc.sync(cards: [(id: card, worktree: wtInput)])
        w.fire(wt + "/.build/debug/Orchestra.o")
        w.fire(wt + "/Sources/Foo.swift")
        w.fire(wt + "/.git/index")
        await yieldBriefly()
        #expect(got.withLock { $0.isEmpty })
    }

    @Test("an overflow batch still reports the change")
    func anOverflowBatchStillEmits() async throws {
        // An overflow names no useful path (often just `/`), so the service must re-check what it
        // knows rather than path-match. Otherwise a dropped event strands the note permanently.
        let w = FakeWatcher(); let hash = Locked<String?>("h1")
        let (svc, got) = makeService(w, hash: hash)
        await svc.sync(cards: [(id: card, worktree: wtInput)])
        w.fire(abs)
        try await pollUntil("seed emit", timeout: .seconds(5)) { got.withLock { $0.count } == 1 }
        hash.withLock { $0 = "h2" }
        w.fireOverflow(inDirectory: wt)
        try await pollUntil("overflow triggers a re-check", timeout: .seconds(5)) { got.withLock { $0.count } == 2 }
    }

    @Test("a deleted note is reported, not suppressed")
    func deletionEmitsWithANilHash() async throws {
        let w = FakeWatcher(); let hash = Locked<String?>("h1")
        let (svc, got) = makeService(w, hash: hash)
        await svc.sync(cards: [(id: card, worktree: wtInput)])
        w.fire(abs)
        try await pollUntil("seed emit", timeout: .seconds(5)) { got.withLock { $0.count } == 1 }
        hash.withLock { $0 = nil }                     // the file is gone
        w.fire(abs)
        try await pollUntil("deletion is reported", timeout: .seconds(5)) { got.withLock { $0.count } == 2 }
        #expect(got.withLock { $0.last?.contentHash } == nil)
        // ...and a second event while it is still absent is not a change.
        w.fire(abs)
        await yieldBriefly()
        #expect(got.withLock { $0.count } == 2)
    }

    // MARK: - sync is a diff, and it is idempotent

    @Test("one stream per live worktree card")
    func syncStartsOneStreamPerLiveWorktreeCard() async {
        let w = FakeWatcher(); let hash = Locked<String?>("h")
        let (svc, _) = makeService(w, hash: hash)
        await svc.sync(cards: [(id: card, worktree: wtInput), (id: UUID(), worktree: "/tmp/wt2")])
        #expect(await svc.activeStreamCount == 2)
    }

    @Test("repeat syncs neither duplicate nor churn")
    func syncIsIdempotent() async {
        let w = FakeWatcher(); let hash = Locked<String?>("h")
        let (svc, _) = makeService(w, hash: hash)
        let cards = [(id: card, worktree: wtInput)]
        await svc.sync(cards: cards)
        await svc.sync(cards: cards)
        await svc.sync(cards: cards)
        #expect(await svc.activeStreamCount == 1)      // not 3
        #expect(w.cancelCount == 0)                    // and nothing was torn down and rebuilt
    }

    @Test("a card that is gone loses its stream")
    func syncCancelsAStreamForACardThatIsGone() async {
        // Card teardown is just "it left the desired set" — there is no teardown protocol to get wrong.
        let w = FakeWatcher(); let hash = Locked<String?>("h")
        let (svc, _) = makeService(w, hash: hash)
        await svc.sync(cards: [(id: card, worktree: wtInput)])
        await svc.sync(cards: [])
        #expect(await svc.activeStreamCount == 0)
        #expect(w.cancelCount == 1)
    }

    /// Two cards on ONE working directory share a stream and both hear about a change. Documents are a
    /// property of the directory, so this is the case the reframe exists for.
    @Test("cards sharing a workspace share one stream and both get the event")
    func cardsSharingAWorkspaceShareOneStream() async throws {
        let w = FakeWatcher(); let hash = Locked<String?>("h1")
        let (svc, got) = makeService(w, hash: hash)
        let other = UUID()
        await svc.sync(cards: [(id: card, worktree: wtInput), (id: other, worktree: wtInput)])
        #expect(await svc.activeStreamCount == 1)          // one directory, one stream
        w.fire(abs)
        try await pollUntil("both cards hear it", timeout: .seconds(5)) {
            got.withLock { Set($0.map(\.cardId)) } == [card, other]
        }
        // ...and the file was hashed ONCE, not once per card.
        #expect(got.withLock { $0.map(\.path) } == [rel, rel])
    }

    @Test("a card leaving a shared workspace does not cancel the other's stream")
    func aCardLeavingASharedWorkspaceKeepsTheStream() async {
        let w = FakeWatcher(); let hash = Locked<String?>("h")
        let (svc, _) = makeService(w, hash: hash)
        let other = UUID()
        await svc.sync(cards: [(id: card, worktree: wtInput), (id: other, worktree: wtInput)])
        await svc.sync(cards: [(id: other, worktree: wtInput)])
        #expect(await svc.activeStreamCount == 1)
        #expect(w.cancelCount == 0)                        // the stream was never torn down
    }

    @Test("a missed transition self-heals at the next sync")
    func syncRepairsAMissedTransition() async {
        // The property that replaces rollback and race handling: reconciling from the desired set means
        // a skipped lifecycle call costs a late stream, not a corrupt one.
        let w = FakeWatcher(); let hash = Locked<String?>("h")
        let (svc, _) = makeService(w, hash: hash)
        await svc.sync(cards: [(id: card, worktree: wtInput)])
        await svc.sync(cards: [(id: UUID(), worktree: "/tmp/wt2")])   // two transitions missed
        #expect(await svc.activeStreamCount == 1)
        #expect(w.watchedDirs == [PathResolver.canonical("/tmp/wt2")])
    }

    @Test("a moved worktree is rewatched at its new path")
    func syncFollowsAWorktreeMove() async {
        let w = FakeWatcher(); let hash = Locked<String?>("h")
        let (svc, _) = makeService(w, hash: hash)
        await svc.sync(cards: [(id: card, worktree: wtInput)])
        await svc.sync(cards: [(id: card, worktree: "/tmp/moved")])
        #expect(await svc.activeStreamCount == 1)
        #expect(w.watchedDirs == [PathResolver.canonical("/tmp/moved")])
        #expect(w.cancelCount == 1)
    }
}
