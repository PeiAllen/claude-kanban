import SwiftUI
import OrchestraKit

// Design tokens for the Orchestra board. Moved verbatim from `App/Theme.swift` into the shared
// OrchestraUI target (F2) so the future iOS client renders with the same palette; the only change is
// the `public` surface required for cross-module use — every color value and helper is unchanged.

// MARK: - Color helpers

extension Color {
    public init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
    /// rgba with 0–255 channels.
    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.init(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: a)
    }
}

// MARK: - Accent + density preferences

public enum Accent: String, CaseIterable, Identifiable {
    case blue, purple, graphite
    public var id: String { rawValue }
    public func color(dark: Bool) -> Color {
        switch self {
        case .blue:     return dark ? Color(hex: 0x0A84FF) : Color(hex: 0x007AFF)
        case .purple:   return dark ? Color(hex: 0xBF5AF2) : Color(hex: 0xAF52DE)
        case .graphite: return dark ? Color(hex: 0x8E8E93) : Color(hex: 0x48484A)
        }
    }
}

public enum Density: String, CaseIterable, Identifiable {
    case comfortable, compact
    public var id: String { rawValue }
    public var cardPad: CGFloat { self == .comfortable ? 12 : 9 }
    public var cardGap: CGFloat { self == .comfortable ? 10 : 7 }
    public var cardTitle: CGFloat { self == .comfortable ? 13.5 : 12.5 }
}

/// A semantic color triple (dot/solid, text, tint fill).
public struct SemColor {
    public let dot: Color
    public let text: Color
    public let tint: Color
    public init(dot: Color, text: Color, tint: Color) {
        self.dot = dot
        self.text = text
        self.tint = tint
    }
}

// MARK: - Theme tokens (resolved from colorScheme + accent)

public struct Theme: Sendable {
    public let dark: Bool
    public let accent: Color

    public init(scheme: ColorScheme, accent: Accent) {
        self.dark = scheme == .dark
        self.accent = accent.color(dark: scheme == .dark)
    }

    // Core
    public var winBg: Color      { dark ? Color(hex: 0x1C1C1E) : Color(hex: 0xF4F2EF) }
    public var toolbar: Color    { dark ? Color(r: 28, g: 28, b: 30, a: 0.985) : Color(r: 244, g: 242, b: 239, a: 0.985) }
    public var card: Color       { dark ? Color(hex: 0x2A2A2D) : Color(hex: 0xFFFFFF) }
    public var cardBorder: Color { dark ? Color(r: 255, g: 255, b: 255, a: 0.08) : Color(r: 0, g: 0, b: 0, a: 0.07) }
    public var text: Color       { dark ? Color(hex: 0xF5F5F7) : Color(hex: 0x1D1D1F) }
    public var text2: Color      { dark ? Color(hex: 0x98989D) : Color(hex: 0x86868B) }
    public var text3: Color      { dark ? Color(hex: 0x6E6E73) : Color(hex: 0xA8A8AD) }
    public var hair: Color       { dark ? Color(r: 255, g: 255, b: 255, a: 0.10) : Color(r: 0, g: 0, b: 0, a: 0.09) }
    public var inspector: Color  { dark ? Color(r: 24, g: 24, b: 26, a: 0.99) : Color(r: 248, g: 247, b: 245, a: 0.99) }
    public var termBg: Color     { dark ? Color(hex: 0x131315) : Color(hex: 0xFBFAF8) }
    public var field: Color      { dark ? Color(r: 255, g: 255, b: 255, a: 0.06) : Color(hex: 0xFFFFFF) }
    public var fieldBorder: Color { dark ? Color(r: 255, g: 255, b: 255, a: 0.14) : Color(r: 0, g: 0, b: 0, a: 0.12) }
    public var chip: Color       { dark ? Color(r: 255, g: 255, b: 255, a: 0.08) : Color(r: 0, g: 0, b: 0, a: 0.05) }
    public var chipHover: Color  { dark ? Color(r: 255, g: 255, b: 255, a: 0.14) : Color(r: 0, g: 0, b: 0, a: 0.10) }
    public var colBg: Color      { dark ? Color(r: 255, g: 255, b: 255, a: 0.028) : Color(r: 0, g: 0, b: 0, a: 0.022) }
    public var scroll: Color     { dark ? Color(r: 255, g: 255, b: 255, a: 0.22) : Color(r: 0, g: 0, b: 0, a: 0.22) }
    public var panelOpaque: Color { dark ? Color(hex: 0x202023) : Color(hex: 0xF6F5F3) }
    public var termPrompt: Color { dark ? Color(r: 255, g: 255, b: 255, a: 0.045) : Color(r: 0, g: 0, b: 0, a: 0.028) }
    public var term: Color       { dark ? Color(hex: 0xD6D6DA) : Color(hex: 0x2A2A2E) }
    public var overTint: Color   { dark ? Color(r: 10, g: 132, b: 255, a: 0.12) : Color(r: 0, g: 122, b: 255, a: 0.07) }

