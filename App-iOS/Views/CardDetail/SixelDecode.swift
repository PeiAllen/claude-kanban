import Foundation
import CoreGraphics

/// Provider-neutral inline-image support for the Agent tab's capture render (PR C2).
///
/// Codex (and any terminal agent) can paint an image into its pane as a **Sixel** DCS sequence
/// (`ESC P … q … ST`) sized to the *window*. The design (§"Codex Sixel width") wants those drawn as
/// native images at the phone's width in the structured Agent view, rather than as clipped fixed-width
/// terminal art. This file is the decode/segmentation half of that: it splits a captured pane string
/// into ordered **runs** — plain text, or a decoded inline image — and `CapturePaneText` renders each.
///
/// Detection is generic: *any* Sixel DCS in the pane text becomes an image. There is no `agent ==`
/// branch — Codex is merely the common emitter; Claude emits iTerm2/Kitty graphics that tmux can't
/// carry, so it simply produces no Sixel here and falls through to text.
///
/// ---
/// **Capture-pipeline reality (verified 2026-07-05, tmux 3.7):** `SessionManager.capture` uses
/// `tmux capture-pane -p` (and even `-pe` only re-emits SGR colour escapes). tmux consumes a Sixel DCS
/// and stores the image *out of band* (an image list attached to the screen, redrawn only to attached
/// Sixel-capable clients) — it is **never** serialised back into `capture-pane` output. So through the
/// *current* non-attaching capture path, a live Codex Sixel does not reach this code: the image cells
/// come back blank. This decoder is therefore exercised by (a) a **synthetic** Sixel-bearing capture,
/// and (b) any future capture/transcript path that *does* forward raw image bytes — which is exactly the
/// seam T3 left here. It is correct and ready the moment image bytes reach the pane text; it just isn't
/// triggered by `capture-pane -p` today. Kept as a localized, provider-neutral change per the C2 seam.

/// One ordered piece of a captured pane frame.
enum CapturePaneRun {
    /// A plain-text run — rendered as the monospaced pane text, exactly as before C2.
    case text(String)
    /// A decoded inline image (from a Sixel DCS) — rendered as a native, phone-width `Image`.
    case image(CGImage)
    /// A Sixel DCS we detected but could not decode — rendered as a small placeholder rather than
    /// dumping raw escape bytes into the text.
    case imagePlaceholder
}

/// Split a captured pane string into ordered text / inline-image runs. The overwhelmingly common case
/// (no Sixel in the pane — every Claude pane, and every Codex pane through today's `capture-pane -p`)
/// is a single O(n) scan that returns one `.text` run, so there is no decode cost on the hot path.
func captureRuns(from text: String) -> [CapturePaneRun] {
    // Fast path: no DCS introducer at all → the whole frame is one text run (byte-cheap guard).
    guard text.utf8.contains(0x1b) else { return [.text(text)] }

    let scalars = Array(text.unicodeScalars)
    var runs: [CapturePaneRun] = []
    var textStart = 0
    var i = 0
    let n = scalars.count

    func flushText(upTo end: Int) {
        guard end > textStart else { return }
        let s = String(String.UnicodeScalarView(scalars[textStart..<end]))
        if !s.isEmpty { runs.append(.text(s)) }
    }

    while i < n {
        // A Sixel DCS opens with 7-bit `ESC P` (0x1b 0x50) or 8-bit DCS (0x90), then optional
        // `P1;P2;P3` numeric params, then the `q` sixel selector.
        let isESC = scalars[i].value == 0x1b && i + 1 < n && scalars[i + 1].value == 0x50
        let is8bit = scalars[i].value == 0x90
        guard isESC || is8bit else { i += 1; continue }

        let dcsStart = i
        var j = i + (isESC ? 2 : 1)
        while j < n, (scalars[j].value >= 0x30 && scalars[j].value <= 0x39) || scalars[j].value == 0x3b {
            j += 1   // skip P1;P2;P3
        }
        guard j < n, scalars[j].value == 0x71 else {   // 'q' — not a Sixel DCS (e.g. DECRQSS/passthrough)
            i += 1
            continue
        }
        let bodyStart = j + 1

        // Find the String Terminator: 7-bit `ESC \` (0x1b 0x5c), 8-bit ST (0x9c), or BEL (0x07).
        var k = bodyStart
        var bodyEnd = -1
        var dcsEnd = -1
        while k < n {
            let v = scalars[k].value
            if v == 0x1b, k + 1 < n, scalars[k + 1].value == 0x5c { bodyEnd = k; dcsEnd = k + 2; break }
            if v == 0x9c || v == 0x07 { bodyEnd = k; dcsEnd = k + 1; break }
            k += 1
        }
        if bodyEnd == -1 { bodyEnd = n; dcsEnd = n }   // unterminated — decode what we have

        flushText(upTo: dcsStart)
        if let img = SixelDecoder.decode(scalars[bodyStart..<bodyEnd]) {
            runs.append(.image(img))
        } else {
            runs.append(.imagePlaceholder)
        }
        textStart = dcsEnd
        i = dcsEnd
    }

    flushText(upTo: n)
    if runs.isEmpty { return [.text(text)] }
    return runs
}

