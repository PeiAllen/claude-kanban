import Testing
import Foundation
import OrchestraKit
@testable import OrchestraCore

@Suite("CardFileSpec — token/path derivation + the single djb2")
struct CardFileSpecTests {
    private func card(cwd: String = "/wt/x", id: UUID = UUID()) -> Task {
        Task(id: id, title: "t", repo: "", branch: "", cwd: cwd, origin: .worktree,
             model: AgentModel(id: "m"), startIn: .impl, column: .impl, order: 0, initialPrompt: "")
    }

    @Test("cwdHash matches the frozen djb2 (must equal the legacy adapter hash byte-for-byte)")
    func djb2Frozen() {
        // Independent reference computation of the SAME algorithm.
        func ref(_ s: String) -> String {
            var h: UInt64 = 5381
            for b in s.utf8 { h = (h &* 33) &+ UInt64(b) }
            return String(h, radix: 16)
        }
        #expect(CardFileSpec.cwdHash("/Users/x/.orchestra/worktrees/r/b") == ref("/Users/x/.orchestra/worktrees/r/b"))
        #expect(CardFileSpec.cwdHash("") == ref(""))
    }

    @Test("path(token:) composes directory/prefix+token+suffix")
    func pathComposition() {
        let spec = CardFileSpec(directory: "/d", prefix: "card-settings-", suffix: ".json", key: .cwdHash)
        #expect(spec.path(token: "abc") == "/d/card-settings-abc.json")
    }

    @Test("token(for:) with .cwdHash hashes the card's cwd")
    func tokenCwdHash() {
        let spec = CardFileSpec(directory: "/d", prefix: "p-", suffix: ".x", key: .cwdHash)
        let c = card(cwd: "/wt/alpha")
        #expect(spec.token(for: c) == CardFileSpec.cwdHash("/wt/alpha"))
    }

    @Test("token(for:) with .shortId is the card's shortId")
    func tokenShortId() {
        let spec = CardFileSpec(directory: "/d", prefix: "readonly-", suffix: ".json", key: .shortId)
        let c = card()
        #expect(spec.token(for: c) == c.shortId)
    }
}
