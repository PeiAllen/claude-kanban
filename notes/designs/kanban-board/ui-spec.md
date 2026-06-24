# Orchestra — Kanban Board UI Spec (SwiftUI)

Single source of visual truth for faithfully reproducing the **Orchestra** agent-orchestration
Kanban board as a native-macOS-style SwiftUI app. All values are extracted verbatim from the
`Orchestra.dc.html` prototype (inline styles + CSS custom properties with light/dark token sets).

> **Source-fidelity notes — read first.** The original task brief mentioned a few components that
> are **not present** in this prototype build. Documented here for honesty so the SwiftUI engineer
> isn't hunting for them:
> - There is **no 4-state status system**. The prototype uses a **3-state** model: `running`,
>   `waiting`, `done`. There is **no `dead` status** and **no Recovery / "Session lost" panel**
>   ("Start new session / Try resume" do not exist). A proposed `dead` token is included in the
>   tokens table for forward-compat, but it is **not used** anywhere in this build.
> - There is **no dedicated Settings panel/sheet**. Settings exist only as Design-Component
>   `data-props` (host-level controls): `accent` (Blue/Purple/Graphite), `density`
>   (Comfortable/Compact), `autonomy` (bool). These map to runtime token overrides (see §3.6).
> - The toolbar "Done" button opens an **Archive popover** (done/merged cards). "Done" and
>   "Archive" are the same concept here.
> - The inspector has **no context-window gauge with a numeric label shown in chrome**; instead a
>   2px Safari-style progress bar sits at the very top of the terminal chrome (color shifts
>   green→amber→red). A `ctxLabel` percentage is computed but not rendered as visible text.

---

## 1. Design Tokens

The root element sets CSS custom properties at runtime via `tokens()`. Two complete sets (light &
dark) plus accent-dependent and density-dependent derived tokens. Map each to a `Theme` Swift
`Color`/value token.

### 1.1 Core theme tokens (`tokens()`)

| CSS var | Purpose | Light | Dark | Swift token |
|---|---|---|---|---|
| `--winBg` | Window / app background | `#F4F2EF` | `#1C1C1E` | `Theme.winBg` |
| `--toolbar` | Toolbar background (translucent) | `rgba(244,242,239,.985)` | `rgba(28,28,30,.985)` | `Theme.toolbar` |
| `--card` | Card / field surface | `#FFFFFF` | `#2A2A2D` | `Theme.card` |
| `--cardBorder` | Card hairline border | `rgba(0,0,0,.07)` | `rgba(255,255,255,.08)` | `Theme.cardBorder` |
| `--text` | Primary text | `#1D1D1F` | `#F5F5F7` | `Theme.text` |
| `--text2` | Secondary text | `#86868B` | `#98989D` | `Theme.text2` |
| `--text3` | Tertiary text | `#A8A8AD` | `#6E6E73` | `Theme.text3` |
| `--hair` | Hairline / divider (0.5px) | `rgba(0,0,0,.09)` | `rgba(255,255,255,.10)` | `Theme.hair` |
| `--inspector` | Inspector panel background | `rgba(248,247,245,.99)` | `rgba(24,24,26,.99)` | `Theme.inspector` |
| `--termBg` | Terminal / shell background | `#FBFAF8` | `#131315` | `Theme.termBg` |
| `--field` | Input field background | `#FFFFFF` | `rgba(255,255,255,.06)` | `Theme.field` |
| `--fieldBorder` | Input field border | `rgba(0,0,0,.12)` | `rgba(255,255,255,.14)` | `Theme.fieldBorder` |
| `--chip` | Chip / subtle button bg | `rgba(0,0,0,.05)` | `rgba(255,255,255,.08)` | `Theme.chip` |
| `--chipHover` | Chip hover bg | `rgba(0,0,0,.10)` | `rgba(255,255,255,.14)` | `Theme.chipHover` |
| `--colBg` | Column background | `rgba(0,0,0,.022)` | `rgba(255,255,255,.028)` | `Theme.colBg` |
| `--shadowCard` | Default card drop shadow | `0 1px 2px rgba(20,20,40,.06)` | `0 1px 2px rgba(0,0,0,.34)` | `Theme.shadowCard` |
| `--scroll` | Scrollbar thumb | `rgba(0,0,0,.22)` | `rgba(255,255,255,.22)` | `Theme.scroll` |
| `--wall1` | (decor gradient stop, unused in board) | `#E5E0F0` | `#232234` | `Theme.wall1` |
| `--wall2` | (decor gradient stop) | `#ECEAF2` | `#1A1A21` | `Theme.wall2` |
| `--wall3` | (decor gradient stop) | `#F2ECE6` | `#201A22` | `Theme.wall3` |

### 1.2 Derived / accent / density tokens

