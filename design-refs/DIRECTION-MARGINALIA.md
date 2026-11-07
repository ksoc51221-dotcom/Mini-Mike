# Margin UI direction: "Marginalia" (2026-10-29)

Owner: Kien. Planned by Opus, executed by Sonnet agents in phases. UI/UX only: no changes to engines, routing, prompts, Claude plumbing or agent logic.

## Why change
The current look is "Claude, but small": terracotta #D97857 borrowed from Claude, a lavender glow for working, green for done, and orange cats. That makes four unrelated hues and no idea of its own. Margin's one gesture is **highlighting text in the margin of what you read**, so the brand is ink, paper and a highlighter.

## World
- **Paper** (light) and **ink** (dark) surfaces, which stay frosted (keep NSVisualEffectView) but are tinted toward warm paper and ink rather than neutral grey.
- **Highlighter yellow** is the one accent. It is used as a *mark* (a fill behind things, a ring or a stroke), almost never as text colour in light mode.
- **Red pencil** is used for errors and "needs your OK". **Sage** is used for done.
- The quote of what you highlighted is set in **New York italic** (the system serif, no download), like a pull-quote in a book margin. UI chrome stays in SF Pro.
- Signature motion: the **highlighter sweep**. The yellow band draws left-to-right behind the quoted text when a chat opens. Use it there and on the trigger, nowhere else.

## Tokens (define once in `Theme`; every view reads tokens; no new hard-coded colours)
Dynamic NSColor and SwiftUI Color pairs, light / dark:

| Token | Light (paper) | Dark (ink) | Use |
|---|---|---|---|
| surfaceTint | #FBF8F1 @ 0.72 over blur | #16171B @ 0.78 over blur | panel tint over vibrancy |
| surfaceRaised | #F3EEE3 | #202228 | input field, cards, chips at rest |
| hairline | #E3DDCF | #FFFFFF @ 0.08 | borders, dividers |
| ink | #1C1B18 | #ECE8DF | primary text |
| inkSecondary | #5E5A52 | #A8A397 | secondary text (≥4.5:1, check) |
| inkTertiary | #77736A | #8A867C | footers, hints (≥4.5:1 on surface; nudge if a check fails) |
| highlighter | #F5DC5A | #F2D64B | accent fills, marks, rings, focus |
| onHighlighter | #1A1700 | #1A1700 | text and icons on highlighter |
| accentText | #7A5A00 | #F2D64B | links and accent text (ochre ink on paper) |
| highlighterWash | #F5DC5A @ 0.35 | #F2D64B @ 0.16 | chip hover, selected rows, quote band |
| done | #3F7D4E | #7FB58A | finished agent, success |
| alert | #C2412D | #E5604A | errors, needs-approval badge, destructive |

Verify every text/background pair for contrast (better-colors skill). Body ≥4.5:1, large ≥3:1, in both modes. Write the measured ratios into a comment block above the tokens.

## Typography (better-typography skill)
- The scale is limited to 5 sizes: 11 (footer/meta), 12 (chips, labels), 13 (UI), 14 (answer body), 17 (headings in library). Weight steps: regular / medium / semibold only.
- The quote is New York italic, 14, inkSecondary, 2 lines max.
- The answer body is 14/21. Inline code uses SF Mono 13 on surfaceRaised with 3pt radius.
- Tabular numbers for times, counts and progress.

## Motion (emil-design-eng + apple-design skills)
- Springs: `.spring(response: 0.32, dampingFraction: 0.86)` for panels, `response 0.22` for small controls.
- Never animate from scale 0. A panel enters from scale 0.96 plus opacity 0, anchored at the cursor.
- Press feedback: scale 0.97 on chips and buttons. Hover: highlighterWash fill, 120ms ease-out.
- The highlighter sweep is a mask width from 0 to 100% over 380ms, ease-out, and plays once per chat open.
- Thinking: the status line text gets a soft shimmer instead of a spinner.
- Streaming: each new paragraph fades in (opacity 0→1, 160ms). No layout jank.
- Send button: arrow ↔ stop square morph while streaming.
- The done state draws a check stroke (trim 0→1, 300ms).
- Everything respects Reduce Motion: fall back to opacity-only crossfades.

## Surfaces to restyle (in priority order)
1. **Chat popup** (`AskView`, `Answer`, `PanelGlow`): highlighter-swept quote, chips, answer typography, sources as small domain chips, input field, send/stop morph, footer.
2. **Trigger spark** (`TriggerIcon`, `ClaudeMark`): a highlighter-yellow rounded square with an ink spark. It springs in, and a hover tilt is allowed.
3. **Corner circles and sidebar** (`AgentSidebar`, `PanelGlow`, `Motion`): the working ring is a highlighter stroke sweeping round (replacing the lavender glow); done is a sage ring plus the check draw-on; error is red pencil. Keep the existing geometry and layout constants.
4. **Agent bar** (`AgentBar`, `AgentBubble`): ink bar, Allow = highlighter with onHighlighter text, Deny = surfaceRaised, progress bar highlighter. Cats unchanged (their art stays).
5. **Library / history window** (`LibraryWindow`, `Library`): paper or ink background, sector chips coloured from a small derived set (highlighter, sage, sky #8DB6D9 / #3D6F99, plum #B78BB0 / #7A4E73) with text contrast checked.
6. **Voice pill, calendar card, quiz card, graph accent** pick up the tokens.

## Rules for executing agents
- Read this file, the matching skill files in `~/.claude/skills/` (emil-design-eng, apple-design, better-colors, better-typography, write-swift, impeccable's `reference/craft-floor.md`) before editing.
- **Never open windows on the user's screen.** Do not run `--demo`, `--placetest`, `--sidebartest`, `--glowtest` or any live test. Pictures come only from headless `ImageRenderer` flags (`--barpicture`, and the new `--uishots` from phase 1).
- **Never run `./build.sh --install`** (it kills the user's running Margin). Use `swift build -c release` and `.build/release/Margin --unittest`.
- Targeted edits; keep behaviour, copy and layout constants unless this file says otherwise. Do not touch `CatAtlas.swift` / `CatSleepAtlas.swift` (generated).
- Do not commit.
