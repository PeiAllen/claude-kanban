// Pure parser for the CLI `send-keys` argv → an ordered key chord. Lives in OrchestraKit (Foundation
// only) beside the rest of the keyboard vocabulary so it is unit-testable without the `orchestra`
// executable target (which has no test harness), and so the CLI stays a thin caller.

/// Parses the argv that follows `orchestra send-keys` (the ref + chord tokens) into an ordered chord,
/// **preserving argv order**. The ordering is the whole point: `send-keys <ref> Enter --text y` must
/// yield `[Enter, "y"]` (Enter then the literal `y`), not text-first. The pre-fix CLI appended the
/// `--text` value ahead of every positional regardless of where it appeared, inverting the chord.
///
/// Grammar (left to right):
/// - the FIRST bare token is the card `ref`;
/// - each later bare token is a named key when it matches the `KeyName` vocabulary, else literal text;
/// - `--text <value>` forces a literal-text element AT ITS POSITION (even if `<value>` looks like a key);
/// - `--window <value>` selects the target window (default `agent`);
/// - `--` makes every remaining token literal text (so a token like `Enter` is sent as the word, and a
///   token starting with `-` isn't mistaken for a flag);
/// - an unknown `--flag` is skipped (with its value, when the next token isn't itself a flag), matching
///   the lenient behavior of the CLI's generic flag parser.
public enum SendKeysArgv {
    public struct Parsed: Equatable, Sendable {
        /// The card ref (first bare token), or nil if none was given (the caller falls back to `--ref`).
        public var ref: String?
        /// The target tmux window (`--window`, default `agent`).
        public var window: String
        /// The ordered chord, argv-order preserved.
        public var tokens: [KeyToken]
        public init(ref: String?, window: String, tokens: [KeyToken]) {
            self.ref = ref; self.window = window; self.tokens = tokens
        }
    }

    public static func parse(_ args: [String]) -> Parsed {
        var ref: String? = nil
        var window = "agent"
        var tokens: [KeyToken] = []
        var literalRest = false
        var i = 0
        while i < args.count {
            let a = args[i]
            if literalRest { tokens.append(.text(a)); i += 1; continue }
            switch a {
            case "--":
                literalRest = true; i += 1
            case "--text":
                if i + 1 < args.count { tokens.append(.text(args[i + 1])); i += 2 }
                else { i += 1 }   // dangling flag: nothing to add (the CLI reports "needs a key")
            case "--window":
                if i + 1 < args.count { window = args[i + 1]; i += 2 }
                else { i += 1 }
            default:
                if a.hasPrefix("--") {
                    // Unknown flag: skip it, plus its value when the next token isn't itself a flag.
                    i += (i + 1 < args.count && !args[i + 1].hasPrefix("--")) ? 2 : 1
                } else if ref == nil {
                    ref = a; i += 1
                } else if let key = KeyName(rawValue: a) {
                    tokens.append(.named(key)); i += 1
                } else {
                    tokens.append(.text(a)); i += 1
                }
            }
        }
        return Parsed(ref: ref, window: window, tokens: tokens)
    }
}
