import Foundation

/// `Margin --mcp`: a local, read-only MCP server (JSON-RPC 2.0, newline-delimited, over stdio) that lets Claude Code / Claude desktop
/// pull context from the Library's mini chats. It reads the JSON files directly and never writes, moves or deletes anything.
final class MCPServer {
    static let version = "1.0"
    static let supported = ["2025-06-18", "2025-03-26", "2024-11-05"]

    let directory: URL
    init(directory: URL? = nil) {
        self.directory = directory ?? Library.overrideDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Margin", isDirectory: true).appendingPathComponent("Library", isDirectory: true)
    }

    /// Blocks reading stdin until it closes, then returns. Only protocol messages go to stdout.
    static func runStdio() -> Never {
        let server = MCPServer()
        while let line = readLine(strippingNewline: true) {
            if let reply = server.handle(line: line) {
                FileHandle.standardOutput.write(Data((reply + "\n").utf8))
            }
        }
        exit(0)
    }

    // MARK: Protocol

    /// One incoming line -> the reply line (nil for notifications).
    func handle(line: String) -> String? {
        guard let data = line.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
        }
        guard let method = obj["method"] as? String else { return nil } // a response or junk: ignore
        let id = obj["id"]
        if id == nil { return nil } // notification (notifications/initialized etc.)
        let params = obj["params"] as? [String: Any] ?? [:]
        func ok(_ result: [String: Any]) -> String? { encode(["jsonrpc": "2.0", "id": id!, "result": result]) }
        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String ?? ""
            return ok(["protocolVersion": Self.supported.contains(asked) ? asked : Self.supported[0],
                       "capabilities": ["tools": [String: Any]()],
                       "serverInfo": ["name": "margin", "version": Self.version]])
        case "ping":
            return ok([:])
        case "tools/list":
            return ok(["tools": Self.toolDefs])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            guard Self.toolDefs.contains(where: { $0["name"] as? String == name }) else {
                return encode(["jsonrpc": "2.0", "id": id!, "error": ["code": -32602, "message": "Unknown tool: \(name)"]])
            }
            let (text, isError) = call(name, args)
            return ok(["content": [["type": "text", "text": text]], "isError": isError])
        default:
            return encode(["jsonrpc": "2.0", "id": id!, "error": ["code": -32601, "message": "Method not found: \(method)"]])
        }
    }

    private func encode(_ obj: [String: Any]) -> String? {
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    private static func tool(_ name: String, _ desc: String, _ props: [String: Any] = [:], required: [String] = []) -> [String: Any] {
        ["name": name, "description": desc,
         "inputSchema": ["type": "object", "properties": props, "required": required],
         "annotations": ["readOnlyHint": true, "openWorldHint": false]]
    }

    static let toolDefs: [[String: Any]] = [
        tool("list_chats", "List the user's Margin mini chats (highlight-to-ask conversations), newest first. Returns id, title, sector, app, date, turns.",
             ["sector": ["type": "string", "description": "Only this sector"], "query": ["type": "string", "description": "Words that must appear in the title/quote/Q&A"],
              "limit": ["type": "integer", "description": "Default 20"]]),
        tool("search_library", "Search chat titles, quotes, questions, answers and saved notes. Returns short snippets with ids.",
             ["query": ["type": "string"], "limit": ["type": "integer", "description": "Default 10"]], required: ["query"]),
        tool("get_chat", "Get one full chat as Markdown (title, sector, date, source app, quote, every Q/A turn).",
             ["id": ["type": "string"]], required: ["id"]),
        tool("list_sectors", "List sector names with chat counts."),
        tool("get_note", "Get one saved note by id.", ["id": ["type": "string"]], required: ["id"]),
    ]

    // MARK: Data (read-only)

    private func read<T: Decodable>(_ sub: String, _ type: T.Type) -> [T] {
        Library.readRecords(in: directory.appendingPathComponent(sub, isDirectory: true), type)
    }
    private func chats() -> [ChatRecord] { read("chats", ChatRecord.self).sorted { $0.updated > $1.updated } }
    private func notes() -> [Note] { read("notes", Note.self).sorted { $0.created > $1.created } }

    private static let day: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()
    private func date(_ d: Date) -> String { Self.day.string(from: d) }
    private func plain(_ s: String) -> String { Answer.plainText(s).replacingOccurrences(of: "\n", with: " ") }
    private func clip(_ s: String, _ n: Int = 200) -> String { s.count > n ? String(s.prefix(n)) + "…" : s }

    private func haystack(_ c: ChatRecord) -> String {
        ([c.title, c.sector, c.quote] + c.turns.flatMap { [$0.question, Answer.plainText($0.answer)] }).joined(separator: "\n")
    }
    private func words(_ q: String) -> [String] { q.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init) }
    /// Window of text around the first hit, so the snippet shows why it matched.
    private func snippet(_ text: String, _ ws: [String]) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        // Search the original string, so the offset is right even where lowercasing changes length (non-ASCII).
        guard let r = ws.lazy.compactMap({ flat.range(of: $0, options: [.caseInsensitive]) }).first else { return clip(flat) }
        let s = flat.index(r.lowerBound, offsetBy: -60, limitedBy: flat.startIndex) ?? flat.startIndex
        return (s > flat.startIndex ? "…" : "") + clip(String(flat[s...]), 200)
    }

    private func call(_ name: String, _ a: [String: Any]) -> (String, Bool) {
        // Clamp as a Double first: Int(1e300) or Int(.nan) would crash the server.
        func int(_ k: String, _ def: Int) -> Int {
            if let i = a[k] as? Int { return max(1, min(100, i)) }
            guard let d = a[k] as? Double, d.isFinite else { return def }
            return Int(max(1, min(100, d)))
        }
        switch name {
        case "list_chats":
            let sector = (a["sector"] as? String)?.lowercased()
            let ws = words(a["query"] as? String ?? "")
            let hits = chats().filter { c in
                (sector == nil || sector!.isEmpty || c.sector.lowercased() == sector!)
                    && (ws.isEmpty || { let h = haystack(c).lowercased(); return ws.allSatisfy { h.contains($0) } }())
            }.prefix(int("limit", 20))
            if hits.isEmpty { return ("No chats found.", false) }
            return (hits.map { "\($0.id.uuidString) | \(clip($0.title, 80)) | \($0.sector) | \($0.app) | \(date($0.updated)) | \($0.turns.count) turns" }
                .joined(separator: "\n"), false)
        case "search_library":
            let ws = words(a["query"] as? String ?? "")
            guard !ws.isEmpty else { return ("query is required", true) }
            let limit = int("limit", 10)
            var out: [String] = []
            for c in chats() where out.count < limit {
                let h = haystack(c), lower = h.lowercased()
                if ws.allSatisfy({ lower.contains($0) }) {
                    out.append("chat \(c.id.uuidString) | \(clip(c.title, 80)) | \(c.sector) | \(date(c.updated))\n  \(snippet(h, ws))")
                }
            }
            for n in notes() where out.count < limit {
                let h = [n.title, n.quote, n.question, Answer.plainText(n.body)].joined(separator: "\n"), lower = h.lowercased()
                if ws.allSatisfy({ lower.contains($0) }) {
                    out.append("note \(n.id.uuidString) | \(clip(n.title, 80)) | \(n.sector) | \(date(n.created))\n  \(snippet(h, ws))")
                }
            }
            return (out.isEmpty ? "No matches." : out.joined(separator: "\n"), false)
        case "get_chat":
            guard let id = (a["id"] as? String).flatMap({ UUID(uuidString: $0) }), let c = chats().first(where: { $0.id == id }) else {
                return ("No chat with that id.", true)
            }
            var md = "# \(c.title)\n\n- Sector: \(c.sector)\n- Date: \(date(c.created))\n- Source app: \(c.app)\n"
            if !c.quote.isEmpty { md += "\n> " + c.quote.replacingOccurrences(of: "\n", with: "\n> ") + "\n" }
            for (i, t) in c.turns.enumerated() {
                md += "\n## Q\(i + 1): \(t.question)\n\n\(Answer.plainText(t.answer))\n"
            }
            let cap = 20_000
            if md.count > cap { md = String(md.prefix(cap)) + "\n\n[truncated: chat is \(md.count) characters, showing the first \(cap)]" }
            return (md, false)
        case "list_sectors":
            var counts: [String: Int] = [:]
            for c in chats() { counts[c.sector, default: 0] += 1 }
            if counts.isEmpty { return ("No chats yet.", false) }
            return (counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n"), false)
        case "get_note":
            guard let id = (a["id"] as? String).flatMap({ UUID(uuidString: $0) }), let n = notes().first(where: { $0.id == id }) else {
                return ("No note with that id.", true)
            }
            var md = "# \(n.title)\n\n- Sector: \(n.sector)\n- Date: \(date(n.created))\n- Source app: \(n.app)\n"
            if !n.quote.isEmpty { md += "\n> " + n.quote.replacingOccurrences(of: "\n", with: "\n> ") + "\n" }
            if !n.question.isEmpty { md += "\n**\(n.question)**\n" }
            md += "\n\(Answer.plainText(n.body))\n"
            return (String(md.prefix(20_000)), false)
        default:
            return ("Unknown tool", true)
        }
    }

    // MARK: Self-test (run from --unittest)

    static func selfTest(_ check: (String, Bool) -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("margin-mcp-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let lib = Library(directory: dir)
        let big = ChatRecord(title: "Parabola direction", sector: "Math", app: "Safari", quote: "y = ax^2",
                             turns: [.init(question: "Why does it open up?", answer: String(repeating: "Because a is positive. ", count: 1500))])
        lib.save(big)
        lib.save(ChatRecord(title: "Russian lock", sector: "Language", app: "Preview", quote: "замок", turns: [.init(question: "Which?", answer: "Stress decides.")]))
        let s = MCPServer(directory: dir)
        for _ in 0..<100 where s.chats().count < 2 { Thread.sleep(forTimeInterval: 0.05) } // Library writes on a background queue
        func rpc(_ json: String) -> [String: Any]? {
            s.handle(line: json).flatMap { $0.data(using: .utf8) }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
        func text(_ name: String, _ args: String) -> String {
            let r = rpc(#"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"\#(name)","arguments":\#(args)}}"#)
            return ((r?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        }
        let ini = rpc(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#)?["result"] as? [String: Any]
        check("mcp: initialize echoes protocol and names server", ini?["protocolVersion"] as? String == "2025-06-18"
              && (ini?["serverInfo"] as? [String: Any])?["name"] as? String == "margin")
        check("mcp: notifications get no reply", s.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        let tools = ((rpc(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)?["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
        check("mcp: tools/list has the 5 tools", Set(tools.compactMap { $0["name"] as? String }) == ["list_chats", "search_library", "get_chat", "list_sectors", "get_note"])
        check("mcp: list_chats newest first with turn count", text("list_chats", "{}").contains("Parabola direction") && text("list_chats", "{}").contains("1 turns"))
        check("mcp: a huge or non-finite limit is clamped, not a crash", text("list_chats", #"{"limit":1e300}"#).contains("Parabola")
              && text("list_chats", #"{"limit":-1e300}"#).contains("turns"))
        check("mcp: list_chats sector filter", text("list_chats", #"{"sector":"language"}"#).contains("Russian") && !text("list_chats", #"{"sector":"language"}"#).contains("Parabola"))
        check("mcp: search_library finds answer text with a short snippet", { let t = text("search_library", #"{"query":"stress"}"#); return t.contains("Russian lock") && t.count < 400 }())
        check("mcp: list_sectors counts", text("list_sectors", "{}").contains("Math: 1"))
        let full = text("get_chat", #"{"id":"\#(big.id.uuidString)"}"#)
        check("mcp: get_chat is Markdown, capped at ~20k with a note", full.hasPrefix("# Parabola direction") && full.contains("truncated") && full.count < 20_400)
        check("mcp: unknown method errors, ping works", rpc(#"{"jsonrpc":"2.0","id":3,"method":"nope"}"#)?["error"] != nil && rpc(#"{"jsonrpc":"2.0","id":4,"method":"ping"}"#)?["result"] != nil)
    }
}
