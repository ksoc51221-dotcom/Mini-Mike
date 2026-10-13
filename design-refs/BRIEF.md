# Design brief: Margin, a macOS "ask Claude about this" helper

## What it is
Margin is a small native macOS menu-bar utility. When you're reading something (usually an explanation from Claude) and one part is confusing, you highlight it and ask a quick side-question in a floating popup. Your main chat stays uncluttered. Each question runs as its own small AI agent. The agent sees the highlighted text and a screenshot of your screen, and it can search the web. Up to 4 agents can run at once, and you can park them as glowing circles in the corner of the screen.

## How it works (user flow)
1. Highlight text in any app. A small "?" bubble pops in next to the cursor.
2. Click it. A floating chat popup opens right there, quoting the highlight.
3. Type a question, tap a quick chip (Simpler / Example? / Define terms), or just press Return.
4. While the agent works, a status line shows what it's doing, e.g. "Searching 'latest Swift release'" or "Reading swift.org".
5. Click Minimize. The popup shrinks and flies into a ~1 cm circle at the top-right of the screen.
   - The circle glows light purple and pulses while the agent works. It turns dark green when the answer is ready, and red on error.
   - Click the circle to fly the chat back out.
   - Hover over it to see the question and a small × to dismiss it.
6. If you can't highlight something (a scanned PDF, an image), hold Tab and press \ to get the macOS crosshair, then drag a box. The popup opens with a thumbnail of the snip instead of quoted text.
7. Ask follow-ups or tap "Go deeper" in the same popup. Clicking away or pressing Esc dismisses it, and finished chats fade out after ~20s idle.

## Current visual design (screenshots attached, dark mode)
Overall the style is minimal, quiet and macOS-native:
- Translucent frosted-glass panels (the system popover blur)
- Follows the system light/dark mode
- Font is SF Pro
- One accent color: terracotta #D97857 (Claude orange)

**"?" trigger**
- A 26pt solid terracotta circle with a bold white "?" and a thin 35% white outline.
- It springs in when it appears.

**Chat popup**
- 380pt wide. Height grows with content, and the answer area starts scrolling past 360pt.
- 14pt padding, 14pt corner radius, frosted blur, 1px hairline border, soft shadow.
- **Header:**
  - The highlighted text in italic gray (2 lines max), with a 3pt terracotta bar on its left.
  - On the right, two small 18pt circular icon buttons (↗ minimize, × close) on a faint gray fill.
  - For snips, a 56×34 thumbnail with a terracotta outline and the text "Your snip from Preview" replace the quoted text.
- **Quick chips:** pill buttons with terracotta text on a 14% terracotta fill.
- **Each turn:**
  - The question is a small semibold terracotta label.
  - The answer is regular body text with inline bold, code and links (links are terracotta).
  - Code blocks are monospace on a faint, rounded gray block.
  - A "Sources:" list of links comes at the end.
- **Working state:** gray "Thinking…" or "Searching …" text with a light shimmer sweeping across it, and a "↗ Minimize" pill on the right.
- **"↘ Go deeper" pill** after each answer.
- **Input bar:**
  - A rounded (9pt), faint gray field with the placeholder "What's confusing about this?" or "Ask a follow-up…".
  - A 22pt round terracotta send button with an ↑ arrow, dimmed when disabled.
- **Footer:** a tiny, faint gray caption such as "Sonnet · web search on · sees your screen".

**Corner circles**
- 1 cm diameter, stacked vertically at the top-right under the menu bar (16pt margin, 18pt gap).
- A dark, near-black disc at 92% opacity with a 3pt colored ring, an outer glow and a soft halo.
- A white SF Symbol in the center: magnifying glass while searching, "…" while writing, ✓ when done, ! on error.
- Colors:
  - Working: light purple #C9A8FF, with the glow pulsing every ~1.1s.
  - Done: dark green #0D7A36, a steady glow with a one-time flash.
  - Error: red #E5484D.
- On hover, a small × badge appears at the circle's top-left. A frosted pill label appears to its left, with the question in 12pt semibold and the status in 11pt gray.

**Toast:** a small frosted rounded rectangle with one line of 12pt text, e.g. "All 4 agents are busy…".

**Menu bar:** a "questionmark.bubble" SF Symbol with a standard dropdown menu.

**Motion:**
- The "?", the popup and the circles spring in.
- The popup grows smoothly as text streams in, and the text types out at a steady pace.
- Minimize and expand are a 0.4s flight of the chat into and out of its circle.
- Idle chats fade out over the last 4 seconds.

## What I want from you
Make the visual design feel more polished, premium and cohesive, like a first-party macOS feature, while keeping it minimal and out of the way.

**Design these states, in both dark and light mode:**
1. The "?" trigger next to highlighted text
2. The empty popup
3. The popup while searching or thinking
4. The popup with a finished answer, including a code block, sources and the follow-up field
5. The snip version of the header
6. The corner circle column, showing a purple working circle, a green done circle, and one hovered circle with its label and ×
7. The toast

**Keep:**
- the 380pt-wide floating popup
- the 1 cm circles at the top-right
- the light-purple glow for working and dark-green glow for done
- the terracotta accent
- frosted macOS materials and SF Pro

**Improve:**
- the visual hierarchy between question, answer and sources
- the header and button styling
- the chips
- the input bar
- the working-state indicator
- the circle details: ring, glow, glyph, hover label
- spacing and typography

**Constraints:**
- It will be rebuilt natively in SwiftUI/AppKit on macOS, so stick to things that translate: blur materials, rounded rectangles, gradients, shadows and glows, SF Symbols. No web-only effects.
- List exact values for everything you change: hex colors (light and dark), font sizes and weights, corner radii, padding, element sizes, shadow and glow settings, and animation timing.
