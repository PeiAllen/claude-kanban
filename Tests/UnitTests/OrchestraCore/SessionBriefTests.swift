import Foundation
import Testing
@testable import OrchestraCore

@Suite("SessionStart orientation — SessionBrief")
struct SessionBriefTests {

    // MARK: sentence content — column + mode + self-id

    @Test("each column names its phase and the card id")
    func perColumn() {
        let plan = SessionBrief.sentence(column: .plan, access: .readWrite, shortId: "abc123", origin: .worktree)
        let impl = SessionBrief.sentence(column: .impl, access: .readWrite, shortId: "abc123", origin: .worktree)
        let review = SessionBrief.sentence(column: .review, access: .readWrite, shortId: "abc123", origin: .worktree)
        #expect(plan.contains("Plan") && plan.contains("abc123"))
        #expect(impl.contains("Implementation") && impl.contains("abc123"))
        #expect(review.contains("Review") && review.contains("abc123"))
        // The self-move hint carries the card's own id so `move` has a ref.
        #expect(plan.contains("move abc123 --col"))
    }

    @Test("read-only adds the no-mutation clause; read/write does not")
    func readOnlyClause() {
        let ro = SessionBrief.sentence(column: .impl, access: .readOnly, shortId: "d00d", origin: .worktree)
        let rw = SessionBrief.sentence(column: .impl, access: .readWrite, shortId: "d00d", origin: .worktree)
        #expect(ro.lowercased().contains("read-only"))
        #expect(!rw.lowercased().contains("read-only"))
    }

    /// Every card starts with a DERIVED name, and no agent can rename its own live session — so the brief
    /// has to point at `set-title`, in every variant. Worded per origin: only a worktree card is named
    /// after a branch, so the freeform/scratch branch must not claim that.
    @Test("every variant points at set-title, and only worktree cards mention the branch")
    func namingNudge() {
        for origin in [CardOrigin.worktree, .borrowed, .scratch] {
            for access in [CardAccess.readWrite, .readOnly] {
                let s = SessionBrief.sentence(column: .impl, access: access, shortId: "abc123", origin: origin)
                #expect(s.contains("set-title abc123"), "missing the rename hint for \(origin)/\(access)")
                if origin != .worktree {
                    #expect(!s.contains("named after its branch"), "branch framing leaked into \(origin)")
                }
            }
        }
    }

    /// The brief is re-injected at EVERY SessionStart, so nudging a card whose name was deliberately chosen
    /// would repeatedly invite the agent to overwrite its parent's (or the human's) choice.
    /// Slice 3a. The nudge is on EVERY variant — a freeform reviewer blocked on a decision is exactly the
    /// invisible case the declaration exists for — and it is scoped to the END of a turn. That scoping is
    /// load-bearing, not phrasing: an agent whose harness has an in-session choices prompt should use it
    /// mid-turn, so orientation must never read as "ask through Orchestra instead".
    @Test("every variant carries the end-of-turn needs-input nudge, and never steers off the choices box")
    func needsInputNudgePresent() {
        for origin in [CardOrigin.worktree, .borrowed, .scratch] {
            let s = SessionBrief.sentence(column: .impl, access: .readWrite, shortId: "abc123", origin: origin)
            #expect(s.contains("needs-input abc123"))
            #expect(s.contains("END your turn"))       // end-of-turn scoping, not a mid-turn instruction
            #expect(s.contains("re-declare"))          // the daemon retires it; the agent re-asserts
            #expect(!s.lowercased().contains("instead of asking"))
        }
    }

    @Test("a pinned title suppresses the nudge, in every variant")
    func pinnedTitleSuppressesTheNudge() {
        for origin in [CardOrigin.worktree, .borrowed, .scratch] {
            let s = SessionBrief.sentence(column: .impl, access: .readWrite, shortId: "abc123",
                                          origin: origin, titlePinned: true)
            #expect(!s.contains("set-title"), "the rename nudge survived a pinned title for \(origin)")
            #expect(!s.contains("name it for the work"))
            // The rest of the orientation is untouched.
            #expect(s.contains("abc123"))
        }
    }