| CSS var | Purpose | Light | Dark | Swift token |
|---|---|---|---|---|
| `--accent` | Brand accent (see §1.3) | `#007AFF` (Blue default) | `#0A84FF` (Blue default) | `Theme.accent` |
| `--panelOpaque` | Opaque popover/toast surface | `#F6F5F3` | `#202023` | `Theme.panelOpaque` |
| `--termPrompt` | Terminal prompt strip tint | `rgba(0,0,0,.028)` | `rgba(255,255,255,.045)` | `Theme.termPrompt` |
| `--cardPad` | Card padding | `12px` (Comfortable) / `9px` (Compact) | same | `Theme.cardPad` |
| `--cardGap` | Gap between cards | `10px` / `7px` (Compact) | same | `Theme.cardGap` |
| `--cardTitle` | Card title font size | `13.5px` / `12.5px` (Compact) | same | `Theme.cardTitleSize` |
| `--panelW` | Inspector width (persisted) | `392px` default (320–820 clamp) | same | `Theme.panelW` |

### 1.3 Accent options (`accentHex()`)

| Accent | Light | Dark |
|---|---|---|
| Blue (default) | `#007AFF` | `#0A84FF` |
| Purple | `#AF52DE` | `#BF5AF2` |
| Graphite | `#48484A` | `#8E8E93` |

### 1.4 Semantic palette (`pal()`) — status & syntax colors

Each color has a base **dot/solid**, a **text** variant, and a **tint** (translucent fill). Used by
status pills, the terminal/CLI syntax, and meta labels.

| Role | Light dot | Light text | Light tint | Dark dot | Dark text | Dark tint | Swift token |
|---|---|---|---|---|---|---|---|
| gray (done/idle) | `#8E8E93` | `#6E6E73` | `rgba(142,142,147,.12)` | `#98989D` | `#B0B0B6` | `rgba(152,152,157,.18)` | `Theme.statusGray*` |
| indigo (plan layer) | `#5E5CE6` | `#4744C4` | `rgba(94,92,230,.12)` | `#7D7BFF` | `#B3B1FF` | `rgba(125,123,255,.20)` | `Theme.indigo*` |
| green (running/ok) | `#34C759` | `#1E8E3E` | `rgba(52,199,89,.14)` | `#30D158` | `#54DE86` | `rgba(48,209,88,.18)` | `Theme.green*` |
| amber (waiting) | `#FF9F0A` | `#B25A00` | `rgba(255,159,10,.16)` | `#FF9F0A` | `#FFC668` | `rgba(255,159,10,.18)` | `Theme.amber*` |
| red (error/del) | `#FF3B30` | `#C9302C` | `rgba(255,59,48,.12)` | `#FF453A` | `#FF8E86` | `rgba(255,69,58,.18)` | `Theme.red*` |
| purple | `#AF52DE` | `#8E3CC4` | `rgba(175,82,222,.13)` | `#BF5AF2` | `#D8A6F4` | `rgba(191,90,242,.20)` | `Theme.purple*` |
| blue (user line/link) | `#007AFF` | `#0061CC` | `rgba(0,122,255,.12)` | `#0A84FF` | `#79B6FF` | `rgba(10,132,255,.20)` | `Theme.blue*` |
| text2 (alias) | `#86868B` | — | — | `#98989D` | — | — | — |
| term (terminal body fg) | `#2A2A2E` | — | — | `#D6D6DA` | — | — | `Theme.term` |

### 1.5 Status → palette mapping (`statusMeta()`)

| Status | Label | Dot | Pill text | Pill tint (bg) |
|---|---|---|---|---|
| `running` | "Running" | green dot | greenText | greenTint |
| `waiting` | "Waiting" | amber dot | amberText | amberTint |
| `done` | "Done" | gray dot | grayText | grayTint |
| (default/idle) | "Idle" | gray dot | grayText | grayTint |
| `dead` *(not in build — proposed)* | "Dead" | red dot | redText | redTint |

### 1.6 macOS traffic-light & fixed colors

| Element | Color |
|---|---|
| Close (red) | `#FF5F57` |
| Minimize (yellow) | `#FEBC2E` |
| Zoom (green) | `#28C840` |
| Traffic-light inner ring | `inset 0 0 0 0.5px rgba(0,0,0,.14)` |
| MCP pulse dot / activity dot | `#34C759` |
| Toast "archived/merged" accent | `#34C759` |
| Feed "you" avatar bg | `#8E8E93` |
| Feed "spawned" avatar bg | `#0A84FF` |

### 1.7 Model chip colors (`modelChip()`)

