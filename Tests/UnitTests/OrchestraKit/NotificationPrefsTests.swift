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
        #expect(p.scope(.permission) == .always)
        #expect(p.scope(.needsYou) == .background)
        #expect(p.scope(.died) == .always)
        #expect(p.sound(.permission) == .hero)
        #expect(p.sound(.needsYou) == .submarine)
        #expect(p.sound(.died) == .basso)
    }

    @Test("scope + sound writes persist across a fresh instance on the same suite")
    func persists() {
        let d = freshDefaults()
        let p1 = NotificationPrefs(defaults: d)
        p1.setScope(.off, for: .needsYou)
        p1.setSound(.none, for: .permission)
        p1.setScope(.always, for: .died)   // same as default, still written

        let p2 = NotificationPrefs(defaults: d)
        #expect(p2.scope(.needsYou) == .off)
        #expect(p2.sound(.permission) == .none)
        #expect(p2.scope(.died) == .always)
        // Untouched trigger still reports its default.
        #expect(p2.sound(.needsYou) == .submarine)
    }

    @Test("storage keys match the macOS AgentNotifier scheme (one shared model, no drift)")
    func keyScheme() {
        #expect(NotificationPrefs.scopeKey(.permission) == "orch_notify_permission_scope")
        #expect(NotificationPrefs.soundKey(.died) == "orch_notify_died_sound")
        // A value written under that key is what a fresh prefs reads back.
        let d = freshDefaults()
        d.set(NotifyScope.background.rawValue, forKey: NotificationPrefs.scopeKey(.permission))
        #expect(NotificationPrefs(defaults: d).scope(.permission) == .background)
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
