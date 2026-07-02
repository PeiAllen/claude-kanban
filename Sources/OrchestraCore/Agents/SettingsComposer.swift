import Foundation

/// Composes a single Claude Code `--settings` file from a managed base (the rendered
/// hooks/statusLine template) plus any number of ordered overlay layers.
///
/// WHY THIS EXISTS: Claude Code applies multiple `--settings` flags as **last-file-wins (full
/// replacement), NOT a deep merge** — a key present only in an earlier file is silently dropped once
/// a later `--settings` is passed. So Orchestra must never hand Claude more than one `--settings`;
/// every per-card settings addition (read-only enforcement today, anything future) has to be folded
/// into ONE file here. Adding a new layer = append an overlay dictionary at the call site; the
/// single-merged-file invariant then holds automatically, with no new `--settings` flag to forget.
///
/// The merge mirrors Claude's own cross-scope semantics so composed layers behave the way separate
/// scopes would: nested objects deep-merge, arrays concatenate (string arrays de-duplicated, e.g.
/// `permissions.deny`), and scalars are overlay-wins (later overlay overrides earlier base). Overlays
/// are applied in order, each on top of the running result.
enum SettingsComposer {
    /// Deep-merge `overlay` onto `base`: dicts merge recursively, arrays concatenate (strings deduped),
    /// scalars are overlay-wins.
    static func deepMerge(_ base: [String: Any], _ overlay: [String: Any]) -> [String: Any] {
        var result = base
        for (key, value) in overlay {
            if let baseDict = result[key] as? [String: Any], let overlayDict = value as? [String: Any] {
                result[key] = deepMerge(baseDict, overlayDict)
            } else if let baseArr = result[key] as? [Any], let overlayArr = value as? [Any] {
                result[key] = concat(baseArr, overlayArr)
            } else {
                result[key] = value
            }
        }
        return result
    }

    /// Concatenate two arrays; if every element is a String (e.g. `permissions.deny`), de-duplicate
    /// while preserving order. Arrays of objects (e.g. hook matcher-groups) are concatenated as-is.
    private static func concat(_ a: [Any], _ b: [Any]) -> [Any] {
        let combined = a + b
        guard combined.allSatisfy({ $0 is String }) else { return combined }
        var seen = Set<String>()
        return combined.filter { seen.insert($0 as! String).inserted }
    }

    /// Fold `overlays` (in order) onto the parsed `baseJSON` and serialize to a single settings file.
    /// A `_comment` key in the base is stripped from the output. Tolerates an unparseable/empty base
    /// (falls back to an empty object), so a missing rendered hooks file never drops the overlays.
    static func composeJSON(baseJSON: String, overlays: [[String: Any]]) -> String {
        var obj = (try? JSONSerialization.jsonObject(with: Data(baseJSON.utf8))) as? [String: Any] ?? [:]
        for overlay in overlays { obj = deepMerge(obj, overlay) }
        obj.removeValue(forKey: "_comment")
        let data = try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