| Family | Light bg | Light fg | Light border | Light dot | Dark bg | Dark fg | Dark border | Dark dot |
|---|---|---|---|---|---|---|---|---|
| Claude | `rgba(191,88,54,.09)` | `#923A1C` | `rgba(191,88,54,.20)` | `#BF5836` | `rgba(191,88,54,.16)` | `#E8896A` | `rgba(191,88,54,.28)` | `#E8896A` |
| GPT / o1 / o3 | `rgba(16,163,127,.09)` | `#0A7560` | `rgba(16,163,127,.20)` | `#10A37F` | `rgba(16,163,127,.15)` | `#3EC9A5` | `rgba(16,163,127,.28)` | `#3EC9A5` |
| Gemini | `rgba(59,115,219,.09)` | `#1A56C4` | `rgba(59,115,219,.20)` | `#3B73DB` | `rgba(59,115,219,.16)` | `#79B0FF` | `rgba(59,115,219,.28)` | `#79B0FF` |
| Other/default | `rgba(142,142,147,.09)` | `#6E6E73` | `transparent` | `#8E8E93` | `rgba(142,142,147,.15)` | `#98989D` | `transparent` | `#98989D` |

### 1.8 Agent avatar solids (spawn-model palette)

| Model | Avatar bg | Avatar fg |
|---|---|---|
| `claude-opus-4-5` | `#BF5836` | `#fff` |
| `gpt-4o` | `#0E8C6D` | `#fff` |
| `claude-sonnet-4-5` | `#A8741C` | `#fff` |
| `gemini-2.5-pro` | `#3B73DB` | `#fff` |

---

## 2. Typography

**Primary UI font stack** (map to system font / `.system` design):
`-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'SF Pro Display', system-ui, sans-serif`

**Monospace stack** (repo/branch, terminal, paths, CLI):
`ui-monospace, 'SF Mono', Menlo, monospace` → SwiftUI `.system(.body, design: .monospaced)` or
`Font.custom("SF Mono", …)`.

Font smoothing: `-webkit-font-smoothing: antialiased`, `text-rendering: optimizeLegibility`.

| Usage | Size | Weight | Letter-spacing | Line-height | Family |
|---|---|---|---|---|---|
| Toolbar app title ("Orchestra") | 13.5px | 600 | -0.01em | — | UI |
| Toolbar subtitle ("· Personal") | 12.5px | 400 | — | — | UI |
| App glyph badge (◧) | 12px | 800 | — | — | UI |
| MCP chip text | 11.5px | 500 | — | — | UI |
| Done/Activity button label | 12px | 500 | — | — | UI |
| New-agent button label | 12.5px | 600 | — | — | UI |
| New-agent "+" glyph | 15px | 500 | — | line-height:1 | UI |
| Light/Dark toggle glyph (☀ ☾) | 12px | — | — | — | UI |
| Column header name | 12.5px | 600 | -0.005em | — | UI |
| Column count badge | 10.5px | 600 | — | — | UI |
| Card status pill label | 10.5px | 600 | 0.005em | — | UI |
| Card title | **13.5px** (Compact 12.5px) | 600 | -0.01em | 1.32 | UI |
| Card description | 11.5px | 400 | — | 1.48 | UI |
| Card footer repo·branch | 10.5px | 400 | — | — | **mono** |
| Card meta label (L1/file/diff) | 10.5px | 500–600 | — | — | **mono** |
| Inspector "View changes"/"Archive" | 12px | 600 / 500 | — | — | UI |
| Inspector model chip | 9.5px | 600 | — | — | **mono** |
| Inspector repo chip | 10px | 600 | — | — | **mono** |
| Inspector branch | 11px | 400 | — | — | **mono** |
| Inspector status pill | 10.5px | 600 | — | — | UI |
| Breadcrumb link / path parts | 10px | 400 | — | — | **mono** |
| Breadcrumb separator (›) | 8.5px | 400 | — | line-height:1 | UI |
| Terminal body lines | 12px | 400 (varies) | — | 1.65 | **mono** |
| Terminal prompt glyph (›) | 12px | 400 | — | 1.65 | **mono** |
| Shell body lines | 12px | 400 | — | 1.6 | **mono** |
| Shell prompt (➜ pwd $) | 12px | 400/600 | — | — | **mono** |
| Shell tab label | 10px | 500 | — | — | **mono** |
| Sheet title ("Spawn a new agent") | 15px | 700 | -0.01em | — | UI |
| Sheet subtitle | 12px | 400 | — | — | UI |
| Sheet field label | 11px | 600 | — | — | UI |
| Sheet Task input | 13px | 400 | — | — | UI |
| Sheet Description textarea | 12.5px | 400 | — | 1.5 | UI |
| Sheet Repository/Branch input | 12.5px | 400 | — | — | **mono** |
| Sheet model button | 11.5px | 600 | — | — | **mono** |
| Sheet Worktree readonly | 11.5px | 400 | — | — | **mono** |
| Sheet Start-in button | 12px | 600 | — | — | UI |
| "CLI equivalent" caption | 9.5px | 600 | 0.07em | — | UI (uppercase) |
| CLI-equivalent command | 10.5px | 400 | — | 1.5 | **mono** |
| Popover section header ("Done") | 11px | 600 | 0.08em | — | UI (uppercase) |
| Popover meta count | 11px | 400 | — | — | UI |
| Archive card title | 12.5px | 600 | — | 1.35 | UI |
| Archive card repo·age | 10.5px | 400 | — | — | **mono** |
| Archive action buttons | 10px | 400/500 | — | — | **mono** |
| Activity feed text | 12px | 400 | — | 1.4 | UI |
| Activity feed meta | 10.5px | 400 | — | — | **mono** |
| Activity tab button (Live/CLI) | 11px | 500 | — | — | UI |
| Activity CLI reference lines | 11px | 400 | — | 1.7 | **mono** |
| Activity CLI section header | 9.5px | 600 | 0.08em | — | UI (uppercase) |
| Toast title | 12.5px | 600 | — | 1.35 | UI |
| Toast sub | 11px | 400 | — | — | **mono** |
| Empty-column placeholder | 11.5px | 400 | — | — | UI |
| Agent avatar mono glyph | 9px (card 9px / archive 9px) | 800 | — | — | **mono** |
| Zed "Z" glyph | 9px (inspector) / 6.5px (archive) | 800 | — | — | **mono** |

