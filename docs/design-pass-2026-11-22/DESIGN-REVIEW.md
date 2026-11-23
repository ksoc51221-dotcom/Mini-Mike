# Merlin design review and design pass, 22 November 2026

This file has three parts: what was judged, what changed, and what is left for you to decide.

## 1. How the review was done

- **Screens:** 62 still pictures of the chat, the dock, the Library, Settings, the Assistant, the sector editor, the voice pill and the empty screens. Each screen was checked in light mode and dark mode.
- **Rules used:** three design skills, in this order: `emil-design-eng` (polish and motion), `apple-design` (Mac conventions), `impeccable` (structure and clutter).
- **Online sources that were read:**
  - motion.dev docs: springs, layout animations, enter and exit, stagger, gestures.
  - Emil Kowalski: "You don't need animations" and "7 practical animation tips".
  - Apple Human Interface Guidelines: sidebars, toolbars, toggles.
  - Linear: "How we redesigned the Linear UI".
  - Things 3 feature page and the Raycast home page.
- **Limits:** motion.dev keeps its example code behind a paywall, so no example numbers come from there. The Apple motion page did not load. Pictures cannot show movement.

## 2. The verdict before the pass

**Strong**
- One font, soft greys and one accent colour. The accent marks only the main action.
- The chat answer has a clear reading order: question, answer, sources, actions.
- The dock shows the state of each chat with a ring, a tick or a red mark.
- The Library uses the standard Mac layout: sidebar, list, detail. Apple's guideline recommends this layout.
- Contrast is good. The faintest text colour has a ratio of about 5 to 1 on the page background.

**Weak**
- Two switch styles in one app.
- The Assistant showed a button, a long command list and a three-line note around one input.
- Numbers and labels were repeated: "Library 34" above "All 34", and Quiz and Copy twice in a chat.
- Two empty messages disagreed during a search with no results.
- Some motion broke the app's own rules: dock rows popped in from 60% size with a bounce.
- The dock used three different wordings for the same states.

## 3. What changed

### Chat panel (`Sources/Merlin/AskView.swift`)
- The Learn switch now has the same shape and motion as the Settings switches.
- The four header icons are larger (22 pt), so they are easier to click.
- The "Minimize" button is quiet while the chat thinks. The status on the left is now the main item.

### Assistant (`Sources/Merlin/LibraryAssistantView.swift`, `Sources/Merlin/AssistantOrb.swift`)
- The "Commands" button and the long list are gone.
- Three example rows remain: "Find chats…", "Library stats", "Star this week's chats".
- The input hint now says what the Assistant can do: "Find, star, file, or change a setting…".
- The three-line note is one line. The full text shows when the pointer rests on it.
- The Send button is grey when the input is empty. It turns to the accent colour when there is text.
- The sidebar button shows "Assistant" only, without a second line.

### Library (`Sources/Merlin/LibraryWindow.swift`)
- The "Library" header no longer repeats the count of "All".
- The Settings row is one line.
- The Desk page keeps its content in one column, 720 pt wide, so a title and its sector are close together.
- A search with no results shows one message, not two.
- The empty Bin shows a bin icon. The old icon looked like a loading ring.
- A chat's header no longer repeats Quiz and Copy. Both are also in the "…" menu, so they stay in reach in a long chat.
- The "↵" hint on a hovered row is gone, because it overlapped the time. The Return key still opens the row.

### Dock (`Sources/Merlin/AgentSidebar.swift`, `AgentDock.swift`, `AgentBubble.swift`)
- One wording for states: "Waiting for your question", "Working on it…" or the live activity, "Done · click to read", "Something went wrong".
- The word "Open" is gone. The bar on the left already marks the open chat.
- The sector name no longer cuts off the "Done" line.

## 4. Motion

This pass mostly corrected motion that was already there. It added five new animations. Each one explains a change of state.

**New**

| Place | Motion | Why |
|---|---|---|
| Desk rows | Settle in one after another, 0.05 s apart | The page reads top to bottom on arrival |
| Sidebar sector rows | Fade and slide 4 pt when a sector is added or removed | A new sector does not just appear |
| List group counts | Digits roll when the number changes | The change is visible |
| Assistant card | Closes in 0.2 s; opens in 0.3 s | Leaving feels quick |
| Assistant Send button | Colour change over 0.2 s | Shows when sending is possible |

