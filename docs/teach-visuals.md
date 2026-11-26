# Teach visuals: diagrams and Manim videos

Status (2026-11-26): built and tested headless. Not committed, not installed. Not yet seen on a real screen.

A `Visual` button under a finished answer opens a menu: `Diagram` (static SVG) or `Animate` (Manim mp4).
Merlin's choices: one icon-only `Visual` menu (row spacing 10 pt when it shows, so the row fits at 380 pt), full chat width, dark 3Blue1Brown look.

## How it works

- **Trigger:** only the button. Never automatic. The cheap `Visualize` chip (`<graph>`, `<board>`, `<scene>`) stays.
- **Model call:** a separate one-shot `claude -p` (`ClaudeOneShot`), Sonnet, `--setting-sources ""`, `--tools ""`.
  The installed skills are NOT loaded (that would add about 14k tokens per click and the user's global setup).
  Instead Merlin sends a short brief distilled from them: `Sources/Merlin/TeachBriefs.swift`.
  Effort: `low` for a diagram, `medium` for a video.
- **Measured cost per click** (live runs, physics and economics):
  - Diagram: about 1.5k output tokens, about $0.02, about 10 s.
  - Video: about 3.5k output tokens, about $0.05 per model call, 30-90 s with the render.
    A failed render spends one fix call (about $0.10 in total), then it stops.
  - Every call is logged in `usage.jsonl` (`why: "diagram"` / `"animate"`).
- **Diagram:** the model returns one ```svg block. Merlin removes scripts, `foreignObject`, `on…=` attributes and
  external links, then saves the file. Shown in a `WKWebView` with JavaScript off and all network blocked by a
  content rule list. If the rule list fails, the view loads nothing.
- **Video:** the model returns one ```python block (`class TeachScene`). Merlin checks it (`TeachVisuals.checkScene`:
  allowed imports only, denylist such as `open`, `exec`, `getattr`, `subprocess`, `os.`, `ctypes`). Merlin, not the
  model, runs `manim -ql` with fixed arguments, a 120 s timeout and Cancel, inside `sandbox-exec`:
  - no network, no Launch Services, no Apple Events;
  - no reads in the home folder except the uv install, `~/.local/bin`, `~/Library/Fonts` and the job folder;
  - no writes outside the job folder and temp folders;
  - no programs outside uv, `/opt/homebrew` and `/usr/local`.
  The string check is a lint. The sandbox is the real boundary.
- **No LaTeX:** the brief forbids `MathTex`/`Tex` unless `latex` is on PATH. Text uses `Helvetica Neue`.
- **Manim missing:** the menu shows "Manim is not installed" and `uv tool install manim`.
- **Files:** `<Library>/Visuals/<chat-id>/<n>.svg|.py|.mp4`. The answer stores `<visual kind="…" file="…"/>`.
  `Answer.plainText` drops the tag, so it never reaches copy, export, search, MCP or the history sent to Claude.
  Moving a chat to the Bin keeps the folder; permanent delete removes it.

## Files

- New: `TeachVisuals.swift` (job flow, checks, sandbox), `TeachBriefs.swift`, `TeachVisualViews.swift`,
  `TeachVisualTests.swift`.
- Changed: `Answer.swift`, `AskView.swift`, `AskPanel.swift`, `ClaudeOneShot.swift`, `Library.swift`,
  `LibraryWindow.swift`, `VoiceMessageView.swift`, `FeatureTests.swift`, `main.swift`.

## Test flags (headless, no window)

- `MERLIN_HEADLESS_TESTS=1 .build/debug/Merlin --unittest`: all unit tests (fake model, fake renderer).
- `--visualrendertest`: one real sandboxed render of a fixed scene.
- `--visualsandboxtest`: a scene tries five escapes (read library, read `~/.ssh`, write outside, socket, `open`).
- `--visuallive <dir>`: real model calls (costs about $0.10), one diagram and one video. `VISUAL_TOPIC=econ`
  switches the question to supply and demand. Prints tokens and cost.
- `--visualshots <svg> <dir>`: offscreen PNGs of the chat with a diagram card.

## Known limits

- Not seen on a real screen yet: menu, web view, player, larger window, reload from history.
- Manim layout is weaker than diagrams: labels can still overlap sometimes.
- A failed attempt leaves its `.py` file in the folder.