---

## 3. Layout & Dimensions

### 3.1 Window structure

```
┌─────────────────────────────────────────────────────────┐
│ TOOLBAR  height 53px (flex:none)                          │
├──────────────────────────────────┬──────────────────────┤
│ BOARD  flex:1, overflow-x:auto    │ INSPECTOR             │
│  3 columns, gap 14px, padding 16px│  width var(--panelW)  │
│                                   │  392px default        │
│                                   │  (320–820 resizable)  │
└──────────────────────────────────┴──────────────────────┘
```

Outer container: `height:100vh; overflow:hidden; display:flex; flex-direction:column`.
Content row: `flex:1; min-height:0; display:flex` (board + optional inspector side-by-side).

### 3.2 Toolbar

| Property | Value |
|---|---|
| Height | 53px (flex:none) |
| Padding | `0 14px` |
| Gap between groups | 10px |
| Bottom border | 0.5px solid `--hair` |
| z-index | 30 |
| Traffic-light dots | 12×12px circles, gap 8px, group margin-right 4px |
| App glyph badge | 21×21px, radius 6px, accent bg, white ◧, shadow `0 1px 2px rgba(0,0,0,.18)` |
| Logo group gap | 9px |
| MCP chip | padding `5px 11px`, radius 999px, gap 7px; pulse dot 7×7px |
| Done/Activity buttons | height 30px, padding `0 11px`, radius 7px, chip bg, 0.5px hair border |
| Done count badge | min-width 16px, height 16px, radius 8px, bg `--text2`, fg `--winBg`, 9.5px/700 |
| Light/Dark segmented | container padding 2px, radius 8px, gap 2px; each button 28×24px, radius 6px |
| New-agent button | height 30px, padding `0 13px`, radius 7px, accent bg, white text, gap 6px; shadow `0 1px 2px rgba(0,0,0,.16), inset 0 1px 0 rgba(255,255,255,.22)` |

### 3.3 Board & columns

| Property | Value |
|---|---|
| Board padding | 16px |
| Column gap | 14px |
| Board overflow | x:auto, y:hidden |
| Column flex | `1 1 0`, **min-width 210px** |
| Column radius | 11px |
| Column border | 1px solid (transparent default, accent when drag-over) |
| Column bg | `--colBg` (or drag-over tint, see §4.2) |
| Column header padding | `13px 13px 9px`, gap 8px |
| Column count badge | min-width 18px, height 18px, radius 999px, padding `0 5px`, chip bg |
| Column "+" add button | 22×22px, radius 6px, transparent→chip hover, 15px glyph |
| Card list padding | `2px 10px 12px` |
| Card list gap | `var(--cardGap)` = 10px (Compact 7px) |
| Empty placeholder | 1px dashed `--hair`, radius 9px, padding 16px, centered |

### 3.4 Card

| Property | Value |
|---|---|
| Radius | 10px |
| Padding | `var(--cardPad)` = 12px (Compact 9px) |
| Border | 1px solid (see §4.3 for state colors) |
| Background | `--card` |
| Cursor | grab |
| Default shadow | `var(--shadowCard)` |
| Selected shadow/ring | `0 0 0 2px <accent>, 0 8px 20px rgba(0,0,0,.12)` |
| Drag opacity | 0.4 while dragging, else 1 |
| Hover transform | `translateY(-1px)` |
| Transition | `box-shadow .15s, transform .12s, opacity .12s` |
| Running shimmer bar | absolute top, full width, height **2px**, gradient (see §5) |
| Status pill | padding `3px 8px 3px 7px`, radius 999px, gap 6px; dot 6×6px |
| Title margin | `9px 0 5px` |
| Footer margin-top | 11px; repo·branch left (ellipsis), meta right (max-width 148px) |
| Meta diff chip gap | 3px |

### 3.5 Inspector

