import Foundation

/// Where a card's `title` came from — and therefore what is allowed to overwrite it. This is the naming
/// half of what `titleProvisional` used to conflate; the lifecycle half is `Task.awaitingFirstPrompt`.
///
/// `.explicit` PINS: no derived default may replace it. Everything else is derived and may be re-derived.
/// A legacy record decodes as `.prompt`, which is what every pre-split title actually was (a prompt or
/// seed cutoff), so those cards keep their existing re-title-on-first-prompt behavior.
public enum TitleSource: String, Codable, Sendable, Equatable {
    case branch      // a worktree card, named by its branch
    case attached    // a read-only card, named "👁 <the card whose dir it borrowed>"
    case prompt      // derived from the human prompt — or, failing that, the card's directory
    case explicit    // `spawn(title:)`, `set-title`, or a mirrored in-session `/rename`
}

/// The naming rules, as pure functions over a card's identity — no store, no clock, no I/O.
public enum CardNaming {
    /// Deliberately a glyph and not the word "review": the primitive is read-only ACCESS, not a role.
    public static let attachedGlyph = "👁"

    /// The longest an explicit title may be. 120, not `titleSeed`'s 60: that cap trims a PROMPT down into
    /// a heading, while this holds a name a human or an agent deliberately chose.
    public static let maxTitleChars = 120

    /// The longest a card note may be. Equal to `maxTitleChars` today, and deliberately a SEPARATE constant:
    /// the title cap is tuned for what is safe in Claude's `--name` argv, and a note never reaches argv —
    /// so tuning one must not silently retune the other.
    public static let maxNoteChars = 120

    /// The longest a declared `needs-input` question may be. Wider than a note because a question has to
    /// carry enough to be answerable without opening the card, and it never reaches argv — but still ONE
    /// line: the surface that renders it is a card row, not a transcript.
    public static let maxQuestionChars = 200

    /// The ONE bound on a card title — every write goes through it, not just the explicit ones. The value
    /// ends up in Claude's `--name` argv, so an unbounded title is a tmux argv problem rather than merely
    /// an ugly card, and the derived arms can exceed the cap on their own: a branch name is arbitrary, and
    /// `"👁 <target>"` is longer than its target by construction.
    public static func normalize(_ raw: String) -> String {
        String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxTitleChars))
    }

    /// The same trim, bounded by the NOTE cap. Separate entry point so the two bounds stay independent.
    public static func normalizeNote(_ raw: String) -> String {
        String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxNoteChars))
    }

    /// The same trim, bounded by the QUESTION cap. Newlines collapse to spaces first: the declaration is a
    /// one-line summary by contract, and an agent pasting a wrapped paragraph must not break the row that
    /// renders it.
    public static func normalizeQuestion(_ raw: String) -> String {
        let flat = raw.split(whereSeparator: \.isNewline).joined(separator: " ")
        return String(flat.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxQuestionChars))
    }

    /// The derived default title for a fresh card, as a strict ordered chain:
    ///
    /// 1. a **worktree** card → its branch (the branch IS that card's identity, so it wins even when a
    ///    human typed a prompt);
    /// 2. a **branchless read-only** card with a resolvable target → `"👁 <target title>"`;
    /// 3. a **human prompt** → its first line, cut down;
    /// 4. else the **directory** the card runs in.
    ///
    /// `prompt` is the HUMAN prompt only — a seed is NEVER a title source, which is exactly why arm 4
    /// exists. A card spawned with a seed and no title is never `awaitingFirstPrompt` (the seed IS its
    /// first turn), so no later prompt can re-title it: a bare placeholder there would be permanent, and
    /// its directory is the one identity it actually has.
    public static func derived(origin: CardOrigin, branch: String, cwd: String, access: CardAccess,
                               attachedTargetTitle: String?,
                               prompt: String) -> (title: String, source: TitleSource) {
        if origin == .worktree, !branch.isEmpty { return (normalize(branch), .branch) }
        // Origin-gated, not merely order-gated: `SpawnInput` permits a `branch` alongside `cwd`/`scratch`,
        // and only a worktree may be named by one.
        if origin != .worktree, access == .readOnly, let target = attachedTargetTitle, !target.isEmpty {
            return (normalize("\(attachedGlyph) \(target)"), .attached)
        }
        let typed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { return (titleSeed(from: typed), .prompt) }   // already ≤60
        if origin == .scratch { return ("Scratch", .prompt) }   // its dir is a bare UUID — no signal in it
        let dir = normalize((cwd as NSString).lastPathComponent)
        return (dir.isEmpty ? "New agent" : dir, .prompt)
    }
}
