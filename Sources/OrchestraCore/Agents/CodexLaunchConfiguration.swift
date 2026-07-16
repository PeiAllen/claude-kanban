import Foundation

/// Projects shared Orchestra content onto Codex's native per-invocation configuration surface. Claude
/// packages the same guidance and its own hooks through a managed settings file; this type owns only the
/// Codex TOML override spelling and keeps it out of adapter control flow.
enum CodexLaunchConfiguration {
    static func flags(context: AdapterContext, agentId: String) -> [String] {
        var flags: [String] = []

        if let hooks = HooksRenderer.codexHooks(orchestraBin: context.orchestraBin, agentId: agentId) {
            for event in hooks.keys.sorted() {
                guard let hooksForEvent = hooks[event],
                      let encoded = TOMLOverride.value(hooksForEvent)
                else { continue }
                flags += ["-c", "hooks.\(TOMLOverride.key(event))=\(encoded)"]
            }
        }

        let trust = context.trustCwd ? "trusted" : "untrusted"
        flags += ["-c", "projects.\(TOMLOverride.quotedKey(context.cwd)).trust_level=\(TOMLOverride.string(trust))"]

        if let instructions = AgentGuidance.developerInstructions(for: agentId) {
            flags += ["-c", "developer_instructions=\(TOMLOverride.string(instructions))"]
        }
        return flags
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
