import Foundation
import Testing
@testable import OrchestraCore

@Suite("Redirect mechanics — rebase --onto after a squash-merged parent")
struct RedirectMechanicsTests {

    @Test("rebase --onto <grandparent> <recorded-base> transplants ONLY the child's own commits, no conflict")
    func onlyChildCommitsTransplant() async throws {
        let repo = TestEnv.repo(TestEnv.make().base)
        func git(_ a: String...) throws -> String {
            let r = try Proc.run(["git", "-C", repo] + a)
            #expect(r.ok, "git \(a.joined(separator: " ")): \(r.stderr)")
            return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func write(_ rel: String, _ s: String) throws {
            try s.write(toFile: repo + "/" + rel, atomically: true, encoding: .utf8)
        }

        try git("init", "-q", "-b", "main")
        try git("config", "user.email", "t@t"); try git("config", "user.name", "t")
        try write("shared.txt", "base\n"); try git("add", "-A"); try git("commit", "-q", "-m", "base")

        // parent adds a commit that touches shared.txt
        try git("checkout", "-q", "-b", "parent")
        try write("shared.txt", "base\nPARENT-LINE\n"); try write("p.txt", "p\n")
        try git("add", "-A"); try git("commit", "-q", "-m", "parent work")
        let recordedBase = try git("rev-parse", "parent")   // child's recorded base = parent tip

        // child forks off parent, adds TWO of its own commits
        try git("checkout", "-q", "-b", "child")
        try write("c1.txt", "c1\n"); try git("add", "-A"); try git("commit", "-q", "-m", "child 1")
        try write("c2.txt", "c2\n"); try git("add", "-A"); try git("commit", "-q", "-m", "child 2")

        // parent is SQUASH-merged into main (new OID; same net change to shared.txt)
        try git("checkout", "-q", "main")
        try git("merge", "--squash", "parent")
        try git("commit", "-q", "-m", "squash parent into main")

        // redirect: replay only base..child onto main
        let r = try Proc.run(["git", "-C", repo, "rebase", "--onto", "main", recordedBase, "child"])
        #expect(r.ok, "rebase --onto must apply cleanly (no phantom conflict): \(r.stderr)")

        // child now sits directly on main and carries EXACTLY its own two commits
        try git("checkout", "-q", "child")
        let count = try git("rev-list", "--count", "main..child")
        #expect(count == "2")
        let subjects = try git("log", "--format=%s", "main..child")
        #expect(subjects.contains("child 1"))
        #expect(subjects.contains("child 2"))
        #expect(!subjects.contains("parent work"))   // parent's commit NOT re-applied
    }
}
