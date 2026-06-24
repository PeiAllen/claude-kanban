import SwiftUI

// MARK: - Color helpers

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
    /// rgba with 0–255 channels.
    init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.init(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: a)
    }
}

// MARK: - Accent + density preferences

enum Accent: String, CaseIterable, Identifiable {
    case blue, purple, graphite
    var id: String { rawValue }
    func color(dark: Bool) -> Color {
        switch self {
        case .blue:     return dark ? Color(hex: 0x0A84FF) : Color(hex: 0x007AFF)
        case .purple:   return dark ? Color(hex: 0xBF5AF2) : Color(hex: 0xAF52DE)
        case .graphite: return dark ? Color(hex: 0x8E8E93) : Color(hex: 0x48484A)
        }
    }
}

enum Density: String, CaseIterable, Identifiable {
    case comfortable, compact
    var id: String { rawValue }
    var cardPad: CGFloat { self == .comfortable ? 12 : 9 }
    var cardGap: CGFloat { self == .comfortable ? 10 : 7 }
    var cardTitle: CGFloat { self == .comfortable ? 13.5 : 12.5 }
}

/// A semantic color triple (dot/solid, text, tint fill).
struct SemColor {
    let dot: Color
    let text: Color
    let tint: Color
}

// MARK: - Theme tokens (resolved from colorScheme + accent)

struct Theme {
    let dark: Bool
    let accent: Color

    init(scheme: ColorScheme, accent: Accent) {
        self.dark = scheme == .dark
        self.accent = accent.color(dark: scheme == .dark)
    }

    // Core
    var winBg: Color      { dark ? Color(hex: 0x1C1C1E) : Color(hex: 0xF4F2EF) }
    var toolbar: Color    { dark ? Color(r: 28, g: 28, b: 30, a: 0.985) : Color(r: 244, g: 242, b: 239, a: 0.985) }
    var card: Color       { dark ? Color(hex: 0x2A2A2D) : Color(hex: 0xFFFFFF) }
    var cardBorder: Color { dark ? Color(r: 255, g: 255, b: 255, a: 0.08) : Color(r: 0, g: 0, b: 0, a: 0.07) }
    var text: Color       { dark ? Color(hex: 0xF5F5F7) : Color(hex: 0x1D1D1F) }
    var text2: Color      { dark ? Color(hex: 0x98989D) : Color(hex: 0x86868B) }
    var text3: Color      { dark ? Color(hex: 0x6E6E73) : Color(hex: 0xA8A8AD) }
    var hair: Color       { dark ? Color(r: 255, g: 255, b: 255, a: 0.10) : Color(r: 0, g: 0, b: 0, a: 0.09) }
    var inspector: Color  { dark ? Color(r: 24, g: 24, b: 26, a: 0.99) : Color(r: 248, g: 247, b: 245, a: 0.99) }
    var termBg: Color     { dark ? Color(hex: 0x131315) : Color(hex: 0xFBFAF8) }
    var field: Color      { dark ? Color(r: 255, g: 255, b: 255, a: 0.06) : Color(hex: 0xFFFFFF) }
    var fieldBorder: Color { dark ? Color(r: 255, g: 255, b: 255, a: 0.14) : Color(r: 0, g: 0, b: 0, a: 0.12) }
    var chip: Color       { dark ? Color(r: 255, g: 255, b: 255, a: 0.08) : Color(r: 0, g: 0, b: 0, a: 0.05) }
    var chipHover: Color  { dark ? Color(r: 255, g: 255, b: 255, a: 0.14) : Color(r: 0, g: 0, b: 0, a: 0.10) }
    var colBg: Color      { dark ? Color(r: 255, g: 255, b: 255, a: 0.028) : Color(r: 0, g: 0, b: 0, a: 0.022) }
    var scroll: Color     { dark ? Color(r: 255, g: 255, b: 255, a: 0.22) : Color(r: 0, g: 0, b: 0, a: 0.22) }
    var panelOpaque: Color { dark ? Color(hex: 0x202023) : Color(hex: 0xF6F5F3) }
    var termPrompt: Color { dark ? Color(r: 255, g: 255, b: 255, a: 0.045) : Color(r: 0, g: 0, b: 0, a: 0.028) }
    var term: Color       { dark ? Color(hex: 0xD6D6DA) : Color(hex: 0x2A2A2E) }
    var overTint: Color   { dark ? Color(r: 10, g: 132, b: 255, a: 0.12) : Color(r: 0, g: 122, b: 255, a: 0.07) }

