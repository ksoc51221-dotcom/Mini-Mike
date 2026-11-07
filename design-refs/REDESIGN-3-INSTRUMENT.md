# Redesign 3 — "Instrument"

Margin stops looking like a notebook and starts looking like a precision instrument: near-black and off-white,
hairline structure, one electric accent used rarely, monochrome glyphs, Geist type. Whole app, not just the library.

Owner decisions (Kien, 2026-10-29): whole app · "Mono instrument" · Geist + Geist Mono · B&W glyphs for sector icons
and status/empty states (the pixel cat stays).

## 0. What dies
- Paper cream, ink brown, the yellow highlighter, highlighter washes, the quote *band*, New York italic, ochre accentText.
- The 8 sector colours. Sectors are told apart by **glyph**, never colour. (`UserSector.colorIndex` stays in the data
  model for decoding; the UI ignores it and the editor's colour picker is removed.)
- Capsule chips. Chips become small rectangles (radius 4). Panels radius 10, cards 8, buttons 6.
- Any copy that says "notebook/paper/ink/highlighter" in UI text (e.g. the sector hue names).

## 1. Tokens (Theme.swift — keep the `Token` struct and API shape)
Contrast measured (WCAG). Dark is the primary look; light is its exact inversion.

| token | dark | light | notes |
|---|---|---|---|
| canvas | #0B0B0C | #F6F6F3 | windows that aren't frosted |
| surfaceTint | #0B0B0C @0.82 | #F6F6F3 @0.80 | over the blur |
| surface (new) | #131315 | #FFFFFF | sidebars, cards |
| surfaceRaised | #1B1B1E | #EDEDE9 | inputs, hover |
| surfaceSelected | #242428 | #E3E3DE | selected row |
| hairline | white @0.08 | #000 @0.09 | dividers |
| hairlineStrong (new) | white @0.16 | #000 @0.18 | focused/active borders, grid ticks |
| ink | #F2F2EE (17.5) | #0B0B0C (18.2) | |
| inkSecondary | #A3A3A8 (7.4 on surface) | #52525A (7.7) | |
| inkTertiary | #838389 (4.9 / 4.6 raised) | #6A6A71 (5.0 / 4.6) | NOT on selected rows (4.1) — use inkSecondary there |
| accent (new) | #C6FF3D | #C6FF3D | **fills/marks only** in light; black text on it 16.7 |
| onAccent (new) | #0B0B0C | #0B0B0C | |
| accentText | #C6FF3D (15.7) | #4A6B00 (6.2) | accent as text/links |
| accentWash (new) | #C6FF3D @0.10 | #C6FF3D @0.28 | drop targets, focus glow only |
| done | = accentText | = accentText | success uses the accent |
| alert | #FF5A4E (6.0) | #C8321F (5.3) | |

Compatibility: keep the old names compiling so nothing breaks mid-migration, but repoint them:
`highlighter`→accent, `onHighlighter`→onAccent, `highlighterWash`→accentWash, `quoteBand`→clear/surfaceRaised,
`quoteText`→inkSecondary, `sectorGold/sky/plum/clay/teal/rose/slate`→ink (all), `sectorHues` → 8× ink,
`sectorHueNames` unused. Then the restyle agents delete call sites of the dead ones; the integrator removes the aliases.

Accent budget: at most ~3 accent marks visible on any screen (focus ring, the live/current indicator, one primary
button or the "now" bar of a chart). If you're adding a 4th, use ink.

Dark-mode rule from round 2 still holds: no low-alpha warm washes over black.

## 2. Type (Geist + Geist Mono, bundled)
Files: `Resources/Fonts/{Geist-Variable,Geist-Italic-Variable,GeistMono-Variable}.ttf` + `OFL.txt`.
- `build.sh` copies `Resources/Fonts/*` into `Margin.app/Contents/Resources/Fonts/`.
- Register at launch with `CTFontManagerRegisterFontsForURL(..., .process, ...)` from `Bundle.main.resourceURL/Fonts`,
  falling back to `<repo>/Resources/Fonts` relative to the executable when run from `.build/release` (shot/test flags),
  and finally to SF Pro / SF Mono if registration fails (never crash, never blank text).
- Variable fonts: weights via `Font.custom("Geist", size:).weight(...)` — **verify in a rendered shot that semibold
  actually renders heavier**; if it doesn't, build the font through a CTFontDescriptor with the `wght` variation axis.

Scale (keep the `Font.m*` names; add mono variants):
| token | font | size/line | use |
|---|---|---|---|
| mMeta | Geist Mono 10.5, tracking +0.4 | 14 | times, counts, kbd hints, footers |
| mLabel | Geist Mono 10.5 **UPPERCASE**, tracking +1.0, medium | 14 | section labels ("RECENT", "SECTORS") |
| mUI | Geist 13 | 18 | UI text, rows |
| mBody | Geist 14 | 22 | answers |
| mHeading | Geist 18 semibold, tracking −0.2 | 24 | titles |
| mDisplay (new) | Geist 28 semibold, tracking −0.6 | 32 | Desk greeting, settings page titles |
| mQuote | Geist Italic 14 | 22 | the selected passage |
| mCode | Geist Mono 13 | 20 | code |
| mNum (new) | Geist Mono 12 `.monospacedDigit()` | | numbers that change (counts, tokens, $) |

`NSFont.margin(size, weight)` returns Geist; add `NSFont.marginMono`. Replace every raw `.font(.system(size:…))`
with a scale token (or `.mUI.weight(.semibold)` etc.). Raw `.system` is allowed only for SF Symbols.
`LibraryWindow`'s local `Font.mono(_:_:)` becomes Geist Mono.

Numbers/times/counts are ALWAYS mono. Prose is ALWAYS Geist. That contrast is the techy feel.

## 3. Glyphs (new file `Glyphs.swift`)
A custom monochrome icon set drawn in code (SwiftUI `Canvas`/`Path`), one colour = the ink it's given. No SF Symbols,
no emoji, no colour. Grid 24×24, stroke 1.5 at 24pt (scale with size), round caps/joins, optional solid fills in ink,
negative space allowed (the black hole is a filled disc with a ring). Every glyph is animatable through a `phase`
(0…1, looping) and an `active` flag (hover/selected → livelier).

API:
```swift
enum GlyphKind: String, Codable, CaseIterable { … }   // the set below
struct Glyph: View { let kind: GlyphKind; var size: CGFloat = 16; var color: Color = Theme.ink.color; var animated = false; var active = false }
```
`animated` drives a `TimelineView(.animation)` only while visible; Reduce Motion → static pose. Idle animation must
be slow and small (≤ 6 s loop, ≤ 15% movement) so a sidebar of 12 animated glyphs isn't a circus — sidebar shows them
static, animating only on hover/selection; the Desk tiles animate.

Set (≥ 28). Sector defaults in **bold**:
- **blackHole** (Physics — disc, tilted accretion ring rotating, photon ring), **sigma** (Math — Σ with a ticking
  index), **flask** (Chemistry — bubbles rise), **helix** (Biology — DNA twisting), **brackets** (Computer Science —
  `{ }` with blinking cursor), **graphUp** (Economics — line drawing on), **glyphA** (Language — "Aa" morphing to "Яя"),
  **hourglass** (History — sand), **nib** (Writing — pen nib drawing a stroke), **pulse** (Health — ECG trace),
  **cube** (Business — wireframe cube rotating), **void** (Other — dotted circle slowly spinning).
- Extra for user sectors: atom, planet (ringed), comet, galaxy (spiral), neuron, chip, terminal, globe, compass,
  prism (light split, in greys), wave (sine), infinity, key, music, leaf, lightning, eye, scales, rocket, gear, star.
- Status/empty: **orbit** (thinking: 3 dots orbiting a point), **scan** (searching / no results: a scanline over a
  frame), **emptyVoid** (empty Bin: the black hole with nothing falling in), **spark** (Desk greeting/new),
  **check** (done: draws on), **warning** (alert, in `alert` colour — the one allowed non-ink glyph).

Data model: `UserSector` gets `icon: GlyphKind?` (optional, so old JSON decodes). Display rule: `icon` if set, else the
default for a built-in sector name, else a stable pick from the "extra" list by name hash (same as SectorOrder's
stable hash). The old `glyph: SectorGlyph` stays decodable and is ignored. `sectorStyle(_:)` in LibraryWindow returns
the GlyphKind; `SectorMark`/`SectorDot` render `Glyph`.

Sector editor: the colour row + shape row become one **glyph picker**: a 7-column grid of animated tiles; selected tile
gets a hairlineStrong frame + accent tick in the corner.

Gallery: `--glyphshots <dir>` renders every glyph at 16/24/48 in dark and light, plus a 4-frame strip of each
animation (phase 0, .25, .5, .75), to PNG. That's how the glyphs are reviewed — they must read clearly at 16pt.

## 4. Structure language
- **Grid & hairlines** instead of cards-with-shadows. Sections are separated by 1px hairlines; section headers are
  mono uppercase labels with a count in mono right-aligned (`RECENT ······ 03`). Zero-padded counts (03, 42).
- No drop shadows except the floating popup (one soft shadow, black @0.4, y 12, r 32).
- Selected row: surfaceSelected + a 2px accent bar at the left edge (the only accent in the list).
- Hover: surfaceRaised; the row's glyph switches to `active`.
- Buttons: primary = accent fill + onAccent text, radius 6, height 26; secondary = surfaceRaised + hairline (two
  fills); ghost = text only. Keyboard hints rendered as mono kbd tags (`⌘K` in a 1px hairline box, radius 3).
- Inputs: surfaceRaised, radius 6; focused → hairlineStrong border + a 1px accent underline that sweeps in from left.
- The quote (selected passage): no band. A 2px accent bar on the left, Geist Italic in inkSecondary, a mono
  `SELECTION · Safari` label above it.
- Charts (sparklines, usage chart): ink lines 1.25pt, bars in inkTertiary, today's bar/point in accent, mono axis labels.
- Borders stay two fills (never `strokeBorder` on a Capsule; prefer `RoundedRectangle` and still two fills).

## 5. Motion (more of it, all purposeful — Motion.swift gets SwiftUI tokens)
Tokens: `Motion.snappy = .spring(response: 0.28, dampingFraction: 0.86)`, `Motion.smooth = .spring(response: 0.45,
dampingFraction: 0.9)`, `Motion.quick = .easeOut(duration: 0.14)`. Reduce Motion → `.easeOut(0.12)` opacity only,
glyphs static, no text scramble.

Library:
1. **Boot**: window open → sidebar sections, then content blocks, fade+rise 6pt, staggered 30 ms (max 8 steps).
2. **Decode text**: Desk greeting and page titles resolve from random mono glyphs to the real text (≈350 ms, once per
   appearance). Mono-only effect; never on body text.
3. **Numeric roll**: every count/token/$ uses `.contentTransition(.numericText())` and animates when it changes.
4. **Sidebar indicator**: selection bar slides (matchedGeometryEffect) — already exists, restyle to the 2px accent bar.
5. **Row hover**: background fades in 120 ms, glyph goes active, a mono "↵" hint fades in at the right.
6. **List changes**: insert = fade + slide 8pt; delete = collapse height + fade; reorder = spring.
7. **Detail open**: blur 8→0 + opacity + 12pt slide from right (snappy).
8. **Sparklines/usage chart**: draw on (trim 0→1, 600 ms) on first appearance; today's dot pulses once.
9. **Drag to sector**: lifted row scales 1.02 with shadow; target sector row shows accentWash + its glyph goes active;
   on drop the count rolls and the glyph does one "absorb" beat (blackHole literally swallows).
10. **Search**: ⌘K / focus → field widens 40pt with smooth spring, accent underline sweeps; results stagger in.
11. **Empty states**: animated status glyph + one mono line ("BIN EMPTY · 0 ITEMS").
12. **Settings**: section switch cross-fades with 6pt slide; toggles spring.

Popup chat / app:
13. **Thinking**: `orbit` glyph + a mono shimmer on "THINKING" instead of any paper-style indicator.
14. **Answer stream-in**: each new paragraph fades in (no per-character effects — readability first).
15. **Chips/sources**: stagger in 25 ms.
16. **Popup open**: keep the existing AppKit pop-in (Motion.popIn), add content fade 80 ms after.

Budget: nothing loops forever on screen except glyphs that are explicitly `animated` on the Desk and the thinking
indicator. Everything else plays once.

## 6. Surfaces to restyle (whole app)
- Library: LibraryWindow.swift, LibrarySettingsView.swift, SectorEditorView.swift.
- Popup/chat: AskView.swift, AskPanel.swift, TaskBox.swift, EventCard.swift, Quiz.swift, GraphView.swift,
  VoiceMessageView.swift, Voice.swift (UI parts).
- Agents: AgentSidebar.swift, AgentBar.swift, AgentBubble.swift, AgentDock.swift (the cat stays, but its chrome goes
  mono), PanelGlow.swift (glow → accent, subtler), TriggerIcon.swift.
- Status menu / Settings window: StatusMenu.swift and wherever the app's Settings UI lives.
- App icon (`--render-icon`): out of scope this round unless trivial.

## 7. Work split
- **A — Foundation** (alone, first): Theme tokens + aliases, font bundling/registration, type scale, Motion tokens,
  mechanical sweep of raw `.system(size:)` fonts → scale tokens across all files. No layout changes.
- **B — Glyphs** (parallel with A): Glyphs.swift + `--glyphshots` + SectorStore `icon` field + tests. Touches only
  Glyphs.swift, SectorStore.swift (field + default mapping), main.swift (one flag line), SectorTests.swift.
- **C — Library** (after A+B): LibraryWindow, LibrarySettingsView, SectorEditorView, UIShots.swift (library cases).
- **D — App chrome** (after A+B, parallel with C): every file in §6 except the library three and UIShots.
- **Integrator** (me + one Sonnet pass): remove aliases, review all shots light/dark, fix, install.

Rules for every agent: don't edit CatAtlas.swift / CatSleepAtlas.swift; borders as two fills; no windows on the user's
screen (headless shots only); don't commit; `swift build -c release` and `.build/release/Margin --unittest` must pass
(UNITTEST PASS) before you report; if the build breaks in a file another agent owns, wait 60 s and retry rather than
editing it.