    // Semantic palette
    public var gray: SemColor   { dark ? SemColor(dot: Color(hex: 0x98989D), text: Color(hex: 0xB0B0B6), tint: Color(r: 152, g: 152, b: 157, a: 0.18))
                                : SemColor(dot: Color(hex: 0x8E8E93), text: Color(hex: 0x6E6E73), tint: Color(r: 142, g: 142, b: 147, a: 0.12)) }
    public var indigo: SemColor { dark ? SemColor(dot: Color(hex: 0x7D7BFF), text: Color(hex: 0xB3B1FF), tint: Color(r: 125, g: 123, b: 255, a: 0.20))
                                : SemColor(dot: Color(hex: 0x5E5CE6), text: Color(hex: 0x4744C4), tint: Color(r: 94, g: 92, b: 230, a: 0.12)) }
    public var green: SemColor  { dark ? SemColor(dot: Color(hex: 0x30D158), text: Color(hex: 0x54DE86), tint: Color(r: 48, g: 209, b: 88, a: 0.18))
                                : SemColor(dot: Color(hex: 0x34C759), text: Color(hex: 0x1E8E3E), tint: Color(r: 52, g: 199, b: 89, a: 0.14)) }
    public var amber: SemColor  { dark ? SemColor(dot: Color(hex: 0xFF9F0A), text: Color(hex: 0xFFC668), tint: Color(r: 255, g: 159, b: 10, a: 0.18))
                                : SemColor(dot: Color(hex: 0xFF9F0A), text: Color(hex: 0xB25A00), tint: Color(r: 255, g: 159, b: 10, a: 0.16)) }
    public var red: SemColor    { dark ? SemColor(dot: Color(hex: 0xFF453A), text: Color(hex: 0xFF8E86), tint: Color(r: 255, g: 69, b: 58, a: 0.18))
                                : SemColor(dot: Color(hex: 0xFF3B30), text: Color(hex: 0xC9302C), tint: Color(r: 255, g: 59, b: 48, a: 0.12)) }
    public var blue: SemColor   { dark ? SemColor(dot: Color(hex: 0x0A84FF), text: Color(hex: 0x79B6FF), tint: Color(r: 10, g: 132, b: 255, a: 0.20))
                                : SemColor(dot: Color(hex: 0x007AFF), text: Color(hex: 0x0061CC), tint: Color(r: 0, g: 122, b: 255, a: 0.12)) }
    // Workflow-STAGE hues (slice 2b): the subtree segments and peek column chips read planning=purple,
    // implementing=blue, in-review=teal — teal (not amber) for review so saturated amber keeps its one
    // meaning (needs you). Merged is `green`; not-started is a dashed outline (no fill).
    public var purple: SemColor { dark ? SemColor(dot: Color(hex: 0xB48EE8), text: Color(hex: 0xC7ADEF), tint: Color(r: 180, g: 142, b: 232, a: 0.18))
                                : SemColor(dot: Color(hex: 0x9A6FD8), text: Color(hex: 0x6E3FB0), tint: Color(r: 154, g: 111, b: 216, a: 0.14)) }
    public var teal: SemColor   { dark ? SemColor(dot: Color(hex: 0x56C5B8), text: Color(hex: 0x7FD4CA), tint: Color(r: 86, g: 197, b: 184, a: 0.18))
                                : SemColor(dot: Color(hex: 0x2FA497), text: Color(hex: 0x1E7268), tint: Color(r: 47, g: 164, b: 151, a: 0.14)) }

