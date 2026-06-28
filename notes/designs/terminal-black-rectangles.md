# Terminal "black rectangle" artifact — root cause & fix

## Symptom
The embedded SwiftTerm terminal showed solid **black rectangles**. Final, precise repro: they appear
when **hovering over Claude Code's expandable items** ("Ran 1 shell command", etc.) — the hover/expand
**preview box** rendered as a solid black rectangle (with its dark text invisible) in a light theme.

## Status: FIXED (one line, no fork)
`App/Views/AgentTerminalView.swift`, in `makeNSView`:
```swift
term.getTerminal().ansi256PaletteStrategy = .xterm
```

## Root cause — SwiftTerm's theme-aware 256-colour palette (NOT bce)
SwiftTerm **v1.13.0** added a "base16 LAB" 256-colour palette strategy (upstream commit `36642aa`) and
made it the **default** (`TerminalOptions.ansi256PaletteStrategy = .base16Lab`). Instead of the fixed
historical xterm cube, it re-derives the entire 16–255 palette by LAB-interpolating between the active
theme's base-16 colours, background, and foreground (`Colors.swift` `generateBase16LabPalette`).

That remaps fixed xterm indices to theme-relative colours. Walk index **231** (cube `r=g=b=5`, normally
pure white `#ffffff`) through the interpolation — every `t = 5/5 = 1.0`, so each `lerp` returns its
second endpoint and it collapses to `c6 = c5 = c3 = lerp(1.0, base8Lab[6], fgLab) = fgLab` = **the theme
foreground**. In a light theme the foreground is near-black → **index 231 renders black**.

Claude Code draws its hover/expand preview box with background `48;5;231` (expecting white) and default
foreground. With base16Lab + a light theme that becomes black bg + black fg → a solid black rectangle.

### How it was proven
- `tmux -L orchestra capture-pane -p -e` of the preview region showed background `48;5;231` (white) +
  default fg — i.e. tmux's grid is *correct/white*.
- A simultaneous in-app screenshot (SIGUSR1 hook) showed that same region as solid **black**.
- → tmux grid white, SwiftTerm renders black ⇒ a SwiftTerm-side palette mapping bug, localized to the
  base16Lab cube remap of index 231.

## Why earlier theories/fixes were wrong (all reverted)
The first investigation chased **background-colour-erase (bce)**: `eraseAttr()` (`Terminal.swift:5388`)
fills scrolled/erased cells with `curAttr.bg`. That theory predicted the wrong category. The two fixes
it motivated did nothing and were reverted:
- `set -ga terminal-overrides ",*:ut@"` (embedded.conf) — inert; SwiftTerm ignores terminfo.
- `term.disableFullRedrawOnAnyChanges = false` — wrong category (draw vs palette).

The decisive break was the **precise repro** (hover preview, not scroll) + capturing the real artifact's
colours, which pointed at the palette, not the erase path.

## Trade-off of the fix
`.xterm` gives apps the standard fixed 256-colour palette, so indexed colours mean what TUIs expect
(231 = white). The only thing given up is base16Lab's theme-coherent colour blending — which was
actively breaking apps here, so this is the correct call for a terminal that hosts arbitrary TUIs.

## Related terminal work from this effort
Lag and blur/cursor-offset/selection were the experimental **Metal renderer** — removed entirely, back
to stock CoreText. Also kept: SIGUSR1 in-app screenshot hook and stable "Orchestra Dev" code-signing
(so TCC grants survive rebuilds).
