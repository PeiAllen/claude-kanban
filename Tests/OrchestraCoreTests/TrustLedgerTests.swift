import Foundation
import Testing
@testable import OrchestraCore

@Suite("TrustLedger — durable path store")
struct TrustLedgerTests {
    private func tmpPath() -> String {
        NSTemporaryDirectory() + "trust-\(UUID().uuidString)/ledger.json"
    }

    @Test("unrecorded path is untrusted; recorded path is trusted")
    func recordThenTrusted() async throws {
        let ledger = TrustLedger(path: tmpPath())
        let p = "/some/repo"
        #expect(await ledger.isTrusted(p) == false)
        let added = try await ledger.record(p, grantedBy: .human)
        #expect(added == true)
        #expect(await ledger.isTrusted(p) == true)
    }

    @Test("record is idempotent (second record returns false, still trusted)")
    func recordIdempotent() async throws {
        let ledger = TrustLedger(path: tmpPath())
        let p = "/repo/x"
        #expect(try await ledger.record(p, grantedBy: .orchestra) == true)
        #expect(try await ledger.record(p, grantedBy: .orchestra) == false)
        #expect(await ledger.isTrusted(p) == true)
    }

    @Test("ledger persists across restart (new instance, same path)")
    func persistsAcrossRestart() async throws {
        let path = tmpPath()
        do {
            let ledger = TrustLedger(path: path)
            try await ledger.record("/persisted/repo", grantedBy: .repoRegistration)
        }
        let reopened = TrustLedger(path: path)   // simulates a daemon restart
        #expect(await reopened.isTrusted("/persisted/repo") == true)
    }

    @Test("keys are canonicalized (/tmp == /private/tmp on macOS)")
    func canonicalKeys() async throws {
        let ledger = TrustLedger(path: tmpPath())
        let raw = NSTemporaryDirectory() + "canon-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: raw, withIntermediateDirectories: true)
        try await ledger.record(raw, grantedBy: .human)
        #expect(await ledger.isTrusted(PathResolver.canonical(raw)) == true)
    }

    @Test("malformed ledger file → treated as empty, moved to .bak")
    func malformedResetsToEmpty() async throws {
        let path = tmpPath()
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try "not json".write(toFile: path, atomically: true, encoding: .utf8)
        let ledger = TrustLedger(path: path)
        #expect(await ledger.isTrusted("/anything") == false)
        #expect(FileManager.default.fileExists(atPath: path + ".bak"))
    }
}