/// A minimal, self-contained Sixel decoder → `CGImage`. Handles the subset every real emitter uses:
/// RGB/HLS colour registers (`#`), raster attributes (`"`), run-length repeat (`!`), graphics CR (`$`)
/// and NL (`-`), and the 0x3F–0x7E sixel data band. No external dependency; runs anywhere CoreGraphics
/// is available (iOS app + macOS unit test).
enum SixelDecoder {
    /// Defensive cap on decoded dimensions (a malformed/hostile DCS can't allocate an unbounded bitmap).
    static let maxDimension = 4096

    static func decode(_ body: ArraySlice<Unicode.Scalar>) -> CGImage? {
        let s = Array(body)
        let n = s.count
        guard n > 0 else { return nil }
        let cap = SixelDecoder.maxDimension

        // The parse runs twice over the same input: pass 1 measures the (already-clamped) extent, pass 2
        // fills a *dense* `w*h*4` RGBA buffer. Two properties make this hostile-safe, honouring the
        // file-level "can't allocate an unbounded bitmap" guarantee:
        //   • every plot coordinate is bounded by `cap` (maxDimension), so a `!Pn` run-length can never
        //     spin the inner loop and never writes past the cap — even `!2000000000?` is ≤ cap iterations;
        //   • storage is a dense array sized to the actual clamped image, not a sparse dictionary keyed by
        //     `y*stride+x` — a 4096² raster is one bounded ~67 MB alloc, not tens of millions of dict keys.
        // `parse` is deterministic (palette rebuilt identically each pass), so both passes agree on colour.
        func parse(write: (_ x: Int, _ y: Int, _ rgb: (UInt8, UInt8, UInt8)) -> Void) -> (Int, Int) {
            var palette: [Int: (UInt8, UInt8, UInt8)] = [:]
            var current = 0
            var x = 0
            var band = 0          // each band is 6 pixels tall
            var maxX = -1
            var maxY = -1

            func plot(_ bits: Int, repeat count: Int) {
                let color = palette[current] ?? (255, 255, 255)
                // Clamp the repeat: a hostile `!Pn` must not iterate unbounded on the main thread.
                let reps = min(max(1, count), cap)
                var r = 0
                while r < reps {
                    if x >= cap { break }   // past the width cap → nothing left to plot in this run
                    var b = 0
                    while b < 6 {
                        if bits & (1 << b) != 0 {
                            let y = band * 6 + b
                            if y < cap {
                                write(x, y, color)
                                if x > maxX { maxX = x }
                                if y > maxY { maxY = y }
                            }
                        }
                        b += 1
                    }
                    x += 1
                    r += 1
                }
            }

            var i = 0
            func readInt() -> Int {
                var v = 0
                var any = false
                while i < n, s[i].value >= 0x30, s[i].value <= 0x39 {
                    // Saturate at `cap` so a giant digit string can't trap on Int overflow; callers
                    // (run-length count, dimensions) only care about values up to `cap`, and the colour
                    // channels (≤ 360) are well under it.
                    if v < cap { v = v * 10 + Int(s[i].value - 0x30) }
                    any = true; i += 1
                }
                return any ? v : 0
            }

            while i < n {
                let c = s[i].value
                switch c {
                case 0x23:   // '#' colour register: #Pc  or  #Pc;Pu;Px;Py;Pz
                    i += 1
                    let pc = readInt()
                    if i < n, s[i].value == 0x3b {   // ';' → full colour definition
                        i += 1; let pu = readInt()
                        if i < n, s[i].value == 0x3b { i += 1 }; let px = readInt()
                        if i < n, s[i].value == 0x3b { i += 1 }; let py = readInt()
                        if i < n, s[i].value == 0x3b { i += 1 }; let pz = readInt()
                        palette[pc] = SixelDecoder.color(system: pu, px, py, pz)
                    }
                    current = pc
                case 0x21:   // '!' run-length: !Pn <data>
                    i += 1
                    let count = readInt()
                    if i < n {
                        let d = s[i].value
                        if d >= 0x3f, d <= 0x7e { plot(Int(d) - 0x3f, repeat: count) }
                        i += 1
                    }
                case 0x22:   // '"' raster attributes: "Pan;Pad;Ph;Pv — consume, we grow dynamically
                    i += 1
                    _ = readInt()
                    while i < n, s[i].value == 0x3b { i += 1; _ = readInt() }
                case 0x24:   // '$' graphics carriage return
                    x = 0; i += 1
                case 0x2d:   // '-' graphics newline
                    x = 0; band += 1; i += 1
                case 0x3f...0x7e:   // sixel data band
                    plot(Int(c) - 0x3f, repeat: 1); i += 1
                default:     // CR/LF/whitespace/unknown → ignore
                    i += 1
                }
            }
            return (maxX, maxY)
        }

        // Pass 1: measure. Coordinates are clamped to < cap, so w,h are guaranteed ≤ cap.
        let (maxX, maxY) = parse { _, _, _ in }
        guard maxX >= 0, maxY >= 0 else { return nil }
        let w = maxX + 1, h = maxY + 1

        // Pass 2: fill a dense RGBA buffer sized to the clamped image (transparent where unset).
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        _ = parse { px, y, rgb in
            let o = (y * w + px) * 4
            buf[o] = rgb.0; buf[o + 1] = rgb.1; buf[o + 2] = rgb.2; buf[o + 3] = 255
        }

        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        return buf.withUnsafeMutableBytes { raw -> CGImage? in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: cs, bitmapInfo: info) else { return nil }
            return ctx.makeImage()
        }
    }

    /// Sixel colour registers: system 2 = RGB (each 0–100%), system 1 = HLS (H 0–360°, L/S 0–100%).
    /// Anything else is treated as RGB. Returns 8-bit RGB.
    static func color(system: Int, _ a: Int, _ b: Int, _ c: Int) -> (UInt8, UInt8, UInt8) {
        func pct(_ v: Int) -> UInt8 { UInt8(max(0, min(255, (v * 255 + 50) / 100))) }
        if system == 1 {
            // DEC HLS → RGB. DEC hue 0° points at blue; rotate by +240° to map onto standard HSL.
            let h = Double((a % 360 + 360) % 360)
            let l = Double(max(0, min(100, b))) / 100.0
            let sat = Double(max(0, min(100, c))) / 100.0
            let chroma = (1 - abs(2 * l - 1)) * sat
            let hp = ((h + 240).truncatingRemainder(dividingBy: 360)) / 60.0
            let xk = chroma * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
            var (r, g, bb) = (0.0, 0.0, 0.0)
            switch hp {
            case 0..<1: (r, g, bb) = (chroma, xk, 0)
            case 1..<2: (r, g, bb) = (xk, chroma, 0)
            case 2..<3: (r, g, bb) = (0, chroma, xk)
            case 3..<4: (r, g, bb) = (0, xk, chroma)
            case 4..<5: (r, g, bb) = (xk, 0, chroma)
            default:    (r, g, bb) = (chroma, 0, xk)
            }
            let m = l - chroma / 2
            func b8(_ v: Double) -> UInt8 { UInt8(max(0, min(255, Int((v + m) * 255 + 0.5)))) }
            return (b8(r), b8(g), b8(bb))
        }
        return (pct(a), pct(b), pct(c))
    }
}
