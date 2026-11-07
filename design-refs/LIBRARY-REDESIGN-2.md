# Library redesign, round 2: "Commonplace book" (2026-10-29)

Kien's verdict on the live app (dark mode, real data: 84 items, 25 chats, 59 screenshots, 143 in Bin) is "still looks really tacky". He's right. This is the judge's diagnosis and the target design. It builds on `DIRECTION-MARGINALIA.md`, whose tokens and rules still apply.

## Diagnosis (from the real screenshot, not fake data)
1. **Most of the window is empty.** With nothing selected, the right ~50% shows one tiny centred line. The window has no focal point.
2. **The rows repeat themselves.** Every row ends with a coloured chip plus a day ("Math · Mon", "Math · Mon", "Math · Mon"). Eight identical chips in a column read as noise, not information.
3. **Two taxonomies compete in the sidebar.** "Sectors" and "Types" both filter, the counts don't add up (All 84, Chats 25), and it's not clear which filter is active.
4. **The selection and hover colours are off.** The selected nav row is a muddy olive (yellow wash over ink). Row hover is a bluish grey that isn't in the palette.
5. **The search focus ring is loud.** A thick yellow ring around search is the brightest thing on screen, apart from New Chat.
6. **There is no type hierarchy.** Sidebar, row titles and snippets are all ~15pt, with only weight changing. Titles are raw ("answer", "how to do 10 b").
7. **The dots look the same.** Math and Language are both pink, and Other is grey.
8. **Bin (143) dwarfs the library (84).** It's a scary number in the sidebar.
9. **Nothing moves.** Filtering, selecting and deleting all snap with no motion.

## Target design

### Layout: two states, not three empty columns
- **Nothing selected:** the list and detail merge into a **Desk** view across the full width to the right of the sidebar.
  - **"Pick up where you left off":** the 3 most recent chats as large cards. Each card shows the quote in New York italic with the highlighter band and the answer's first line.
  - **"Your sectors":** a shelf of sector tiles, each with its colour, count, last-active date and a tiny sparkline of chats per week (tabular numbers). Clicking a tile filters the list.
  - **"To review":** quiz items due, if any exist; otherwise hide this.
- **Something selected:** the classic list + detail. The detail slides in from the right (offset 16pt + opacity, spring 0.32 / 0.86), and Esc returns to the Desk.

### Sidebar: one taxonomy
- **Top:** a search field with a hairline border. Focus gives a 1px highlighter ring plus a soft 3pt wash glow, not a thick ring.
- **Library:** All, Chats, Notebook, Screenshots as one list, so type is a scope. The counts are true.
- **Sectors:** user-editable. Each row has a colour dot (the shape varies when hues repeat: ●, ◆, ▲, ■), name and count. A "+ New sector" row at the end and a drag handle on hover.
- **Bin:** at the very bottom, without the count. Show "Bin" plus "Empties after 30 days" on hover.
- **Selected nav row:** surfaceRaised fill plus ink text, with the icon tinted highlighter. No yellow wash on dark.

### Rows
- **Line 1:** the title (13 semibold, ink) with the time right-aligned (11 tabular, inkTertiary).
- **Line 2:** the snippet (12, inkSecondary, 1 line).
- **Sector marker:** a small coloured dot before the title instead of a chip. Show it only when the list isn't already filtered to that sector. Remove the chip entirely.
- **Row spacing:** padding 10/12 and a hairline divider inset 12, or no dividers with 4pt gaps. Use no cards.
- **Hover:** raised fill, at 120ms ease-out.
- **Selection:** raised fill plus a highlighter dot that slides between rows with `matchedGeometryEffect`.
- **Bad auto-titles:** if a title is fewer than 3 words or all lowercase, show the first quote words in italic instead ("answer" becomes the quote).

### Detail
- **Header:** the sector pill (clickable, opens Move to…), the app it came from, and the time, then the title (17 semibold).
- **Quote:** a New York italic block with the highlighter band, which sweeps once when the detail opens (respecting reduced motion).
- **Turns:** your question in 13 medium with an ochre "Q" marker, then the answer in 14/21 body. Code blocks are raised.
- **Action rail (top right):** Quiz me, Copy, Move to…, Bin. Each is an icon with a tooltip, and the rail is visible on hover or focus.

### Colour fixes
- **Dark hover and selection:** surfaceRaised `#202228` with a lighter step `#262830` for selection. Never yellow at low alpha over ink.
- **Sector palette:** 8 hues, each checked at ≥3:1 for dots and ≥4.5:1 when used as text:
  - highlighter
  - sage
  - sky
  - plum
  - clay (#C98A5B / #9A5B32)
  - teal (#6FB3A8 / #2E7068)
  - rose (#D98BA0 / #9E4A63)
  - slate (#9AA3B5 / #535B6E)

  Hues are assigned in sector order and stored per sector, so they're stable.

### Motion and interaction
- **List:** on a filter change, rows crossfade and stagger in at 20ms each (the first 12 only). Deleting a row collapses its height (spring 0.22) and shows the Undo toast.
- **Selection:** the indicator slides between rows with matchedGeometry.
- **Drag to file:** drag a row onto a sidebar sector. The row lifts (scale 1.02, shadow), the target sector row glows with highlighterWash and its dot pulses once, and on drop the count ticks up with a numeric text transition. The same works with multi-select (⌘-click, ⇧-click).
- **Keyboard:**
  - ↑↓ move the selection.
  - Return opens the selected item.
  - Esc returns to the Desk.
  - ⌘F searches, ⌘⌫ moves to Bin, ⌘⇧M opens Move to….
  - 1–9 jump to sectors when the list has focus.
- **Reduced motion:** opacity changes only.

## Work split (parallel worktrees, merged by Opus)
- **A. Sectors** (`Library.swift`, new `SectorStore.swift`, `SectorEditorView.swift`, `Prompts.swift`): user sectors with colour, glyph, description and rules; create, rename, merge, delete, reorder; rule-based filing; "Help me write the rules" via one lean Claude call; a refile-all preview.
- **B. Library settings** (new `LibrarySettingsView.swift`, `LibraryUsage.swift`, `Settings.swift`): a settings window in the Claude-settings style, with a usage panel that reads `UsageLog`.
- **C. Redesign** (`LibraryWindow.swift` only): everything in this file except the sector editor and settings, which C opens through two placeholder hooks:
  - `LibraryHooks.openSectorEditor`
  - `LibraryHooks.openSettings`
