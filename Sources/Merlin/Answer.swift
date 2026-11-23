import Foundation

/// Splits Claude's answer into what the chat shows: text, voice clips (<say …>…</say>), graphs
/// (<graph>{json}</graph>) and quizzes (<quiz>{json}</quiz>). A <meta title="…" sector="…"/> at the end of the
/// first answer is never shown: it names the chat and files it under a sector.
enum Answer {
    enum Piece: Equatable {
        case text(String)
        case say(SayRequest)
        /// The JSON inside a <graph> tag.
        case graph(String)
        /// A <graph> that's still streaming in, shown as "Drawing…".
        case drawing
        /// The JSON inside a <quiz> tag.
        case quiz(String)
        /// A <quiz> that's still streaming in.
        case writingQuiz
        /// The JSON inside an <event> tag: a calendar event for you to check and add.
        case event(String)
        /// The JSON inside a <board> tag that passed `BoardSpec`'s checks (a board that fails becomes text).
        case board(String)
        /// A <board> that's still streaming in.
        case drawingBoard
        /// The JSON inside a <scene> tag that `SceneSpec` could read (one it can't becomes text).
        case scene(String)
        /// A <scene> that's still streaming in.
        case buildingScene
    }

    /// What Claude says a chat is about, and which sector it belongs in.
    struct Meta: Equatable {
        var title: String
        var sector: String
    }

