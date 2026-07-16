import Foundation

/// Retires only the hook commands written by the former global Codex integration. New Orchestra hooks
/// travel in a launch-scoped configuration override, while Codex merges hook sources, so leaving the old
/// commands would invoke the same Stop drain twice. This cleaner deliberately does not install anything.
public enum CodexHooks {
    /// A command fragment unique to Orchestra's edge helper. It recognizes all former Orchestra events,
    /// including retired spellings, without matching unrelated hook descriptions or metadata.
    public static let sentinel = "_report --event"

    /// Remove Orchestra command handlers from a legacy hooks file. Foreign commands in the same handler
    /// group survive, empty groups/events disappear, and a pure Orchestra file is deleted. A malformed
    /// document is intentionally untouched because guessing at executable user configuration is unsafe.
    @discardableResult
    public static func retireLegacy(at path: String) -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var events = root["hooks"] as? [String: Any]
        else { return false }

        var changed = false
        for event in events.keys.sorted() {
            guard let groups = events[event] as? [Any] else { continue }
            var retainedGroups: [Any] = []
            var eventChanged = false

            for rawGroup in groups {
                guard var group = rawGroup as? [String: Any],
                      let handlers = group["hooks"] as? [Any]
                else {
                    retainedGroups.append(rawGroup)
                    continue
                }

                let retainedHandlers = handlers.filter { !isOrchestraHandler($0) }
                guard retainedHandlers.count != handlers.count else {
                    retainedGroups.append(rawGroup)
                    continue
                }
                changed = true
                eventChanged = true
                guard !retainedHandlers.isEmpty else { continue }
                group["hooks"] = retainedHandlers
                retainedGroups.append(group)
            }

            guard eventChanged else { continue }
            if retainedGroups.isEmpty {
                events.removeValue(forKey: event)
            } else {
                events[event] = retainedGroups
            }
        }
        guard changed else { return false }

        if events.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = events
        }
        if let comment = root["_comment"] as? String, comment.contains("Orchestra-managed") {
            root.removeValue(forKey: "_comment")
        }

        if root.isEmpty {
            do {
                try FileManager.default.removeItem(atPath: path)
                return true
            } catch {
                return false
            }
        }
        guard let rewritten = try? JSONSerialization.data(withJSONObject: root,
                                                           options: [.sortedKeys, .prettyPrinted]) else {
            return false
        }
        do {
            try rewritten.write(to: URL(fileURLWithPath: path), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private static func isOrchestraHandler(_ raw: Any) -> Bool {
        guard let handler = raw as? [String: Any],
              let command = handler["command"] as? String
        else { return false }
        return command.contains(sentinel)
    }
}
