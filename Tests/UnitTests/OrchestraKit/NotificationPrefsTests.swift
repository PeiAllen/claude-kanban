import Foundation
import Testing
import OrchestraKit

@Suite("NotificationPrefs — client-side persistence")
struct NotificationPrefsTests {

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "orch-notify-test-\(UUID().uuidString)")!
    }

    @Test("defaults match the shipped notifier scheme when nothing is stored")
    func defaults() {
        let p = NotificationPrefs(defaults: freshDefaults())
        #expect(p.scope(.humanRequired) == .always)
        #expect(p.scope(.died) == .always)
        #expect(p.sound(.humanRequired) == .hero)
        #expect(p.sound(.died) == .basso)
    }

    @Test("scope + sound writes persist across a fresh instance on the same suite")
    func persists() {
        let d = freshDefaults()
        let p1 = NotificationPrefs(defaults: d)
        p1.setScope(.off, for: .humanRequired)
        p1.setSound(.none, for: .humanRequired)
        p1.setScope(.always, for: .died)   // same as default, still written

        let p2 = NotificationPrefs(defaults: d)
        #expect(p2.scope(.humanRequired) == .off)
        #expect(p2.sound(.humanRequired) == .none)
        #expect(p2.scope(.died) == .always)
        // Untouched trigger still reports its default.
        #expect(p2.sound(.mergeStalled) == .submarine)
    }

    @Test("storage keys match the macOS AgentNotifier scheme (one shared model, no drift)")
    func keyScheme() {
        #expect(NotificationPrefs.scopeKey(.humanRequired) == "orch_notify_humanRequired_scope")
        #expect(NotificationPrefs.soundKey(.died) == "orch_notify_died_sound")
        // A value written under that key is what a fresh prefs reads back.
        let d = freshDefaults()
        d.set(NotifyScope.background.rawValue, forKey: NotificationPrefs.scopeKey(.humanRequired))
        #expect(NotificationPrefs(defaults: d).scope(.humanRequired) == .background)
    }

    @Test("an unknown stored raw value falls back to the default")
    func unknownRawFallsBack() {
        let d = freshDefaults()
        d.set("bogus", forKey: NotificationPrefs.scopeKey(.died))
        d.set("Kazoo", forKey: NotificationPrefs.soundKey(.died))
        let p = NotificationPrefs(defaults: d)
        #expect(p.scope(.died) == .always)   // default
        #expect(p.sound(.died) == .basso)    // default
    }
}
