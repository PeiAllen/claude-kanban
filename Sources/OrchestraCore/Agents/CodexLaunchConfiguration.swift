import Foundation

/// Projects shared Orchestra content onto Codex's native per-invocation configuration surface. Claude
/// packages the same guidance and its own hooks through a managed settings file; this type owns only the
/// Codex TOML spelling and keeps it out of adapter control flow.
///
/// The content is delivered through a per-launch **profile file** (`$CODEX_HOME/<name>.config.toml`,
/// selected with `-p <name>`), NOT inline `-c` overrides. That indirection is load-bearing: the developer
/// instructions alone are ~16KB, and tmux caps a whole `new-session … -- argv` command at ~16KB (it packs
/// the argv into a fixed client→server buffer and aborts overlong ones with "command too long"). Inlining
/// them via `-c` therefore killed every Codex card at spawn. A profile file carries the same content off
/// the command line — codex layers it on top of the user's native config, so auth / `config.toml` /
/// unrelated MCP servers stay untouched while the launch-local `orchestra` server uses the profile's
/// normal same-name precedence — and argv shrinks to just `-p <name>`.
enum CodexLaunchConfiguration {
    /// Argv that selects this launch's profile file. `prepareToLaunch` must have written the matching
    /// `profilePath` first; codex resolves `-p <name>` to `$CODEX_HOME/<name>.config.toml`.
    static func flags(cwd: String) -> [String] {
        ["-p", profileName(cwd: cwd)]
    }

    /// Deterministic codex profile name for this worktree, so `prepareToLaunch` writes the exact file
    /// `-p` later resolves. Hashed (not the raw cwd) to stay a short, filename-safe profile id, and
    /// `orch-` namespaced so it can never collide with a profile the user authored.
    static func profileName(cwd: String) -> String {
        "orch-\(CardFileSpec.cwdHash(cwd))"   // shared djb2 — the file the sweep reaps and `-p` selects agree
    }

    /// A first-line TOML comment stamped into every profile we write, proving Orchestra authorship. The
    /// GC sweep reaps an `orch-*.config.toml` only if it contains this marker — so a user's own hand-written
    /// `~/.codex/orch-<name>.config.toml` (which never carries it) is never deleted, even if its name shares
    /// the hash shape. A bare TOML comment; codex ignores it when layering the profile.
    static let ownershipMarker = "# orchestra-managed card launch profile — GC-owned"

    /// Absolute path of the profile file in the (native) Codex home. Codex only discovers profiles under
    /// `$CODEX_HOME`, so it must live there — clearly namespaced (`orch-…`) and separate from the user's
    /// own `config.toml`/auth, which it never touches.
    static func profilePath(cwd: String, codexHome: String) -> String {
        "\(codexHome)/\(profileName(cwd: cwd)).config.toml"
    }

    /// The profile body as TOML: the SAME hooks, per-project trust, and developer instructions the launch
    /// used to inline via `-c`, now written to a file. Each former `-c key=value` becomes one `key = value`
    /// line — dotted keys are valid TOML and the RHS is already TOML from `TOMLOverride`. Always non-empty
    /// (trust is always set), so a written profile is never a no-op file `-p` would fail to layer.
    static func profileTOML(context: AdapterContext, agentId: String) -> String {
        var lines: [String] = [ownershipMarker]   // first line: proves Orchestra authorship to the GC sweep

        if let hooks = HooksRenderer.codexHooks(orchestraBin: context.orchestraBin, agentId: agentId) {
            for event in hooks.keys.sorted() {
                guard let hooksForEvent = hooks[event],
                      let encoded = TOMLOverride.value(hooksForEvent)
                else { continue }
                lines.append("hooks.\(TOMLOverride.key(event)) = \(encoded)")
            }
        }

        let trust = context.trustCwd ? "trusted" : "untrusted"
        lines.append("projects.\(TOMLOverride.quotedKey(context.cwd)).trust_level = \(TOMLOverride.string(trust))")

        if let instructions = AgentGuidance.developerInstructions(for: agentId) {
            lines.append("developer_instructions = \(TOMLOverride.string(instructions))")
        }
        lines.append(contentsOf: MCPConfiguration.codexTOML(command: context.orchestraMCPBin, access: context.access)
            .split(whereSeparator: \.isNewline)
            .map(String.init))
        return lines.joined(separator: "\n") + "\n"
    }
}

/// Minimal TOML emission for values Orchestra owns. Keeping the encoding typed avoids interpolating paths,
/// hook commands, or instructions into a shell string; argv remains an array all the way to tmux.
enum TOMLOverride {
    static func key(_ value: String) -> String {
        guard !value.isEmpty,
              value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") })
        else { return quotedKey(value) }
        return value
    }

    static func quotedKey(_ value: String) -> String { string(value) }

    static func string(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x08: out += "\\b"
            case 0x09: out += "\\t"
            case 0x0A: out += "\\n"
            case 0x0C: out += "\\f"
            case 0x0D: out += "\\r"
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0..<0x20, 0x7F:
                let hex = String(scalar.value, radix: 16, uppercase: true)
                out += "\\u" + String(repeating: "0", count: max(0, 4 - hex.count)) + hex
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    static func value(_ value: JSONValue) -> String? {
        switch value {
        case .null:
            return nil
        case .bool(let bool):
            return bool ? "true" : "false"
        case .int(let int):
            return String(int)
        case .double(let double):
            return double.isFinite ? String(double) : nil
        case .string(let text):
            return Self.string(text)
        case .array(let elements):
            let encoded = elements.compactMap(Self.value)
            guard encoded.count == elements.count else { return nil }
            return "[" + encoded.joined(separator: ", ") + "]"
        case .object(let object):
            var encoded: [String] = []
            for rawKey in object.keys.sorted() {
                guard let json = object[rawKey], let rendered = Self.value(json) else { return nil }
                encoded.append("\(Self.key(rawKey)) = \(rendered)")
            }
            return "{" + encoded.joined(separator: ", ") + "}"
        }
    }
}