| Property | Value |
|---|---|
| Width | `var(--panelW)` default **392px**, clamp **320–820px**, persisted in localStorage (`orch_panelW`) |
| Left border | 0.5px solid `--hair` |
| Background | `--inspector` |
| Resize handle | absolute, left:-4px, width 10px, full height, cursor col-resize, z-index 8; hover shows accent gradient line |
| Header bar | padding `10px 12px`, gap 6px |
| "View changes" button | height 29px, padding `0 11px`, radius 8px, card bg, 0.5px hair, 6px gap; Zed badge 16×16px radius 4px conic-gradient |
| "Archive" button | height 29px, padding `0 10px`, radius 8px, card bg, text2 |
| Close (✕) button | 29×29px, radius 7px, chip bg |
| Agent chrome | margin `0 16px 0`, radius 10px (or `10px 10px 0 0` when shell open), 0.5px hair border, termBg |
| Context bar (top of chrome) | height 2px, fill width = `ctxPct%`, opacity .7, transition width .8s ease |
| Terminal header | padding `8px 12px`, gap 7px, bottom 0.5px hair; model chip h18 / radius 5px, repo chip radius 5px padding `2px 6px` max-width 140px |
| Breadcrumb strip | height 25px, chip bg, bottom 0.5px hair; copy buttons padding `0 10px`, right-divider 0.5px |
| Terminal body | padding `11px 13px 9px`, mono 12px, line-height 1.65, scrollable |
| Terminal prompt row | padding `1px 13px 10px`; › glyph margin-right 6px |
| Bottom strip (tab ribbon / new-terminal) | height 26px, top 0.5px hair, chip bg, radius `0 0 10px 10px` |
| Shell tab | height 20px, radius 4px; close × 14px wide; new-tab + 18×18px radius 3px |
| Shell panel | height `shellPanelHeight` default **220px**, clamp **80–500px**; margin `0 16px 16px`, radius `0 0 10px 10px`, 0.5px hair (no top border) |
| Shell prompt | padding `1px 13px 9px`; ➜ accent, pwd max-width 160px ellipsis |

### 3.6 Density (Compact vs Comfortable)

Density only changes three tokens: `--cardPad` (12→9px), `--cardGap` (10→7px), `--cardTitle`
(13.5→12.5px). Everything else is unchanged.

### 3.7 Sheet (Spawn a new agent)

| Property | Value |
|---|---|
| Backdrop | `position:absolute; inset:0; background:rgba(0,0,0,.28); z-index:50` |
| Sheet | top 62px, horizontally centered (`left:50%; margin-left:-235px`), **width 470px**, winBg, 0.5px hair, radius 13px |
| Shadow | `0 28px 70px rgba(20,18,40,.4)` |
| Animation | `ccSheetIn .24s ease-out` |
| Header padding | `17px 19px 6px` |
| Body padding | `12px 19px 4px`, vertical gap 12px between groups |
| Field label margin-bottom | 5px |
| Task input | height 34px, radius 8px, padding `0 11px`, 0.5px fieldBorder, field bg; focus ring `0 0 0 2px accent` |
| Description textarea | min-height 54px, radius 8px, padding `9px 11px` |
| Repository/Branch row | gap 11px, two flex:1 inputs, mono |
| Model segmented | container padding 2px radius 8px gap 2px; buttons height 28px padding `0 12px` radius 6px mono |
| Worktree readonly | height 34px, chip bg, 0.5px hair, radius 8px, mono 11.5px |
| Start-in segmented | padding 2px radius 8px; buttons height 28px padding `0 14px` radius 6px |
| CLI-equivalent box | margin `4px 19px 0`, padding `8px 11px`, chip bg, radius 8px, 0.5px hair |
| Footer | padding `15px 19px 17px`, margin-top 6px, right-aligned, gap 9px |
| Cancel button | height 32px, padding `0 15px`, radius 8px, card bg, 0.5px hair |
| Spawn button | height 32px, padding `0 16px`, radius 8px, accent bg, white |

### 3.8 Popovers (Archive / Activity)

| Property | Archive | Activity |
|---|---|---|
| Position | top 48px, right 268px | top 48px, right 120px |
| Width | 460px | 312px |
| Background | `--panelOpaque` | `--panelOpaque` |
| Border / radius | 0.5px hair / 13px | 0.5px hair / 13px |
| Shadow | `0 16px 48px rgba(20,18,40,.26)` | same |
| Animation | `ccPopIn .16s ease-out` | `ccPopIn .16s ease-out` |
| Scrim | `position:fixed; inset:0; z-index:40` (click to close) | same |
| z-index | 41 | 41 |
| Body | max-height 380px scroll, padding `0 8px 10px` | tabs + max-height 290px scroll |

### 3.9 Toasts

