import Testing
@testable import OrchestraUI

@Suite("Embedded terminal render-parking policy")
struct TerminalRenderParkingPolicyTests {

    @Test("renders full-rate only when looked at AND on-screen")
    func rendersWhenWatchedAndOnScreen() {
        // The one live case: the window/scene is active and this terminal is on-screen.
        #expect(!TerminalRenderParkingPolicy.shouldPark(animationsActive: true, onScreen: true))
    }

    @Test("parks when the window/scene isn't being looked at, regardless of on-screen")
    func parksWhenNotWatched() {
        #expect(TerminalRenderParkingPolicy.shouldPark(animationsActive: false, onScreen: true))
        #expect(TerminalRenderParkingPolicy.shouldPark(animationsActive: false, onScreen: false))
    }

    @Test("parks when off-screen (scrolled out / collapsed / non-selected) even while watched")
    func parksWhenOffScreen() {
        #expect(TerminalRenderParkingPolicy.shouldPark(animationsActive: true, onScreen: false))
    }
}
