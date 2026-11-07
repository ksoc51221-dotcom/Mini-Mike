# Margin UI notes (2026-10-23 design pass)

## Principles used (from Apple HIG and designer write-ups)
- Text contrast of at least 4.5:1 on its background, in both light and dark mode. Terracotta #D97857 is fine on dark but
  only ~2.5:1 on pale fills, so text uses `Theme.accentText` (darker terracotta in light mode).
- Hierarchy comes from colour, size or weight, not all three at once. Secondary text recedes with a lighter colour, never a lighter weight.
- One accent (terracotta) across every window; system blue/grey controls look off-brand and, in non-key panels, look disabled.
- Put the status before the label in narrow rows, so truncation hits the less important part.
- Spell out ambiguous data (the calendar card shows "Friday, 8 January 2027" under the regional short date).

## What changed
| Area | Change |
|---|---|
| Popup footer | secondary colour, 10.5pt (was near-invisible tertiary) |
| Quick chips | all six have icons, wrap 3 + 3 |
| Answer text | 10pt between paragraphs; lists hang under their text; Sources get their own "SOURCES" section |
| Light mode | `Theme.accentText` for chips, links, question label, quiz card |
| Agent / approval cards | "Show / Open / Show files" terracotta; cost warning text brighter |
| Library | `Ink.primary*` tokens are terracotta, labels use the system font, breadcrumbs are plain words |
| Calendar card | long-form date line |
| Voice pill | `PillAction` capsule buttons, shorter title, white mic on the disc |
| Sidebar row | status first, sector trails |

## Left alone on purpose
- Video summary headings: the numbered emoji headings and terracotta topic titles are the prompt's structure.
- Purple (working) / green (done) circles: the original brief.
- `--agentbartest` "cat per agent" check now tests width, since the strip lays cats out in a row.

## How to check
`--demo <dir>` (popup, bubble; `MARGIN_LIGHT=1` for light mode), `--libdemo <dir>`, `--agentbartest <dir>`, `--pilldemo <dir>`,
`--calendardemo <dir>`, `--videodemo <dir>`, `--unittest`.
