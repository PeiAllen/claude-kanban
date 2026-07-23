import Foundation
import Testing
@testable import OrchestraKit

/// The naming rules as pure functions: the ordered derived chain, the explicit-title bound, and the
/// `titleProvisional` split's back-compat decode. No store, no clock, no I/O.
@Suite struct CardNamingTests {

    // MARK: - the derived chain

    @Test("a worktree card is named by its branch, even when a human typed a prompt")
    func worktreeTakesBranch() {
        let r = CardNaming.derived(origin: .worktree, branch: "feat/card-naming", cwd: "/w/card-naming",
                                   access: .readWrite, attachedTargetTitle: nil, prompt: "add set-title")
        #expect(r.title == "feat/card-naming")
        #expect(r.source == .branch)
    }

    @Test("a read-only branchless card is stamped with its target")
    func readOnlyBranchlessStampsTarget() {
        let r = CardNaming.derived(origin: .borrowed, branch: "", cwd: "/w/card-naming", access: .readOnly,
                                   attachedTargetTitle: "feat/card-naming", prompt: "review this")
        #expect(r.title == "👁 feat/card-naming")
        #expect(r.source == .attached)
    }

    @Test("read-write never attaches — it mirrors BoardStore.attachedTarget's readOnly guard")
    func readWriteNeverAttaches() {
        let r = CardNaming.derived(origin: .borrowed, branch: "", cwd: "/r/x", access: .readWrite,
                                   attachedTargetTitle: "target", prompt: "go")
        #expect(r.title == "go")
        #expect(r.source == .prompt)
    }

    @Test("the attached arm is origin-gated, not merely order-gated")
    func worktreeNeverAttachesEvenReadOnly() {
        let r = CardNaming.derived(origin: .worktree, branch: "feat/x", cwd: "/w/x", access: .readOnly,
                                   attachedTargetTitle: "target", prompt: "")
        #expect(r.source == .branch)
    }

    @Test("a branchless card falls back to the prompt, then to its directory")
    func branchlessFallsBackToPromptThenDirectory() {
        #expect(CardNaming.derived(origin: .borrowed, branch: "", cwd: "/r/claude-kanban", access: .readWrite,
                                   attachedTargetTitle: nil, prompt: "poke at the parser").title
                == "poke at the parser")
        // A seeded delegated fork with no title and no prompt: named after the one identity it has. NEVER
        // the seed's cutoff, and never a dead-end placeholder — it is not `awaitingFirstPrompt` (the seed
        // IS its first turn), so nothing later could re-title it.
        let seeded = CardNaming.derived(origin: .borrowed, branch: "", cwd: "/r/claude-kanban",
                                        access: .readWrite, attachedTargetTitle: nil, prompt: "   ")
        #expect(seeded.title == "claude-kanban")
        #expect(seeded.source == .prompt)
        // A scratch dir is a bare UUID, so its basename carries no signal.
        #expect(CardNaming.derived(origin: .scratch, branch: "", cwd: "/s/9f76e014", access: .readWrite,
                                   attachedTargetTitle: nil, prompt: "").title == "Scratch")
    }

    /// `SpawnInput` permits a `branch` alongside `cwd`/`scratch`, and BoardStore always sends one, while
    /// spawn classifies scratch/cwd BEFORE branch. Only a worktree may be named by its branch.
    @Test("a branchless card ignores a stray branch")
    func branchlessIgnoresAStrayBranch() {
        #expect(CardNaming.derived(origin: .borrowed, branch: "feat/x", cwd: "/r/claude-kanban",
                                   access: .readWrite, attachedTargetTitle: nil, prompt: "").title
                == "claude-kanban")
        #expect(CardNaming.derived(origin: .scratch, branch: "feat/x", cwd: "/s/9f76", access: .readWrite,
                                   attachedTargetTitle: nil, prompt: "").title == "Scratch")
    }

    // MARK: - the explicit-title bound

    @Test("normalize trims and caps — the one bound spawn and set-title share")
    func normalizeTrimsAndCaps() {
        #expect(CardNaming.normalize("  Reviewer A\n ") == "Reviewer A")
        #expect(CardNaming.normalize(String(repeating: "x", count: 500)).count == CardNaming.maxTitleChars)
        #expect(CardNaming.normalize("   ").isEmpty)
    }

    // MARK: - the titleProvisional split, on disk

    /// Hand-writing this fixture is a trap: `Phase`'s wire form is `{name, detail}`, not `{kind, run}`, and
    /// a bare `JSONDecoder()` uses `.deferredToDate` where the store uses `OrchestraJSON`'s `.iso8601` —
    /// either mismatch fails the decode for the wrong reason and the test passes vacuously. Round-trip a
    /// REAL card and swap only the key.
    @Test("a pre-split record's titleProvisional decodes into awaitingFirstPrompt")
    func legacyTitleProvisionalDecodes() throws {
        let card = Task(id: UUID(), title: "x", titleSource: .branch, awaitingFirstPrompt: true,
                        repo: "/r", branch: "feat", cwd: "/w", model: AgentModel(id: "m"),
                        startIn: .impl, column: .impl, order: 0, initialPrompt: "")
        var obj = try #require(try JSONSerialization.jsonObject(
            with: OrchestraJSON.pretty.encode(card)) as? [String: Any])
        obj["titleProvisional"] = obj.removeValue(forKey: "awaitingFirstPrompt")   // as a pre-split board wrote it
        obj.removeValue(forKey: "titleSource")
        let decoded = try OrchestraJSON.decoder.decode(
            Task.self, from: try JSONSerialization.data(withJSONObject: obj))
        #expect(decoded.awaitingFirstPrompt)          // the lifecycle half survives the rename
        #expect(decoded.titleSource == .prompt)       // every pre-split title WAS a prompt/seed cutoff
    }

    /// A garbage enum rawValue must cost the FIELD, never the record: `TaskStore.FailableTask` drops any
    /// card whose `Task.init(from:)` throws, so an unguarded decode would delete a live board card the day
    /// a future build writes a `titleSource` this one doesn't know.
    @Test("an unknown titleSource defaults instead of dropping the card")
    func unknownTitleSourceDefaults() throws {
        let card = Task(id: UUID(), title: "x", repo: "/r", branch: "feat", cwd: "/w",
                        model: AgentModel(id: "m"), startIn: .impl, column: .impl, order: 0,
                        initialPrompt: "")
        var obj = try #require(try JSONSerialization.jsonObject(
            with: OrchestraJSON.pretty.encode(card)) as? [String: Any])
        obj["titleSource"] = "somethingFromTheFuture"
        let decoded = try OrchestraJSON.decoder.decode(
            Task.self, from: try JSONSerialization.data(withJSONObject: obj))
        #expect(decoded.titleSource == .prompt)
        #expect(decoded.title == "x")                 // the record itself survived
    }
}
