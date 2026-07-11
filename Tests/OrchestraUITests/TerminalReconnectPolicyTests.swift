import Testing
@testable import OrchestraKit

@Suite struct TerminalReconnectPolicyTests {
    // The iOS schedule, now shared: 1,2,4,8,8 (capped at 8), then give up past the budget.
    @Test func test_reconnectPolicyBackoff() {
        let p = TerminalReconnectPolicy()          // maxReconnects = 5
        // `delay` returns Int?, so compare against an [Int?] literal (a plain [Int] won't type-check).
        #expect((1...5).map { p.delay(forAttempt: $0) } == [1, 2, 4, 8, 8].map(Optional.some))
        #expect(p.delay(forAttempt: 6) == nil)     // budget spent → give up
        #expect(p.delay(forAttempt: 0) == nil)     // 1-based; 0 is not a valid attempt
    }
}