Bottom-right stack: `position:absolute; bottom:16px; right:16px; z-index:60; gap:9px`.
Each toast: min-width 236px, max-width 320px, padding `11px 13px`, panelOpaque bg, 0.5px hair,
radius 11px, shadow `0 14px 40px rgba(20,18,40,.26)`, animation `ccToastIn .22s ease-out`,
8×8px color dot. Auto-dismiss after **4200ms**.

### 3.10 Hairlines & shadows summary

- **Hairlines:** 0.5px solid `--hair` everywhere (borders, dividers). On macOS render as 0.5pt or a
  1px @1x line; SwiftUI `Divider`/overlay stroke with `lineWidth: 0.5`.
- **Column & card borders:** 1px solid.
- **Shadows:** card `var(--shadowCard)`; selected card adds 2px accent ring + `0 8px 20px
  rgba(0,0,0,.12)`; popovers `0 16px 48px rgba(20,18,40,.26)`; sheet `0 28px 70px rgba(20,18,40,.4)`;
  toasts `0 14px 40px rgba(20,18,40,.26)`.

---

## 4. Component-by-Component Breakdown

### 4.1 Toolbar (left → right)

1. **Traffic lights** — 3 × 12px circles: `#FF5F57`, `#FEBC2E`, `#28C840`, each with
   `inset 0 0 0 0.5px rgba(0,0,0,.14)` ring. (Decorative — native macOS provides these.)
2. **App identity** — 21px accent rounded-square badge with `◧` glyph (white, 12px/800); title
   "Orchestra" (13.5px/600); subtitle "· Personal" (12.5px, text2).
3. **Spacer** (flex:1).
4. **MCP chip** — pill, chip bg, 0.5px hair; green 7px pulse dot (`ccPulse 1.8s`); text
   `MCP connected · {n} agents` where n = distinct agents with running/waiting cards.
5. **Done button** — ✓ glyph (10px, opacity .6) + "Done" + optional count badge. Opens Archive
   popover.
6. **Activity button** — 3-bar equalizer glyph (bars 2px wide, heights 6/11/8px, opacities
   .55/1/.75) + "Activity". Opens Activity popover.
7. **Light/Dark toggle** — segmented control, ☀ (Light) / ☾ (Dark). Active segment gets card bg +
   shadow `0 1px 2px rgba(0,0,0,.16)`; inactive transparent.
8. **New agent button** — accent filled, "+" glyph (15px) + "New agent". Opens Spawn sheet
   (defaults to `impl` column).

### 4.2 Board

Three columns, exact `[key, label]` defs: `['plan','Plan'], ['impl','Implementation'],
['review','Review']`. Each column header: name (12.5px/600) + count badge (number of cards in
column) + spacer + "+" add button.

- Add button opens the Spawn sheet pre-set to that column (`plan` → Plan, else `impl`).
- Drag-over state: column bg → `overTint` (`rgba(0,122,255,.07)` light / `rgba(10,132,255,.12)`
  dark), border → accent.
- Empty column shows dashed "Drop a card here" placeholder.

**Auto-advance simulation** (autonomy on): every ~2.2s a running card gets a new CLI line; every 6th
tick a card may auto-advance review→done ("merged") or running→review ("moved").

### 4.3 Card

Anatomy top→bottom:

1. **Running shimmer** — 2px gradient bar pinned to top edge, only when `running` (see §5).
2. **Status pill** — colored dot (6px) + label. Label includes age: `"{label} · {age}"` for
   running/waiting (live timer, formatted `s`/`m`/`h`/`d`), no age for done. Dot animation:
   running `ccPulse 1.5s`, waiting `ccPulse 2.2s`, done none.
3. **Title** — AI summary of goal (13.5px/600, line-height 1.32).
4. **Description** — current activity blurb (11.5px/1.48). Color = amberText when waiting, else
   text2.
5. **Footer** — left: `repo · branch` mono (ellipsis); right: column-specific meta.

**Column-specific meta** (`cardMeta()`):

| Column | Meta label | Color | Style |
|---|---|---|---|
| Plan | `L{n} · {Design\|Contract\|Impl}` (n=planLayer) | indigoText on indigoTint chip | padding `2px 7px`, radius 5px, weight 600 |
| Impl | last read/edit file path (or `—`) | text2 | no chip, weight 500 |
| Review | `+{add}` and `−{del}` (two spans) | `+` greenText, `−` redText | no chip, weight 600 |

**Card border (`borderColor`):** selected → accent; waiting → amber border
(`rgba(255,159,10,.36)` light / `.40` dark); else `--cardBorder`. Selected also gets ring shadow.

### 4.4 Status pills

Reusable pill used on cards and in inspector header. Dot 6px + label; bg = status tint, text =
status text color. See §1.5. (Pulse animations as in §4.3 / §5.)

### 4.5 Inspector

Open when a card is selected. Top→bottom:

1. **Header bar** — "View changes" (Zed conic-gradient badge), "Archive" (✓), spacer, close (✕).
   - "View changes" → toast "Opening changes in Zed… {folder} · {branch}".
   - "Archive" → moves card to `done`, closes panel, toast "Archived".
