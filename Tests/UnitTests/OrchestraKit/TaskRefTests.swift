import Foundation
import Testing
@testable import OrchestraCore

@Suite("TaskRef — card-ref resolution")
struct TaskRefTests {

    private func sample() -> Task {
        Task(title: "Fix the login flow!", repo: "/repos/app", branch: "feature",
             cwd: "/wt/app/feature", model: AgentModel(id: "m"), startIn: .plan, column: .plan, order: 0,
             initialPrompt: "Fix the login flow!")
    }

    @Test("resolves by full UUID, shortId, and orchestra:// URI; slug is ignored")
    func resolvesAllForms() throws {
        let t = sample()
        let tasks = [t]
        #expect(try resolve(.uuid(t.id), in: tasks).id == t.id)
        #expect(try resolve(.short(t.shortId), in: tasks).id == t.id)
        // The slug in the URI is decorative — a wrong slug still resolves by shortId.
        #expect(try resolve(.uri("orchestra://task/\(t.shortId)-totally-wrong-slug"), in: tasks).id == t.id)
    }

    @Test("ref() produces a round-trippable URI")
    func refRoundTrips() throws {
        let t = sample()
        let ref = t.ref()
        #expect(ref.hasPrefix("orchestra://task/\(t.shortId)"))
        #expect(try resolve(.init(parsing: ref), in: [t]).id == t.id)
    }

    @Test("unknown ref throws")
    func unknownThrows() {
        #expect(throws: OrchestraError.self) { try resolve(.short("zzzzzz"), in: []) }
    }

    @Test("TaskRef parsing classifies the three handle forms")
    func parsing() {
        #expect(TaskRef(parsing: "orchestra://task/abc123-foo") == .uri("orchestra://task/abc123-foo"))
        let u = UUID()
        #expect(TaskRef(parsing: u.uuidString) == .uuid(u))
        #expect(TaskRef(parsing: "AB12CD") == .short("ab12cd"))
    }

    @Test("slugify strips punctuation and lower-cases")
    func slugifyWorks() {
        #expect(slugify("Fix the login flow!") == "fix-the-login-flow")
        #expect(slugify("  Multiple   spaces  ") == "multiple-spaces")
    }

    @Test("titleSeed takes the first line, truncated")
    func titleSeedWorks() {
        #expect(titleSeed(from: "Add OAuth\nand more details") == "Add OAuth")
        let long = String(repeating: "x", count: 100)
        #expect(titleSeed(from: long, max: 10).hasSuffix("…"))
    }
}