    // MARK: freeform (non-worktree) cards — no lifecycle column, no self-move hint

    @Test("freeform cards get no column framing and no move hint")
    func freeformNoColumnFraming() {
        // A freeform/scratch card carries a `column` value (ignored by the board, which files it into
        // the freeform dock by ORIGIN) — orientation must NOT hand it the worktree lifecycle text.
        for origin in [CardOrigin.borrowed, .scratch] {
            let s = SessionBrief.sentence(column: .impl, access: .readWrite, shortId: "abc123", origin: origin)
            #expect(s.contains("abc123"))
            #expect(!s.contains("move abc123 --col"))
            #expect(!s.contains("--col"))
            // No lifecycle lane naming — it has no column to be "in".
            #expect(!s.contains("Plan column"))
            #expect(!s.contains("Implementation column"))
            #expect(!s.contains("Review column"))
        }
    }

    @Test("freeform origin nouns: Scratch vs Freeform")
    func freeformNouns() {
        let scratch = SessionBrief.sentence(column: .impl, access: .readWrite, shortId: "s1", origin: .scratch)
        let freeform = SessionBrief.sentence(column: .impl, access: .readWrite, shortId: "f1", origin: .borrowed)
        #expect(scratch.contains("Scratch"))
        #expect(freeform.contains("Freeform"))
    }

    @Test("read-only clause still applies to freeform cards")
    func freeformReadOnlyClause() {
        let ro = SessionBrief.sentence(column: .impl, access: .readOnly, shortId: "d00d", origin: .borrowed)
        let rw = SessionBrief.sentence(column: .impl, access: .readWrite, shortId: "d00d", origin: .borrowed)
        #expect(ro.lowercased().contains("read-only"))
        #expect(!rw.lowercased().contains("read-only"))
    }

    @Test("borrowed (project) cards get the spawn-a-card delegation guidance; scratch does not")
    func borrowedDelegationGuidance() {
        let borrowed = SessionBrief.sentence(column: .impl, access: .readWrite, shortId: "b1", origin: .borrowed)
        let scratch = SessionBrief.sentence(column: .impl, access: .readWrite, shortId: "s1", origin: .scratch)
        // Freeform-on-a-project: don't fix on main / hand-roll a branch — spawn a worktree card.
        #expect(borrowed.contains("spawn"))
        #expect(borrowed.contains("main"))
        // Scratch is a throwaway dir, not a project — no delegation clause.
        #expect(!scratch.contains("spawn"))
    }

    // (SessionStart envelope encoding is covered by HookChannelTests — HookEnvelope.additionalContext.)

    // MARK: service reads the LIVE column (not launch-time startIn)

    @Test("sessionBrief reflects the card's current column after a move")
    func liveColumn() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let task = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "work", repo: repo, branch: "feat"))

        _ = try await env.svc.move(task.id, to: .review)
        let reviewed = try #require(await env.svc.sessionBrief(task.id))
        #expect(reviewed.contains("Review"))

        _ = try await env.svc.move(task.id, to: .impl)
        let building = try #require(await env.svc.sessionBrief(task.id))
        #expect(building.contains("Implementation"))
    }

    @Test("sessionBrief is nil for an unknown card")
    func unknownNil() async {
        let env = TestEnv.make()
        #expect(await env.svc.sessionBrief(UUID()) == nil)
    }

    // MARK: launch — orientation rides the SessionStart hook, NOT the launch positional

    @Test("spawn never folds orientation into the launch positional (the hook delivers it)")
    func noPositionalFold() async throws {
        let env = TestEnv.make()
        let repo = TestEnv.repo(env.base)
        let t = try await TestEnv.spawnAndAwaitLive(env.svc, SpawnInput(id: UUID(), prompt: "build the thing", repo: repo, branch: "cl"))
        let argv = try #require(env.sessions.ensureArgv[env.sessions.sessionName(t.id)])
        // The positional is exactly the user's prompt — no orientation text prepended.
        #expect(argv.last == "build the thing")
    }
}