2. **Agent terminal chrome** (flex:1):
   - **Context bar** — 2px top progress bar; width `ctxPct%` (= cli-line-count × 3.8, capped 94);
     color green (<50) → amber (<80) → red (≥80).
   - **Terminal header** — model chip (dot + model display name, e.g. `opus-4-5`), repo chip
     (folder name), branch (mono), status pill.
   - **Breadcrumb strip** — left: "Copy chat link" button (link-icon SVG + `agent/id` chip,
     copies `orchestra://chat/{agent}/{id}`); right: clickable worktree path broken into `›`-
     separated parts (last segment text2, prior two gray, rest text3) → "Copy worktree path".
   - **Terminal body** — CLI lines rendered per `lineStyle()` (see §4.8). Auto-scrolls to bottom.
   - **Prompt row** — `›` glyph (colored by live status: running green / waiting amber / done gray)
     + text input. Enter sends a message; in `plan` column it "refines the plan", else it
     "thinks → reads → on it".
   - **Bottom strip** — if no shell tabs: full-width "›_ New terminal" button. If shell tabs: tab
     ribbon (each tab `›_ {label}` + × close) + "+" new + minimize ▾/▴ toggle. Strip is drag-handle
     to resize shell panel (cursor ns-resize when tabs exist).
3. **Shell panel** (resizable, hidden when minimized) — own mono output + prompt `➜ {pwd} $ ▌`.
   Supports `clear`, `pwd`, `ls`, `git status`, `git log`, else "command not found".

### 4.6 Recovery panel (NOT in this build)

No `dead`/"Session lost" recovery UI exists in the prototype. If/when implementing the brief's
recovery state, propose: red status pill "Dead", a why-line, an "Originally asked" quote block, and
three buttons (Start new session / Archive / Try resume) styled like the inspector header buttons
(height 29px, radius 8px). **This is a forward-looking proposal, not extracted from the source.**

### 4.7 Spawn sheet

