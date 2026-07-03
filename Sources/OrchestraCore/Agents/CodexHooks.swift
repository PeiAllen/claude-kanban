import Foundation

/// Installs Orchestra's managed Codex hooks file into the pinned `$CODEX_HOME/hooks.json`. Codex 0.135+
/// ships a Claude-parity **SessionStart** hook whose stdout `hookSpecificOutput.additionalContext` is
/// folded into the session — the same inbound channel Claude uses — so the card's column/mode/self-id
/// orientation ([[SessionBrief]]) rides that hook instead of the launch positional. Orientation ONLY:
/// the hook runs `orchestra _report --event orient`, which prints the brief and sends NO telemetry
/// (Codex telemetry stays the daemon-side rollout tail).
///
/// Ownership: Orchestra owns the pinned CODEX_HOME's global level (it already writes `AGENTS.md` there),
/// but a hooks file is executable config, so this is deliberately conservative — it **never clobbers a
/// FOREIGN user hooks.json**. It writes only when the destination is absent or already Orchestra's
/// (identified by the [[sentinel]] command). Best-effort: never throws into a launch path.
public enum CodexHooks {
    /// Marker identifying an Orchestra-rendered hooks file — the `orchestra _report` command no other
    /// tool emits. (A pre-change file wired the retired `--event orient`; those are cleared, not migrated.)
    public static let sentinel = "_report --event session"

    /// Install `content` (the rendered hooks JSON) at `dest`, unless `dest` already exists and is a
    /// foreign (non-Orchestra) hooks file. Returns `true` iff it wrote. Idempotent for our own file.
    @discardableResult
    public static func installIfSafe(content: String, to dest: String) -> Bool {
        if let existing = try? String(contentsOfFile: dest, encoding: .utf8),
           !existing.contains(sentinel) {
            return false   // a user's own hooks.json — leave it; the card just misses the orient hook
        }
        let dir = (dest as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        do { try content.write(toFile: dest, atomically: true, encoding: .utf8); return true }
        catch { return false }
    }

    /// Convenience: read the daemon-rendered hooks file at `src` (default `Config.codexHooksPath`) and
    /// install it at `dest`. No-op (returns false) if the rendered source is missing.
    @discardableResult
    public static func install(fromRendered src: String = Config.codexHooksPath, to dest: String) -> Bool {
        guard let content = try? String(contentsOfFile: src, encoding: .utf8) else { return false }
        return installIfSafe(content: content, to: dest)
    }
}