    private static let metaTag = try! NSRegularExpression(pattern: #"<meta\b([^>]*?)/?>"#, options: [.caseInsensitive])

    /// The chat's name and sector, if the answer carries them.
    static func meta(in answer: String) -> Meta? {
        let ns = answer as NSString
        // The last tag with a title is Merlin's own; an HTML <meta charset…> in the answer is not.
        guard let m = ownMetaTags(in: answer).last else { return nil }
        let attrs = attributes(ns.substring(with: m.range(at: 1)))
        guard var title = attrs["title"]?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: "\"'«»“”"))
        if title.count > 60 { title = String(title.prefix(60)).trimmingCharacters(in: .whitespaces) + "…" }
        return Meta(title: title, sector: attrs["sector"] ?? "")
    }

    /// The <meta> tags that carry a title: the ones Merlin asks Claude for. Others are part of the answer (HTML code).
    private static func ownMetaTags(in answer: String) -> [NSTextCheckingResult] {
        let ns = answer as NSString
        return metaTag.matches(in: answer, range: NSRange(location: 0, length: ns.length)).filter {
            ns.substring(with: $0.range(at: 1)).range(of: #"\b(?:title|sector)\s*="#, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    /// The answer without its <meta> tag (and the blank space it leaves).
    static func withoutMeta(_ answer: String) -> String {
        let buffer = NSMutableString(string: answer)
        for m in ownMetaTags(in: answer).reversed() { buffer.replaceCharacters(in: m.range, with: "") }
        let cleaned = buffer as String
        return cleaned == answer ? answer : cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let tag = try! NSRegularExpression(pattern: #"<(say|graph|quiz|event|board|scene)\b([^>]*)>(.*?)</\1\s*>"#,
                                                      options: [.dotMatchesLineSeparators, .caseInsensitive])
    private static let attribute = try! NSRegularExpression(pattern: #"(\w+)\s*=\s*"([^"]*)""#)

    /// With `hidePartial`, a tag that's still streaming in is hidden instead of flashing raw markup.
    static func pieces(_ answer: String, hidePartial: Bool = false) -> [Piece] {
        let answer = withoutMeta(answer)
        let ns = answer as NSString
        var pieces: [Piece] = []
        var cursor = 0
        for match in tag.matches(in: answer, range: NSRange(location: 0, length: ns.length)) {
            appendText(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)), to: &pieces)
            let kind = ns.substring(with: match.range(at: 1)).lowercased()
            let body = ns.substring(with: match.range(at: 3)).trimmingCharacters(in: .whitespacesAndNewlines)
            if kind == "graph" {
                if !body.isEmpty { pieces.append(.graph(body)) }
            } else if kind == "quiz" {
                if !body.isEmpty { pieces.append(.quiz(body)) }
            } else if kind == "event" {
                if !body.isEmpty { pieces.append(.event(body)) }
            } else if kind == "board" {
                // Only a board that passes every check is drawn; otherwise its captions stand in as text.
                if BoardSpec.parse(body) != nil {
                    pieces.append(.board(body))
                } else {
                    appendText("\n" + BoardSpec.fallbackText(body) + "\n", to: &pieces)
                }
            } else if kind == "scene" {
                // A scene with nothing drawable (bad JSON, no known part) shows its caption and labels as text.
                if SceneSpec.parse(body) != nil {
                    pieces.append(.scene(body))
                } else {
                    appendText("\n" + SceneSpec.fallbackText(body) + "\n", to: &pieces)
                }
            } else if !body.isEmpty {
                let attrs = attributes(ns.substring(with: match.range(at: 2)))
                let lang = attrs["lang"] ?? (body.unicodeScalars.contains { (0x400...0x4FF).contains($0.value) } ? "ru-RU" : "en-US")
                pieces.append(.say(SayRequest(text: body, lang: lang, ipa: attrs["ipa"])))
            }
            cursor = match.range.location + match.range.length
        }
        var tail = ns.substring(from: cursor)
        var unfinished: Piece?
        if hidePartial {
            // Any opening tag left in the tail is unfinished.
            let opens: [(Range<String.Index>, Piece?)] = [
                ("<say", nil), ("<graph", .drawing), ("<quiz", .writingQuiz), ("<meta", nil), ("<board", .drawingBoard), ("<scene", .buildingScene),
            ].compactMap { name, piece in
                tail.range(of: name, options: [.backwards, .caseInsensitive]).map { ($0, piece) }
            }
            if let open = opens.max(by: { $0.0.lowerBound < $1.0.lowerBound }) {
                unfinished = open.1
                tail = String(tail[..<open.0.lowerBound])
            }
            for prefix in ["<grap", "<gra", "<gr", "<g", "<sa", "<s", "<quiz", "<qui", "<qu", "<q", "<meta", "<met", "<me", "<m",
                           "<boar", "<boa", "<bo", "<b", "<scen", "<sce", "<sc", "<"]
            where tail.hasSuffix(prefix) {
                tail.removeLast(prefix.count)
                break
            }
        } else if let open = ["<board", "<scene"].compactMap({ tail.range(of: $0, options: [.backwards, .caseInsensitive]) })
                    .min(by: { $0.lowerBound < $1.lowerBound }) {
            // A board or scene that never closed (a stopped or failed answer): its JSON is never shown.
            tail = String(tail[..<open.lowerBound])
        }
        appendText(tail, to: &pieces)
        if let unfinished { pieces.append(unfinished) }
        return withoutFences(pieces)
    }

    /// The answer as plain words, for putting back into a prompt: a voice clip becomes its text, a graph a note.
    static func plainText(_ answer: String) -> String {
        pieces(answer).compactMap { piece -> String? in
            switch piece {
            // Key-word marks are for the screen only; a table becomes readable lines ("Term: … Definition: …"), never pipes.
            case .text(let t): return Highlights.strip(MarkdownTable.plainText(t)).trimmingCharacters(in: .whitespacesAndNewlines)
            case .say(let request): return "“\(request.text)”"
            case .graph: return "[a graph was shown here]"
            case .quiz: return "[a quiz was shown here]"
            case .event: return "[a calendar event was shown here]"
            case .board(let json):
                let words = BoardSpec.parse(json)?.plainText ?? ""
                return words.isEmpty ? "[a board was shown here]" : "[a board was shown here: \(words)]"
            case .scene(let json):
                let words = SceneSpec.parse(json)?.plainText ?? ""
                return words.isEmpty ? "[a 3D scene was shown here]" : "[a 3D scene was shown here: \(words)]"
            case .drawing, .writingQuiz, .drawingBoard, .buildingScene: return nil
            }
        }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func appendText(_ s: String, to pieces: inout [Piece]) {
        if !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { pieces.append(.text(s)) }
    }

    /// Claude sometimes wraps a <graph> in a ``` fence; drop the fence so no empty code block shows.
    private static func withoutFences(_ pieces: [Piece]) -> [Piece] {
        func isGraph(_ j: Int) -> Bool {
            guard pieces.indices.contains(j) else { return false }
            switch pieces[j] {
            case .graph, .drawing, .quiz, .writingQuiz, .event, .board, .drawingBoard, .scene, .buildingScene: return true
            case .text, .say: return false
            }
        }
        var out: [Piece] = []
        for (i, piece) in pieces.enumerated() {
            guard case .text(var t) = piece else {
                out.append(piece)
                continue
            }
            if isGraph(i + 1), let fence = t.range(of: #"```[A-Za-z]*\s*$"#, options: .regularExpression) {
                t.removeSubrange(fence)
            }
            if isGraph(i - 1), let fence = t.range(of: #"^\s*```"#, options: .regularExpression) {
                t.removeSubrange(fence)
            }
            appendText(t, to: &out)
        }
        return out
    }

    private static func attributes(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        let ns = s as NSString
        for m in attribute.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out[ns.substring(with: m.range(at: 1)).lowercased()] = ns.substring(with: m.range(at: 2))
        }
        return out
    }
}