Fields top→bottom (see §3.7 for metrics): **Task** input (placeholder "e.g. Add rate limiting to
the API"), **Description** textarea (placeholder "What should the agent do?"), **Repository** +
**Branch** mono inputs side-by-side, **Model** segmented (`claude-opus`, `claude-sonnet`, `gpt-4o`,
`gemini` — active button text colored to the model's brand color: `#BF5836`/`#A8741C`/`#0E8C6D`/
`#3B73DB`), **Worktree** readonly (computed `~/worktrees/{repo}/{branch-with-slashes→dashes}`),
**Start in** segmented (Plan | Implementation). Then a **CLI equivalent** preview box (uppercase
caption + `$ orchestra spawn --task "…" --repo … --branch … --col … --model …`). Footer: **Cancel**
(card bg) + **Spawn agent** (accent). Defaults: repo `api-gateway`, branch `feat/new-task`, col
`impl`, model `claude-sonnet-4-5`.

### 4.8 Terminal line styles (`lineStyle()`)

Each CLI line type has a prefix, color, font-style, weight. Color refs are from `pal()`. A
`divider` renders as `─`×46.

| Type | Prefix | Color | Style | Weight |
|---|---|---|---|---|
| `agent` | `● ` | term | normal | 400 |
| `tool` | `  ` | text2 | normal | 400 |
| `result` | `  ` | text3 | normal | 400 |
| `user` | `›  ` | blue | normal | 400 |
| `think` | `  ` | text2 | italic | 400 |
| `ok` | `✳ ` | green | normal | 400 |
| `err` | `● ` | red | normal | 400 |
| `diffA` | `  + ` | green | normal | 400 |
| `diffD` | `  - ` | red | normal | 400 |
| `divider` | (none) | text3 | normal | 400 |
| `choice-cat` | `□ ` | blue | normal | 600 |
| `choice-q` | (none) | term | normal | 700 |
| `choice-sel` | `› ` | blue | normal | 600 |
| `choice-opt` | `  ` | term | normal | 500 |
| `choice-sub` | `    ` | text2 | normal | 400 |
| `choice-hint` | (none) | text2 | normal | 400 |
| `sys` | (filtered out of body; feeds breadcrumb chip+path) | — | — | — |

### 4.9 Done / Archive popover

Header "DONE" (uppercase) + "{n} tasks". Empty state "No archived tasks yet". Each archived row:
22px agent avatar (mono initials) + title (12.5px/600 ellipsis) + `repo · age` mono; below: three
copy/action buttons (`agent/id` chat-link with copy-icon SVG, `branch` with copy-icon, "Zed" with
conic-gradient Z badge), then a 0.5px hair divider.

### 4.10 Activity popover

Header: green pulse dot + Live/CLI segmented tabs + spacer + "MCP" mono label.
- **Live tab** — feed list (21px avatar + text + mono meta), footer `$ orchestra mcp — 4 tools · all
  agents run in tmux windows` (accent `$`).
- **CLI tab** — mono command reference: `orchestra list/spawn/move/send/status/archive/shell` with
  args in text2, plus an "Example — todo list → plan cards" block.

### 4.11 Settings (host props only)

No in-app settings UI. Exposed as Design-Component props (`data-props`): `accent`
(enum Blue/Purple/Graphite, default Blue), `density` (enum Comfortable/Compact, default
Comfortable), `autonomy` (boolean, default true). In SwiftUI model these as app preferences /
`@AppStorage` that drive the token computation in §1.

---

## 5. Animations (keyframes)

| Name | Definition | Duration / easing (where applied) | What it animates / usage |
|---|---|---|---|
| `ccPulse` | `0%,100%{opacity:1; transform:scale(1)} 50%{opacity:.35; transform:scale(.78)}` | MCP dot **1.8s ease-in-out infinite**; running card dot **1.5s**; waiting card dot **2.2s**; inspector status dot **1.6s**; activity dot **1.8s** | Breathing pulse on status/live dots — fades to 35% opacity and shrinks to 78% scale at midpoint. |
| `ccShimmer` | `0%{background-position:200% 0} 100%{background-position:-200% 0}` | running card top bar **2.4s linear infinite** | Horizontal light sweep across the 2px top bar. Bar = `linear-gradient(90deg, transparent, {green}, transparent)`, `background-size:200% 100%`, opacity 0.9 when running (else 0). |
| `ccSheetIn` | `from{transform:translateY(-10px) scale(.985)} to{transform:translateY(0) scale(1)}` | Spawn sheet **.24s ease-out** | Sheet drops in + slight scale-up. |
| `ccPopIn` | `from{transform:translateY(-6px) scale(.97)} to{transform:translateY(0) scale(1)}` | Archive & Activity popovers **.16s ease-out** | Popover settles down + scale-up. |
| `ccToastIn` | `from{transform:translateY(10px) scale(.98)} to{transform:translateY(0) scale(1)}` | Toasts **.22s ease-out** | Toast rises from below + scale-up. |

Other non-keyframe transitions: card `box-shadow .15s / transform .12s / opacity .12s`; column
`background .15s, border-color .15s`; context bar `width .8s ease`; breadcrumb hover `background
.1s`.

Scrollbars: 9px wide, thumb `--scroll` with `border-radius:9px`, 2px transparent content-box inset,
hover bumps opacity to ~0.35.

---

## 6. Iconography → SF Symbols

| Icon (prototype) | Where | SF Symbol proposal |
|---|---|---|
| `◧` app glyph | toolbar badge | `square.lefthalf.filled` (or custom logo) |
| `✓` check | Done button, Archive button | `checkmark` |
| 3-bar equalizer (custom bars) | Activity button | `chart.bar.fill` (or `waveform`) |
| `☀` sun | Light theme toggle | `sun.max.fill` |
| `☾` moon | Dark theme toggle | `moon.fill` |
| `+` plus | New agent, column add, new shell/tab | `plus` |
| `✕` / `×` | Inspector close, shell tab close | `xmark` |
| Pulse dot (●) | MCP / status dots | `circle.fill` (animated) |
| `Z` conic-gradient badge | View changes / Zed actions | custom Zed mark (gradient `square`) |
| Copy/overlap-rects SVG | Archive copy-link / copy-branch | `doc.on.doc` |
| Link / chain SVG | Inspector "Copy chat link" | `link` |
| `›` chevron | breadcrumb separator, terminal prompt | `chevron.right` (separator) / text `›` (prompt) |
| `›_` | New terminal / shell tab glyph | `terminal` |
| `➜` arrow | shell prompt | `arrow.right` (or literal `➜`) |
| `▾` / `▴` | shell minimize / expand | `chevron.down` / `chevron.up` |
| `$` | CLI command prompt (accent) | literal `$` (mono) |
| `□` | terminal choice-category | `square` |
| `─` row | terminal divider | literal repeated `─` |

---

## 7. Default data & formatting notes (for realistic mock state)

- **Columns/cards seed:** Plan (c1, c2 — waiting, planLayer 1/2), Implementation (c3 running,
  c4/c5 waiting), Review (c6 done, c7 waiting), Done/Archive (c8, c9 done).
- **Age timer** (`fmt`): `<60s`→`Ns`, `<60m`→`Nm`, `<24h`→`Nh`, else `Nd`. Live for running/waiting,
  static (`staticAge`) for done.
- **Worktree path:** `~/worktrees/{repo}/{branch with "/"→"-"}`.
- **Chat link:** `orchestra://chat/{agent}/{id}`.
- **Model display name:** strip leading `claude-` (e.g. `claude-opus-4-5` → `opus-4-5`).
- **ctxPct:** `min(94, round(nonSysCliLines × 3.8))`.
- **MCP chip:** updates every 2.2s; "MCP connected · {distinct running/waiting agents} agents".