    // Card drop shadow
    public var shadowCard: Color { dark ? Color(r: 0, g: 0, b: 0, a: 0.34) : Color(r: 20, g: 20, b: 40, a: 0.06) }

    // Waiting card border
    public var waitingBorder: Color { dark ? Color(r: 255, g: 159, b: 10, a: 0.40) : Color(r: 255, g: 159, b: 10, a: 0.36) }
}

// MARK: - Status → palette

extension Theme {
    public func statusColor(_ status: String) -> SemColor {
        switch status {
        case "running": return green
        case "waiting": return amber
        case "done":    return gray
        case "dead":    return red
        default:        return gray
        }
    }
    public func statusLabel(_ status: String) -> String {
        switch status {
        case "running": return "Running"
        case "waiting": return "Waiting"
        case "done":    return "Done"
        case "dead":    return "Dead"
        default:        return "Idle"
        }
    }
    /// The palette for a derived phase-display key — the one place `phaseDisplay → color` lives, so the
    /// board cell / detail header / takeover chrome no longer each carry their own copy of this switch.
    public func statusColor(_ key: PhaseDisplayKey) -> SemColor {
        switch key {
        case .running:                        return green
        case .idle, .needsPermission:         return amber
        case .starting, .launching, .relaunching: return blue
        case .done:                           return gray
        case .dead:                           return red
        }
    }
    /// Typed convenience over the string form — delegates to `PhaseDisplayKey.label`, the ONE place
    /// `phaseDisplay → label` text lives (shared by the GUI, the CLI, and `DisplayState.label`).
    public func statusLabel(_ key: PhaseDisplayKey) -> String { key.label }

    /// The workflow-STAGE hue for a card's column (slice 2b): planning=purple, implementing=blue,
    /// in-review=teal. The ONE place `column → stage color` lives, shared by the L4 subtree segments and
    /// the peek-row column chips so a stage always reads the same colour wherever it appears.
    public func stageColor(_ column: Column) -> SemColor {
        switch column {
        case .plan:   return purple
        case .impl:   return blue
        case .review: return teal
        }
    }

    /// The attention chip's SOLID amber fill — the only saturated fill on a board card. Every other
    /// quiet fact is a muted tint or a soft state wash, which is what makes "scan for solid amber" a
    /// rule you can trust rather than a habit.
    public var attentionChipFill: Color { amber.dot }

    /// Text on that fill. Near-black in BOTH modes: the fill is a saturated amber either way, so the
    /// contrast comes from the ink, not from the theme.
    public var attentionChipText: Color { Color(hex: 0x1D1D1F) }

    /// The attached-agents eye tint for a liveness tier — green (active) · grey (idle/all-concluded) ·
    /// amber (a reviewer needs the human now / died). The ONE place this mapping lives, shared by the L4
    /// roll-up eye and the per-row peek eye so both read the same.
    public func eyeTint(_ liveness: BoardStore.AttachedLiveness) -> Color {
        switch liveness {
        case .running:        return green.text
        case .idle:           return text3
        case .needsAttention: return amber.text
        }
    }
}

// MARK: - Fonts

public enum F {
    public static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }
    public static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight, design: .monospaced) }
}

// MARK: - Reusable chrome

extension View {
    /// The prototype's standard surface chrome — a fill, a 0.5px hairline border, and a rounded clip,
    /// collapsed from a repeated `.background / .overlay(stroke) / .clipShape` recipe. Modifier order
    /// matches the hand-written sites exactly, so rendering is unchanged.
    public func surface(_ fill: Color, corner: CGFloat, hair: Color) -> some View {
        background(fill)
            .overlay(RoundedRectangle(cornerRadius: corner).stroke(hair, lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: corner))
    }

    /// Just the 0.5px hairline border (for surfaces that fill/clip separately).
    public func hairline(_ hair: Color, corner: CGFloat) -> some View {
        overlay(RoundedRectangle(cornerRadius: corner).stroke(hair, lineWidth: 0.5))
    }
}

// MARK: - Environment

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme(scheme: .light, accent: .blue)
}
extension EnvironmentValues {
    public var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}
