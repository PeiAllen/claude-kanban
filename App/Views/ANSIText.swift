import SwiftUI
import OrchestraCore

/// Renders ANSI-colored terminal text (git / difftastic diff output) as an `AttributedString`. A
/// minimal SGR parser — foreground color (basic 30-37 / 90-97, 256-color, truecolor) + bold + reset.
/// Background and other attributes are ignored; the Diff view only needs readable add/remove/hunk
/// coloring. Both git's colored diff and difft's inline output are SGR, so one parser handles both.
enum ANSIText {
    private struct Style { var color: Color?; var bold: Bool }

    static func strip(_ raw: String) -> String {
        ANSIEscape.strip(raw)
    }

    /// `raw` may contain SGR escapes; `base` is the default foreground; `size` the monospaced point size.
    static func attributed(_ raw: String, base: Color, size: CGFloat) -> AttributedString {
        var out = AttributedString("")
        var style = Style(color: nil, bold: false)
        let chars = Array(raw)
        var i = 0, run = ""

        func flush() {
            guard !run.isEmpty else { return }
            var piece = AttributedString(run)
            piece.foregroundColor = style.color ?? base
            piece.font = .system(size: size, weight: style.bold ? .bold : .regular, design: .monospaced)
            out += piece
            run = ""
        }

        while i < chars.count {
            let c = chars[i]
            if c == "\u{1B}", i + 1 < chars.count, chars[i + 1] == "[" {
                flush()
                var j = i + 2, params = ""
                while j < chars.count, !("@"..."~").contains(chars[j]) { params.append(chars[j]); j += 1 }
                let final = j < chars.count ? chars[j] : "m"
                if final == "m" { apply(params, to: &style) }
                i = j + 1
            } else {
                run.append(c)
                i += 1
            }
        }
        flush()
        return out
    }

    private static func apply(_ params: String, to style: inout Style) {
        let codes = params.split(separator: ";").map { Int($0) ?? 0 }
        if codes.isEmpty { style = Style(color: nil, bold: false); return }   // ESC[m == reset
        var k = 0
        while k < codes.count {
            switch codes[k] {
            case 0:       style = Style(color: nil, bold: false)
            case 1:       style.bold = true
            case 22:      style.bold = false
            case 39:      style.color = nil
            case 30...37: style.color = basic(codes[k] - 30, bright: false)
            case 90...97: style.color = basic(codes[k] - 90, bright: true)
            case 38:
                if k + 2 < codes.count, codes[k + 1] == 5 {
                    style.color = xterm256(codes[k + 2]); k += 2
                } else if k + 4 < codes.count, codes[k + 1] == 2 {
                    style.color = Color(.sRGB, red: Double(codes[k + 2]) / 255,
                                        green: Double(codes[k + 3]) / 255, blue: Double(codes[k + 4]) / 255)
                    k += 4
                }
            default:      break   // background (40-49) / other — ignored
            }
            k += 1
        }
    }

    // 0K 1R 2G 3Y 4B 5M 6C 7W — tuned for readability on the diff canvas (not raw terminal values).
    // The `c` helper types each literal as UInt32 up front so the array doesn't stall the type-checker.
    private static func c(_ h: UInt32) -> Color { Color(hex: h) }
    private static let basicNormal: [Color] = [c(0x6E6E73), c(0xCC3333), c(0x2E8B2E), c(0xB58900),
                                               c(0x2277CC), c(0xAA44AA), c(0x1E9E9E), c(0xB0B0B6)]
    private static let basicBright: [Color] = [c(0x8E8E93), c(0xFF6E67), c(0x54DE86), c(0xE6C200),
                                               c(0x62A9FF), c(0xD08BFF), c(0x5FD7D7), c(0xF5F5F7)]
    private static func basic(_ n: Int, bright: Bool) -> Color {
        (bright ? basicBright : basicNormal)[max(0, min(7, n))]
    }

    private static func xterm256(_ n: Int) -> Color {
        if n < 16 { return basic(n % 8, bright: n >= 8) }
        if n >= 232 { let v = Double(8 + (n - 232) * 10) / 255; return Color(.sRGB, red: v, green: v, blue: v) }
        let c = n - 16, r = (c / 36) % 6, g = (c / 6) % 6, b = c % 6
        func comp(_ x: Int) -> Double { x == 0 ? 0 : Double(55 + x * 40) / 255 }
        return Color(.sRGB, red: comp(r), green: comp(g), blue: comp(b))
    }
}
