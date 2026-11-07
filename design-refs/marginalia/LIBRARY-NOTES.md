# Library restyle notes (2026-10-29)

Changed (LibraryWindow.swift, small edits in AskView.swift, UIShots.swift, BinTests.swift):
- One "Margin" title; one storage line at the sidebar foot; banner and header badge removed.
- Sidebar: solid-highlighter New Chat (only solid yellow), All, Sectors (7pt dot + count), Types, Bin pinned at the bottom with "Empties after 30 days" (true: Library.binDays = 30). Selected rows use highlighterWash, 8pt radius, no bar.
- Rows: question 13 medium, answer snippet 12, meta line (sector chip, relative time, quiz glyph). Trash only on hover/selection, context menu (Open, Copy question, Move to Bin). Sentence-case sticky time buckets with a count.
- Times: now / 5m / 2h / Yesterday / Mon / 12 Oct. Test strings updated.
- Sector colours from sky, plum, sage, ochre, neutral only; chips tinted.
- Detail: quote is the New York italic highlighter-band (QuoteMark made internal, `animated: false`); "Quiz me" labelled; disabled Send is surfaceRaised.
- Empty detail: quote, one help line (real shortcut: highlight anywhere, or ⌥⇧⇥), one action.
- Bin: Restore always visible, Delete forever in alert colour.
- Borders drawn as two fills (`boxed`), no stroked capsules. ⌘F also focuses search; ⌘⌫ moves the selection to the Bin.
- UIShots: added library-empty and library-bin.

Skipped:
- "Today" and "Kept/pinned" smart lists: the model has neither, would need new plumbing.
- Screenshot thumbnail grid: kept the row thumbnail (ScreenshotThumb).
- "Keep" action in chat detail: no existing library action for it.
- Return-to-open: selection already shows the detail.
- Sector colours: 5 colours for 7+ sectors, so Math/Language share plum.
