# Library window fix spec (judge pass, 2026-10-29)

Target: `Sources/Margin/LibraryWindow.swift` (plus `Theme.swift` only if a token is missing). UI only: keep the data model, storage, `Library.swift` APIs, and every existing action (open, delete to Bin, restore, undo, prompt bar, kind picker, sectors). Follow `design-refs/DIRECTION-MARGINALIA.md` and its agent rules (no windows, no `--install`, no commits, verify with `--uishots` + `--unittest`).

Reference apps: Apple Notes / Bear (dense rows with a snippet), Things 3 (smart lists above user groups), Readwise Reader (one-key triage), Linear (hover actions, keyboard), ChatGPT/Claude.ai (time buckets).

## What is wrong now (from the after-phase2 shots)
1. "Margin" branding appears twice, and there are two storage badges. Keep one quiet storage line at the sidebar foot.
2. Every row has an always-visible trash icon. Show it only on hover or selection, and add a context menu (Open, Copy question, Move to Bin).
3. Every row says "now". Use relative time with tabular numbers (now / 5m / 2h / Yesterday / Mon / 12 Oct).
4. The caps "TODAY 7 ENTRIES" header is shouty. Use sentence-case sticky time buckets (Today, Yesterday, Previous 7 days, Previous 30 days, then month names) in 11pt medium inkTertiary, with the count in a lighter weight.
5. The selected row has a 3px left bar. Replace it with a full-row highlighterWash fill and 8pt radius, matching the chips.
6. There are two competing yellows (New Chat button and the selected Chats nav row). The selected nav row uses highlighterWash; only the single primary action may use solid highlighter.
7. Sector colours don't separate (several purples, two greens). Map sectors onto the derived set only (highlighter, sage, sky, plum, plus alert-free neutrals), shown as a 7pt dot in the sidebar and as a small tinted chip in rows. Check text contrast.
8. The empty detail pane uses the old caps "YOU HIGHLIGHTED" callout. Use the Marginalia quote instead: New York italic, 14, with a highlighter band behind it (static, no sweep here), and a one-line empty state with one action ("Highlight text anywhere and press ⌘⇧… to ask"; keep the real shortcut text the app already uses).
9. The disabled Send button looks broken. When empty, show it at surfaceRaised with inkTertiary arrow. Never use a greyed yellow.

## Target layout
- **Sidebar:** smart lists first (All, Today, Kept / pinned if the model has it, otherwise skip), then Sectors (dot + name + tabular count), then Types (Chats, Notes, Screenshots), then Bin at the bottom with "Empties after 30 days" only if that is true in `Library.swift` (check; if not, omit the claim).
- **List:** dense rows, about 3 lines each: the question in 13 medium ink (1 line), a snippet of the answer in 12 inkSecondary (1 line), and a meta line (sector chip · time · tiny glyphs for note / screenshot / quiz if known). Use the sticky time buckets from item 4. Screenshots kind shows a thumbnail grid (keep `ScreenshotThumb`).
- **Detail:** the quote (item 8 style) on top, then the chat. The action row "Ask follow-up · Keep · Quiz me" reuses existing actions only. Don't invent backends.
- **Keyboard (if cheap):** ↑/↓ move the selection, Return opens, ⌘⌫ moves to Bin, ⌘F focuses search. Skip any that need new plumbing.
- **Bin:** each row has a Restore button visible, and the destructive action is in alert colour.

## Motion
Row hover wash 120ms ease-out; selection change spring 0.22 / 0.86; hover actions fade in at 120ms. Reduce Motion means opacity only. No sweep in the library.

## Done means
- `swift build -c release` clean, `.build/release/Margin --unittest` passes.
- `--uishots` regenerated. Copy `library-light.png` and `library-dark.png` into `design-refs/marginalia/after-library/`, plus a Bin and an empty-detail shot if the uishots harness can do them cheaply (add cases to `UIShots.swift` if needed).
- A short `design-refs/marginalia/LIBRARY-NOTES.md`: what changed, and what was skipped and why.
