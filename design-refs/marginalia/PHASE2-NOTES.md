# Marginalia phase 2: motion, interaction, three fixes (2026-10-29)

Build: `swift build -c release` clean. `--unittest`: **859 ok, 0 FAIL** (UNITTEST PASS). Shots: `after-phase2/` (24 PNGs, light + dark). Not committed. No window was opened, no live test run.

## Visual fixes
1. **Quote highlighter** (`AskView.swift:727` `QuoteMark`): one band per text line (max 2), covering the lower 60% of the line, 2 pt corners, -1° skew, ragged right (band overshoots the last word by 3 pt on line 1, 5 pt on line 2; a clipped third line runs to the edge). Line positions are measured with TextKit at the width SwiftUI gives the text. New tokens in `Theme.swift`: `quoteBand` (light #F5DC5A @0.50, dark #F2D64B @0.30) and `quoteText` (light inkSecondary, dark paper ink #ECE8DF). Contrast: light 5.7:1, dark 6.2:1 (inkSecondary would have been 3.0:1 in dark). The dark band is still a dark gold on ink; that is what 0.30 of that yellow composites to.
2. **Sidebar row** (`AgentSidebar.swift`, `refresh()`): selected = `surfaceRaised`, hover = `surfaceRaised` @0.55; the arrival flash is now a faint ink flash. Only the ring carries yellow.
3. **Done circle** (`AgentBubble.swift`, `DiscView`): spikes, brush check and mask removed. Now a sage ring plus one check stroke. (`BrushCheck.swift` is untouched; tests and Demo still use it.)

## Every animation
| What | Where | Duration / curve | Reduce Motion |
|---|---|---|---|
| Panel enter: scale 0.96 + fade, anchored at the spark (cursor) | `AskPanel.swift:270` via `Motion.popIn(about:)` | spring response 0.32, damping 0.86 (CASpring stiffness 385, damping 33.8); fade 0.18 s ease-out (existing) | no scale, fade only |
| Highlighter sweep, line by line, once per chat open | `AskView.swift:~790` | mask width 0→100%, 380 ms ease-out, line 2 starts 190 ms after line 1 | band fades in 200 ms, no sweep |
| Trigger spring-in | `TriggerIcon.swift:68` | from 0.8 (was 0.5), response 0.32, damping 0.7 | fade only |
| Trigger hover 1.06 / press 0.94 | `TriggerIcon.swift:207` `settleScale()` | spring response 0.22, damping 0.86 | none (colour brighten stays) |
| Chips hover wash / press 0.97 | `AskView.swift:1342` (`ChipStyle`), `:1316` (`ProminentChipStyle`, darkens 8% on hover), `:1089` (`SourceChip`) | hover 120 ms ease-out; press spring 0.22 / 0.86 | colour only |
| Icon buttons press | `AskView.swift:1114` `PressStyle` | 0.97 default, 0.92 for icon-only (header, send) | none |
| Thinking shimmer | `AskView.swift:894` `ShimmerText` (spinner next to "Reading…" removed) | 1.6 s linear loop (existing) | static secondary text |
| Streaming paragraph fade | `AskView.swift:928` `ParagraphFade` | opacity 0→1, 160 ms ease-out, no layout change | same (opacity only) |
| Send arrow ↔ stop square | `AskView.swift:809` `SendGlyph` | spring 0.22 / 0.86 | crossfade, no scale |
| Working ring: highlighter arc sweeps round | `AgentBubble.swift:205` | 1.4 s linear loop; aura breathes 1.6 s | arc sits still, steady glow |
| Done: check draws on | `AgentBubble.swift:225` `celebrate()` | strokeEnd 0→1, 300 ms ease-out | 200 ms fade |
| Error: red-pencil shake | `AgentBubble.swift:243` `shake()` | 2 cycles, ±4 pt, 320 ms | none |
| Agent bar Allow / Deny press | `AgentBar.swift` (`onPress` → `model.pressed`, `pill()`) | scale 0.97, spring 0.22 / 0.86 | none |
| Agent bar progress width | `AgentBar.swift:905` | spring 0.32 / 0.86 | none |
| Panel glow bloom | `PanelGlow.swift` `bloom()` | existing 1.1 s | skipped |

`Motion.swift` holds `reduceMotion` (NSWorkspace flag, read at use time), `still` (headless harness flag), `spring(response:damping:)`, `layerPoint(fromScreen:in:)` and the new `popIn(about:response:damping:)`. All `Motion.popIn` / `shrinkOut` calls skip themselves under Reduce Motion.

Also removed: the lavender/ripple remnants. `GlowView` is now one bloom at about half its old strength (no rippling rings, no completion burst).

## Could not do / caveats
- **Nothing was seen moving.** The shots are static (the harness sets `Motion.still`, so the sweep and check appear at their final frame). The spring values, the cursor-anchored scale and the press/hover states are untested live.
- **Cursor anchor** is the spark's centre, clamped to the panel edge. The y flip for the hosting view's layer is handled by comparing `isFlipped` with `isGeometryFlipped`; if the panel visibly grows from the wrong corner, that is the line to check (`Motion.layerPoint`).
- **Stop button:** no stop action exists, so the square is only a state indicator and the button stays disabled while streaming.
- The thinking shimmer, chip hover and the 120 ms hover already existed from phase 1; they now respect Reduce Motion.
- Icon-only buttons press to 0.92, not 0.97 (0.97 would be invisible on 18–22 pt circles).
- Sweep line 2 delay (190 ms) is my choice; the spec only says "line by line".
- Sidebar working aura still reads slightly khaki on the dark sidebar; lower the 0.38 alphas in `GlowView.setPhase` if it is too much.
