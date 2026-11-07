# Margin MCP server

`Margin --mcp` serves your mini chats to Claude Code and the Claude desktop app over MCP (stdio). Local-only (no network, no Claude calls) and read-only (it never writes, moves or deletes anything in your Library). Binned items are not served.

## Tools
- `list_chats` {sector?, query?, limit=20}: id, title, sector, app, date, turns, newest first.
- `search_library` {query, limit=10}: matches in titles, quotes, questions, answers and notes, with short snippets.
- `get_chat` {id}: the full chat as Markdown (capped at ~20k characters).
- `list_sectors`: sector names with counts.
- `get_note` {id}.

## Claude Code
```
claude mcp add margin -- ~/Applications/Margin.app/Contents/MacOS/Margin --mcp
```
Add `-s user` to make it available in every project:
```
claude mcp add -s user margin -- ~/Applications/Margin.app/Contents/MacOS/Margin --mcp
```

## Claude desktop
Edit `~/Library/Application Support/Claude/claude_desktop_config.json` (use the absolute path) and restart the app:
```json
{
  "mcpServers": {
    "margin": {
      "command": "/Users/YOU/Applications/Margin.app/Contents/MacOS/Margin",
      "args": ["--mcp"]
    }
  }
}
```

The server reads the same Library folder the app uses and starts no menu-bar icon, hotkeys or watchers. Logs go to stderr; stdout carries only protocol messages.