    // Semantic palette
    var gray: SemColor   { dark ? SemColor(dot: Color(hex: 0x98989D), text: Color(hex: 0xB0B0B6), tint: Color(r: 152, g: 152, b: 157, a: 0.18))
                                : SemColor(dot: Color(hex: 0x8E8E93), text: Color(hex: 0x6E6E73), tint: Color(r: 142, g: 142, b: 147, a: 0.12)) }
    var indigo: SemColor { dark ? SemColor(dot: Color(hex: 0x7D7BFF), text: Color(hex: 0xB3B1FF), tint: Color(r: 125, g: 123, b: 255, a: 0.20))
                                : SemColor(dot: Color(hex: 0x5E5CE6), text: Color(hex: 0x4744C4), tint: Color(r: 94, g: 92, b: 230, a: 0.12)) }
    var green: SemColor  { dark ? SemColor(dot: Color(hex: 0x30D158), text: Color(hex: 0x54DE86), tint: Color(r: 48, g: 209, b: 88, a: 0.18))
                                : SemColor(dot: Color(hex: 0x34C759), text: Color(hex: 0x1E8E3E), tint: Color(r: 52, g: 199, b: 89, a: 0.14)) }
    var amber: SemColor  { dark ? SemColor(dot: Color(hex: 0xFF9F0A), text: Color(hex: 0xFFC668), tint: Color(r: 255, g: 159, b: 10, a: 0.18))
                                : SemColor(dot: Color(hex: 0xFF9F0A), text: Color(hex: 0xB25A00), tint: Color(r: 255, g: 159, b: 10, a: 0.16)) }
    var red: SemColor    { dark ? SemColor(dot: Color(hex: 0xFF453A), text: Color(hex: 0xFF8E86), tint: Color(r: 255, g: 69, b: 58, a: 0.18))
                                : SemColor(dot: Color(hex: 0xFF3B30), text: Color(hex: 0xC9302C), tint: Color(r: 255, g: 59, b: 48, a: 0.12)) }
    var blue: SemColor   { dark ? SemColor(dot: Color(hex: 0x0A84FF), text: Color(hex: 0x79B6FF), tint: Color(r: 10, g: 132, b: 255, a: 0.20))
                                : SemColor(dot: Color(hex: 0x007AFF), text: Color(hex: 0x0061CC), tint: Color(r: 0, g: 122, b: 255, a: 0.12)) }

    // Card drop shadow
    var shadowCard: Color { dark ? Color(r: 0, g: 0, b: 0, a: 0.34) : Color(r: 20, g: 20, b: 40, a: 0.06) }

    // Waiting card border
    var waitingBorder: Color { dark ? Color(r: 255, g: 159, b: 10, a: 0.40) : Color(r: 255, g: 159, b: 10, a: 0.36) }
}

// MARK: - Status → palette

extension Theme {
    func statusColor(_ status: String) -> SemColor {
        switch status {
        case "running": return green
        case "waiting": return amber
        case "done":    return gray
        case "dead":    return red
        default:        return gray
        }
    }
    func statusLabel(_ status: String) -> String {
        switch status {
        case "running": return "Running"
        case "waiting": return "Waiting"
        case "done":    return "Done"
        case "dead":    return "Dead"
        default:        return "Idle"
        }
    }
}

// MARK: - Fonts

enum F {
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight, design: .monospaced) }
}

// MARK: - Reusable chrome

extension View {
    /// The prototype's standard surface chrome — a fill, a 0.5px hairline border, and a rounded clip,
    /// collapsed from a repeated `.background / .overlay(stroke) / .clipShape` recipe. Modifier order
    /// matches the hand-written sites exactly, so rendering is unchanged.
    func surface(_ fill: Color, corner: CGFloat, hair: Color) -> some View {
        background(fill)
            .overlay(RoundedRectangle(cornerRadius: corner).stroke(hair, lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: corner))
    }

    /// Just the 0.5px hairline border (for surfaces that fill/clip separately).
    func hairline(_ hair: Color, corner: CGFloat) -> some View {
        overlay(RoundedRectangle(cornerRadius: corner).stroke(hair, lineWidth: 0.5))
    }
}

// MARK: - Environment

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme(scheme: .light, accent: .blue)
}
extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

// MARK: - Model display helpers

enum ModelDisplay {
    /// Strip a leading "claude-" for the chip label, e.g. claude-opus-4-8 → opus-4-8.
    static func short(_ model: String) -> String {
        model.hasPrefix("claude-") ? String(model.dropFirst("claude-".count)) : model
    }
    static func family(_ model: String) -> String {
        let m = model.lowercased()
        if m.contains("claude") { return "claude" }
        if m.contains("gpt") || m.contains("o1") || m.contains("o3") { return "gpt" }
        if m.contains("gemini") { return "gemini" }
        return "other"
    }
}