**Changed**

| Place | Before | Now |
|---|---|---|
| Dock: new chat row | Popped in from 60% size with a bounce | Fades in and settles from 96% in 0.22 s |
| Dock: error mark | Bounced in from 30% size | Fades and settles from 95% |
| Dock: flash on a row | From 80% with a 0.6 s glow | From 95% with a 0.3 s glow |
| Dock: tick | Drew itself again on unfold and on minimise | Draws once, when a chat changes from working to done |
| Learn switch | Round knob with a bounce | Same shape and motion as the Settings switches |
| Library hover, press, selection | 0.3 s | 0.2 s |

**Already there, kept**
- Rolling counts in the sidebar.
- The Assistant card growing from its button.
- The sliding highlight in the sidebar.
- The gentle entrance of empty screens.

Rules for the motion in this pass:
- Nothing starts from a size below 95%.
- Nothing lasts longer than 0.3 s.
- No bounce on functional parts.
- Reduce Motion (a macOS setting) keeps a short fade and removes movement.
- Actions that you repeat many times a day stay instant. Example: a switch between All, Notes and Screenshots.

Not touched: the chat panel's own moves in `AskPanel.swift`. Three of them last 0.34 to 0.42 s: the size change, the move into the dock and the return from the dock.

## 5. Checks

- Build: clean.
- Unit tests: `UNITTEST PASS`.
- Dock test: `SIDEBARTEST PASS`.
- Pictures: checked in light and dark for the chat, the Assistant, the Desk and the dock. See the `after-*.png` files in this folder.
- **Not checked:** the animations in the running app. Pictures freeze every animation at its last frame. You must look at the motion yourself after an install.
- Note: three animation tests fail when the display sleeps, because macOS stops window animations then. They pass with the display on.

## 6. Left for your decision

These change how the app works, so they were not done.

1. **Remove the Desk page.** It shows three recent rows that "All" also shows. Option: open on "All" and delete Desk. Things 3 gives its home list a job ("today"); Desk has no such job yet.
2. **Merge Settings pages.** There are eight pages. Usage and Storage can be one page. Privacy can move into General.
3. **Reduce the chat header.** Four icons sit next to the Learn switch. Option: keep Star and Close, and move "bigger" and "put away" into one menu. Cost: one more click for "put away".
4. **Fewer marks on list rows.** A row can show a sector icon, a type icon, a quiz mark and a time. Option: show the sector icon only in "All".
5. **Settings layout.** The cards stop at about 70% of the width. A centred column looks more balanced. The Feature session edits this file now, so this waits.
6. **Voice pill.** The Feature session rebuilds it as an orb, so it was not touched.
7. **Chat panel timing.** Shorten the three long moves in `AskPanel.swift` to 0.3 s or less.
8. **Two motion ideas that nobody built.** The dock folding into its pill, and a dragged chat shrinking into its sector.

## 7. Known small costs of this pass

- Twelve Assistant commands, such as "dark mode" and "new sector", have no button now. You type them. The input hint names the groups.
- One unused view (`SidebarSettingsRow`) remains in `AssistantOrb.swift`. It does no harm.

## 8. Manual test (about 5 minutes)

Pictures cannot show motion, so this test is the only motion check. Do it after an install.

1. **Chat.** Highlight text in any app and open the chat. Click the Learn switch three times. Confirm: the knob slides with no bounce, and the switch looks like the switches in Settings.
2. **Dock.** Ask a question, then click "Minimize". Confirm: the row fades in with no bounce. Wait for the answer. Confirm: the tick draws itself once, and the line says "Done · click to read".
3. **Desk.** Open the Library (⌘⇧L) and click "Desk". Confirm: the rows settle in from top to bottom in less than half a second.
4. **Assistant.** Click "Assistant" at the bottom left. Confirm: three example rows and one input show. Enter "dark mode" and press Return. Confirm: the row shows "Working…" and the theme changes.
5. **Search.** Enter "zzqx" in Search. Confirm: one message, "No results", and an empty right side. Then click All, Notes and Screenshots. Confirm: the sector list changes at once, with no slide.