@Suite("Codex hook rendering")
struct CodexHookRenderingTests {
    @Test("rendered Codex JSON substitutes the orchestra bin + agent id and emits the session command")
    func renderedCodexJSONSubstitutes() throws {
        let got = HooksRenderer.renderedCodexJSON(orchestraBin: "/abs/orchestra", agentId: "codex")
        #expect(!got.contains("__ORCHESTRA_BIN__"))
        #expect(!got.contains("__AGENT_ID__"))
        #expect(!got.contains(#""matcher""#))
        // Assert on the parsed command value — the render emits canonical JSON, so a raw-substring match
        // on the path is format-coupled (JSON escapes `/` as `\/`); decode it instead.
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(got.utf8)) as? [String: Any])
        let hooks = try #require(obj["hooks"] as? [String: Any])
        let sessionStart = try #require(hooks["SessionStart"] as? [[String: Any]])
        let inner = try #require(sessionStart.first?["hooks"] as? [[String: Any]])
        #expect(inner.first?["command"] as? String == "/abs/orchestra _report --event session --agent codex")
    }

    // The idle-Codex-never-wakes bug: Codex's hooks schema accepts only `description`/`hooks` at the top
    // level, so a stray `_comment` makes it REJECT the whole file (`_comment, expected 'description' or
    // 'hooks'`) — the Stop hook never registers and no turn-end inbox drain fires. Claude is immune only
    // because SettingsComposer strips `_comment`; the Codex render path must strip it too. Pin: the
    // rendered file parses as JSON, carries NO `_comment`, and keeps BOTH SessionStart and Stop.
    @Test("rendered Codex hooks parse cleanly (no _comment) and keep both SessionStart + Stop")
    func renderedCodexJSONIsCodexValid() throws {
        let rendered = HooksRenderer.renderedCodexJSON(orchestraBin: "/abs/orchestra", agentId: "codex")
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(rendered.utf8)) as? [String: Any])
        #expect(obj["_comment"] == nil)   // Codex rejects any top-level key other than description/hooks
        let hooks = try #require(obj["hooks"] as? [String: Any])
        #expect(hooks["SessionStart"] != nil)
        #expect(hooks["Stop"] != nil)      // the turn-end inbox drain — its absence is the wake bug
        #expect(hooks["PermissionRequest"] == nil)   // app-server is the sole request authority
    }

    // Pin the strip helper's contract directly (independent of Bundle template resolution): it drops a
    // top-level `_comment`, keeps `hooks`, and — the defensive branch — returns non-object/unparseable
    // input UNCHANGED so a malformed template still installs its hooks rather than collapsing to empty.
    @Test("strippingComment drops _comment, preserves hooks, and passes through non-JSON unchanged")
    func strippingCommentContract() throws {
        let stripped = HooksRenderer.strippingComment(#"{"_comment":"doc","hooks":{"Stop":[]}}"#)
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(stripped.utf8)) as? [String: Any])
        #expect(obj["_comment"] == nil)
        #expect(obj["hooks"] != nil)
        // No `_comment` present → returned verbatim (no needless re-serialization).
        #expect(HooksRenderer.strippingComment(#"{"hooks":{}}"#) == #"{"hooks":{}}"#)
        // Not a JSON object → returned unchanged (fail-safe: never drop the hooks).
        #expect(HooksRenderer.strippingComment("not json at all") == "not json at all")
        #expect(HooksRenderer.strippingComment("[1,2,3]") == "[1,2,3]")
    }

    @Test("in-memory Codex hook render contains the complete comment-free hook object")
    func inMemoryHooksAreCodexValid() throws {
        let hooks = try #require(HooksRenderer.codexHooks(orchestraBin: "/abs/orchestra", agentId: "codex"))
        #expect(hooks["SessionStart"] != nil)
        #expect(hooks["Stop"] != nil)
        #expect(hooks["PermissionRequest"] == nil)
    }
}
