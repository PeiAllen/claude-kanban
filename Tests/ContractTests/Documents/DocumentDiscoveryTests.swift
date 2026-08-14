import Foundation
import Testing
@testable import OrchestraCore
import OrchestraKit

/// The pruned filesystem walk behind the document list. CONTRACT TIER because it IS filesystem
/// behaviour — hidden-file skipping and directory pruning are the things under test, and a fake would
/// only restate the implementation.
@Suite("DocumentDiscovery — the pruned walk")
struct DocumentDiscoveryTests {

    /// Build a tree that exercises every rule at once.
    private func tree() throws -> String {
        let root = NSTemporaryDirectory() + "orch-docs-\(UUID().uuidString)"
        let fm = FileManager.default
        func write(_ rel: String) throws {
            let url = URL(fileURLWithPath: root + "/" + rel)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "x".write(to: url, atomically: true, encoding: .utf8)
        }
        try write("README.md")
        try write("docs/guide.md")
        try write("docs/images/shot.png")          // not a document
        try write("notes/designs/plan.md")         // gitignored in a real repo — must still be found
        try write("Sources/main.swift")            // not a document
        try write(".git/COMMIT_EDITMSG.md")        // hidden dir
        try write(".claude/skills/foo.md")         // hidden dir — machine-owned config, not a document
        try write(".claude/skills/orchestra-tree/SKILL.md")   // what Orchestra itself used to inject
        try write(".github/PULL_REQUEST_TEMPLATE.md")          // hidden dir
        try write(".hidden.md")                    // hidden file
        try write("node_modules/pkg/readme.md")    // denied dir
        try write("build/output.md")               // denied dir
        try write("DerivedData/x/notes.md")        // denied dir
        return root
    }

    @Test("finds documents anywhere, gitignored or not")
    func findsDocumentsRegardlessOfGit() throws {
        let root = try tree()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let found = Set(DocumentDiscovery.walk(root: root))
        // A gitignored `notes/` must list exactly like a tracked `docs/` — discovery is deliberately
        // git-independent, which is the whole point of replacing the changed-notes scope.
        #expect(found.contains("notes/designs/plan.md"))
        #expect(found.contains("docs/guide.md"))
        #expect(found.contains("README.md"))
    }

    @Test("skips non-documents, hidden entries, and denied directories")
    func prunesTheRest() throws {
        let root = try tree()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let found = Set(DocumentDiscovery.walk(root: root))
        #expect(!found.contains("docs/images/shot.png"))     // not a document
        #expect(!found.contains("Sources/main.swift"))       // not a document
        #expect(!found.contains(".hidden.md"))               // hidden file
        #expect(found.allSatisfy { !$0.hasPrefix(".git/") }) // hidden dir
        // Pruned at the DIRECTORY level — the reason this stays cheap on a real project.
        #expect(found.allSatisfy { !$0.hasPrefix("node_modules/") })
        #expect(found.allSatisfy { !$0.hasPrefix("build/") })
        #expect(found.allSatisfy { !$0.hasPrefix("DerivedData/") })
    }

    @Test("every dot-directory is pruned, with no exceptions")
    func dotDirectoriesArePruned() throws {
        // The dot prefix marks machine-owned config, not a document a human reviews. Pruning all of it
        // is fail-safe: it covers tools this walk has never heard of, which an exception list cannot do.
        // The case that forced this: Orchestra injected its own guidance skills into every card's
        // `.claude/skills`, and the reader listed them as `.added` — ABOVE the real documents.
        let root = try tree()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let found = Set(DocumentDiscovery.walk(root: root))
        #expect(found.allSatisfy { !$0.hasPrefix(".") })
        #expect(!found.contains(".claude/skills/orchestra-tree/SKILL.md"))
        #expect(!found.contains(".claude/skills/foo.md"))
        #expect(!found.contains(".github/PULL_REQUEST_TEMPLATE.md"))
        // The rule did not swallow the documents that matter.
        #expect(found.contains("docs/guide.md"))
        #expect(found.contains("notes/designs/plan.md"))
    }

    @Test("results are relative, sorted, and capped")
    func resultShape() throws {
        let root = try tree()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let found = DocumentDiscovery.walk(root: root)
        #expect(found.allSatisfy { !$0.hasPrefix("/") })     // relative to the root, never absolute
        #expect(found == found.sorted())
        #expect(DocumentDiscovery.walk(root: root, cap: 2).count == 2)
    }

    @Test("a missing root yields nothing rather than throwing")
    func missingRootIsEmpty() {
        #expect(DocumentDiscovery.walk(root: "/nope/does/not/exist").isEmpty)
    }

    @Test("isPruned agrees with the walk, so the watcher cannot drift from discovery")
    func isPrunedMatchesTheWalk() {
        // The watcher sees absolute paths from the OS instead of walking, so it needs a component
        // test. If these two disagreed, a change under a denied directory would emit an event for a
        // document the list never shows.
        #expect(DocumentDiscovery.isPruned(relativePath: "node_modules/pkg/readme.md"))
        #expect(DocumentDiscovery.isPruned(relativePath: ".git/x.md"))
        #expect(DocumentDiscovery.isPruned(relativePath: "docs/.secret.md"))
        // The watcher must prune dot-directories too. If it did not, an injected
        // `.claude/skills/orchestra-tree/SKILL.md` would emit change events for a document the list
        // never shows, and the reader would refetch on every launch.
        #expect(DocumentDiscovery.isPruned(relativePath: ".claude/skills/orchestra-tree/SKILL.md"))
        #expect(DocumentDiscovery.isPruned(relativePath: ".github/PULL_REQUEST_TEMPLATE.md"))
        #expect(!DocumentDiscovery.isPruned(relativePath: "docs/guide.md"))
        #expect(!DocumentDiscovery.isPruned(relativePath: "notes/designs/plan.md"))
    }

    @Test("only renderable documents count")
    func onlyRenderableExtensions() {
        #expect(DocumentDiscovery.isDocument("a.md"))
        #expect(DocumentDiscovery.isDocument("a.MARKDOWN"))
        #expect(!DocumentDiscovery.isDocument("a.png"))
        #expect(!DocumentDiscovery.isDocument("a.swift"))
    }
}
