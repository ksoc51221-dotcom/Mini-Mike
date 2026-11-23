import CoreGraphics
import Foundation

/// Package B: the <board> whiteboard. Reading, the checks, falling back to text, streaming, stripping, the prompt rule
/// and its gate, and the layout math.
extension FeatureTests {
    static func boardChecks(_ check: (String, Bool) -> Void) {
        let sample = BoardSpec.priceCeilingSample

        // A good board reads and passes.
        let spec = BoardSpec.parse(sample)
        check("board: the price ceiling sample parses and passes every check", spec != nil && BoardSpec.decode(sample)?.problems == [])
        check("board: 6 nodes, 6 arrows, 4 steps", spec?.nodes.count == 6 && spec?.edges.count == 6 && spec?.steps.count == 4)
        check("board: one key node, Shortage", spec?.nodes.filter(\.key).map(\.title) == ["Shortage"])
        check("board: short and long keys read the same",
              BoardSpec.decode(#"{"nodes":[{"id":"a","title":"A","column":0,"row":0},{"id":"b","title":"B","subtitle":"x y","column":"1","row":1,"key":true}],"edges":[{"from":"a","to":"b","label":"so","dashed":true}],"steps":[{"caption":"One.","ids":["a","b"]}]}"#)
                == BoardSpec(nodes: [.init(id: "a", title: "A", column: 0, row: 0),
                                     .init(id: "b", title: "B", subtitle: "x y", column: 1, row: 1, key: true)],
                             edges: [.init(from: "a", to: "b", label: "so", dashed: true)],
                             steps: [.init(caption: "One.", ids: ["a", "b"])]))
        check("board: the last step shows every node at full strength", spec.map { $0.inFocus(at: 3) == Set($0.nodes.map(\.id)) } == true)
        check("board: earlier steps focus only their own nodes", spec?.inFocus(at: 1) == ["qd", "qs"])
        check("board: an arrow shows once both ends are on the board",
              spec.map { s in s.firstStep(of: s.edges[2]) == 2 && s.firstStep(of: s.edges[0]) == 1 } == true)

        // Each rule rejects.
        func board(_ nodes: String, _ edges: String, _ steps: String) -> String { #"{"n":[\#(nodes)],"e":[\#(edges)],"s":[\#(steps)]}"# }
        let ab = #"{"id":"a","t":"A","r":0},{"id":"b","t":"B","r":1}"#
        let okEdge = #"{"f":"a","to":"b"}"#
        let okStep = #"{"c":"Both.","n":["a","b"]}"#
        check("board check: the minimal board passes", BoardSpec.parse(board(ab, okEdge, okStep)) != nil)
        let rejects: [(String, String)] = [
            ("an arrow to a missing node", board(ab, okEdge + #",{"f":"a","to":"zzz"}"#, okStep)),
            ("a node in no step", board(ab, okEdge, #"{"c":"Only a.","n":["a"]}"#)),
            ("a node with no arrow", board(ab + #",{"id":"c","t":"C","r":2}"#, okEdge, #"{"c":"All.","n":["a","b","c"]}"#)),
            ("more than 8 nodes", board((0..<9).map { #"{"id":"n\#($0)","t":"N","r":\#($0)}"# }.joined(separator: ","),
                                        (0..<8).map { #"{"f":"n\#($0)","to":"n\#($0 + 1)"}"# }.joined(separator: ","),
                                        (0..<3).map { i in #"{"c":"x","n":[\#((i * 3..<i * 3 + 3).map { "\"n\($0)\"" }.joined(separator: ","))]}"# }.joined(separator: ","))),
            ("more than 5 steps", board(ab, okEdge, #"{"c":"a","n":["a"]},{"c":"b","n":["b"]},{"c":"c","n":[]},{"c":"d","n":[]},{"c":"e","n":[]},{"c":"f","n":[]}"#)),
            ("a title over 4 words", board(#"{"id":"a","t":"One two three four five","r":0},{"id":"b","t":"B","r":1}"#, okEdge, okStep)),
            ("a subtitle over 6 words", board(#"{"id":"a","t":"A","sub":"one two three four five six seven","r":0},{"id":"b","t":"B","r":1}"#, okEdge, okStep)),
            ("a step adding more than 3 nodes", board(#"{"id":"a","t":"A","r":0},{"id":"b","t":"B","r":1},{"id":"c","t":"C","r":2},{"id":"d","t":"D","r":3}"#,
                                                     #"{"f":"a","to":"b"},{"f":"b","to":"c"},{"f":"c","to":"d"}"#, #"{"c":"All.","n":["a","b","c","d"]}"#)),
            ("two nodes in one place", board(#"{"id":"a","t":"A","r":0},{"id":"b","t":"B","r":0}"#, okEdge, okStep)),
            ("more than 3 columns", board(#"{"id":"a","t":"A","c":0,"r":0},{"id":"b","t":"B","c":1,"r":0},{"id":"c","t":"C","c":2,"r":0},{"id":"d","t":"D","c":3,"r":0}"#,
                                          #"{"f":"a","to":"b"},{"f":"b","to":"c"},{"f":"c","to":"d"}"#, #"{"c":"x","n":["a","b"]},{"c":"y","n":["c","d"]}"#)),
            ("two nodes with one id", board(#"{"id":"a","t":"A","r":0},{"id":"a","t":"B","r":1}"#, #"{"f":"a","to":"a"}"#, #"{"c":"x","n":["a"]}"#)),
            ("a step with no caption", board(ab, okEdge, #"{"c":"","n":["a","b"]}"#)),
            ("not JSON", "{n: oops"),
            ("no steps", #"{"n":[{"id":"a","t":"A","r":0}],"e":[],"s":[]}"#),
        ]
        for (rule, json) in rejects { check("board check rejects \(rule)", BoardSpec.parse(json) == nil) }

        // A board that fails shows as text: never raw JSON, never a broken board.
        func shown(_ pieces: [Answer.Piece]) -> String {
            pieces.map { p -> String in if case .text(let t) = p { return t } else { return "" } }.joined()
        }
        func hasBoard(_ pieces: [Answer.Piece]) -> Bool { pieces.contains { if case .board = $0 { return true } else { return false } } }
        let badJSON = Answer.pieces("Look:\n<board>{\"n\":[{\"id\":oops</board>\nThat's it.")
        check("board fallback: bad JSON draws no board", !hasBoard(badJSON))
        check("board fallback: bad JSON shows the text around it, with no JSON", shown(badJSON).contains("Look:") && shown(badJSON).contains("That's it.")
              && !shown(badJSON).contains("{") && !shown(badJSON).contains("board"))
        let broken = board(ab, #"{"f":"a","to":"ghost"}"#, #"{"c":"First the cause.","n":["a"]},{"c":"Then the effect.","n":["b"]}"#)
        let brokenPieces = Answer.pieces("Here:\n<board>\(broken)</board>")
        check("board fallback: a board that breaks a rule shows its captions as text",
              !hasBoard(brokenPieces) && shown(brokenPieces).contains("1. First the cause.") && shown(brokenPieces).contains("2. Then the effect.")
                && !shown(brokenPieces).contains("{"))
        check("board fallback: a board that never closed hides its JSON", !shown(Answer.pieces("So:\n<board>{\"n\":[{\"id\":\"a\"")).contains("{"))

        // Streaming: every prefix of a full answer, in both modes, never crashes and never shows JSON.
        let full = "A ceiling below P* changes both sides.\n<board>\(sample)</board>\nSo the price can't do its job."
        var leaked: [String] = []
        var index = full.startIndex
        while index <= full.endIndex {
            let prefix = String(full[..<index])
            for partial in [true, false] {
                let pieces = Answer.pieces(prefix, hidePartial: partial)
                let text = shown(pieces) + " " + Answer.plainText(prefix)
                if text.contains("{") || text.contains("\"n\"") || text.lowercased().contains("<board") || text.contains("</") { leaked.append(prefix) }
            }
            if index == full.endIndex { break }
            index = full.index(after: index)
        }
        check("board streaming: no prefix of \(full.count) characters shows JSON or the tag", leaked.isEmpty)
        let midway = Answer.pieces(String(full.prefix(120)), hidePartial: true)
        check("board streaming: a half-written board shows 'Drawing a board…'", midway.last == .drawingBoard)
        let finished = Answer.pieces(full, hidePartial: true)
        check("board streaming: the finished answer is text, board, text",
              finished.count == 3 && hasBoard(finished) && shown(finished).contains("So the price"))
        check("board: a board in a ``` fence leaves no empty code block",
              Answer.pieces("See:\n```json\n<board>\(sample)</board>\n```\nDone.") == [.text("See:\n"), .board(sample.trimmingCharacters(in: .whitespacesAndNewlines)), .text("\nDone.")])

        // Stripped everywhere words are used: previews, chat titles, search and export all read `Answer.plainText`.
        let plain = Answer.plainText(full)
        check("board plain text: no JSON or tag (previews, titles, search, quiz and prompt input)",
              !plain.contains("{") && !plain.lowercased().contains("<board") && !plain.contains("\"id\""))
        check("board plain text: keeps the captions, so search and follow-ups still know what it said",
              plain.contains("[a board was shown here:") && plain.contains("a shortage"))
        check("board voice: a board is never a voice clip (only <say> is read aloud)",
              !Answer.pieces(full).contains { if case .say = $0 { return true } else { return false } })
        check("board library: a chat's transcript (search and export) has no board JSON",
              { let r = ChatRecord(title: "t", sector: "Economics", app: "Safari", quote: "q", turns: [.init(question: "Why?", answer: full)]); return !r.transcript.contains("{") && r.transcript.contains("a shortage") }())

        // The local model's retry: a broken board goes to Claude once.
        check("board retry: a good board is kept", !BoardSpec.hasBrokenBoard(full))
        check("board retry: a board that breaks a rule is retried", BoardSpec.hasBrokenBoard("Here:\n<board>\(broken)</board>"))
        check("board retry: bad JSON is retried", BoardSpec.hasBrokenBoard("<board>{oops</board>"))
        check("board retry: a board that never closed is retried", BoardSpec.hasBrokenBoard("Text <board>{\"n\":["))
        check("board retry: an answer with no board is not", !BoardSpec.hasBrokenBoard("Just text about boards."))

        // The prompt rule: small, valid, and sent only when it can apply.
        let rule = Prompts.boardRule
        check("board rule: 80 tokens or fewer (\(rule.count) characters, about \(rule.count / 4) tokens)", rule.count <= 320)
        check("board rule: its own example is a valid board", Answer.pieces(rule).contains { if case .board = $0 { return true } else { return false } })
        check("board rule: says the limits, the captions rule and the facts rule",
              rule.contains("≤8 nodes") && rule.contains("5 steps") && rule.contains("Captions explain") && rule.contains("≤2 sentences outside")
                && rule.contains("Settled facts only") && rule.contains("not curves"))
        func f(_ q: String) -> Prompts.Features { Prompts.features(question: q, selection: "") }
        check("board gate: how / why / explain / steps questions get it",
              ["Why does a price ceiling cause a shortage?", "How does a bill become law?", "Explain photosynthesis",
               "What are the steps of the water cycle?", "Can you draw a diagram of this?"].allSatisfy { f($0).contains(.board) })
        check("board gate: a comparison gets the table rule, not a board",
              ["Compare mitosis and meiosis", "Contrast a monopoly with perfect competition", "Monopoly vs oligopoly"].allSatisfy {
                  !f($0).contains(.board) && f($0).contains(.table) })
        check("board gate: Visualize gets it", f(Prompts.visualize).contains(.board))
        check("board gate: plain questions, Pronounce and quizzes don't",
              !f("What does this mean?").contains(.board) && !f(Prompts.pronounce).contains(.board) && !f(Prompts.quiz).contains(.board)
                && !f("Define this word").contains(.board))
        check("board gate: never part of .all", !Prompts.Features.all.contains(.board))
        check("board gate: the rule is in the prompt only with .board",
              Prompts.system(webSearch: false, features: .board).contains(rule) && !Prompts.system(webSearch: false, features: []).contains(rule)
                && !Prompts.system(webSearch: false, features: .all).contains(rule) && !Prompts.system(webSearch: false, features: .learn).contains(rule))
        check("board gate: the quick and local models never get it",
              !Prompts.quickSystem(seeing: true, model: Settings.haikuID, features: [.board, .learn]).contains(rule) && !Prompts.localSystem.contains(rule))
        let later = Prompts.extraInstructions(for: "Why does that happen?", have: [])
        check("board gate: a later why-question carries the rule once", later?.added == .board && later?.text.contains(rule) == true)
        check("board gate: not again once the chat has it", Prompts.extraInstructions(for: "Why does that happen?", have: .board) == nil)
        check("board gate: a Learn chat already has it", Prompts.extraInstructions(for: "Why does that happen?", have: .learn) == nil)
        let learnLate = Prompts.extraInstructions(for: "ok", have: [], learn: true)
        check("board gate: turning Learn on later brings the board rule after the Learn rule",
              learnLate?.added == [.learn, .board] && learnLate.map { t in
                  (t.text.range(of: Prompts.learnRule)?.lowerBound ?? t.text.endIndex) < (t.text.range(of: rule)?.lowerBound ?? t.text.startIndex) } == true)

        // Layout: grid places become points, no overlap, and arrows go around cards, not through them.
        func throughCards(_ s: BoardSpec, _ l: BoardLayout) -> [String] {
            var hits: [String] = []
            for a in l.arrows {
                for k in 1..<40 {
                    let t = CGFloat(k) / 40, u = 1 - t
                    let x = u * u * u * a.start.x + 3 * u * u * t * a.control1.x + 3 * u * t * t * a.control2.x + t * t * t * a.end.x
                    let y = u * u * u * a.start.y + 3 * u * u * t * a.control1.y + 3 * u * t * t * a.control2.y + t * t * t * a.end.y
                    for (id, r) in l.frames where r.insetBy(dx: 1, dy: 1).contains(CGPoint(x: x, y: y)) { hits.append("\(a.from)→\(a.to) crosses \(id)") }
                }
            }
            return hits
        }
        for width: CGFloat in [348, 600] {
            if let s = spec {
                let l = BoardLayout(s, .init(width: width))
                check("board layout (\(Int(width)) pt): the sample's cards don't overlap", l.hasNoOverlap)
                check("board layout (\(Int(width)) pt): every card fits the width", l.frames.values.allSatisfy { $0.minX >= 0 && $0.maxX <= width })
                check("board layout (\(Int(width)) pt): rows flow top to bottom", (l.frames["cap"]?.maxY ?? 1) < (l.frames["qd"]?.minY ?? 0)
                      && (l.frames["qd"]?.maxY ?? 1) < (l.frames["gap"]?.minY ?? 0))
                check("board layout (\(Int(width)) pt): the lone middle card is centred", abs((l.frames["gap"]?.midX ?? 0) - width / 2) <= 1)
                check("board layout (\(Int(width)) pt): no arrow crosses a card", throughCards(s, l).isEmpty)
            }
        }
        let eight = BoardSpec.parse(board(
            #"{"id":"a","t":"A","c":1,"r":0},{"id":"b","t":"B","c":0,"r":1},{"id":"c","t":"C","c":1,"r":1},{"id":"d","t":"D","c":2,"r":1},{"id":"e","t":"E","c":0,"r":2},{"id":"f","t":"F","c":2,"r":2},{"id":"g","t":"G","sub":"x","c":1,"r":3},{"id":"h","t":"H","c":0,"r":4}"#,
            #"{"f":"a","to":"b"},{"f":"a","to":"c"},{"f":"a","to":"d"},{"f":"b","to":"e"},{"f":"d","to":"f"},{"f":"e","to":"g"},{"f":"f","to":"g"},{"f":"c","to":"g"},{"f":"g","to":"h"}"#,
            #"{"c":"1","n":["a"]},{"c":"2","n":["b","c","d"]},{"c":"3","n":["e","f"]},{"c":"4","n":["g"]},{"c":"5","n":["h"]}"#))
        check("board layout: an 8-node, 5-step board passes", eight != nil)
        if let eight {
            for width: CGFloat in [300, 348, 600] {
                let l = BoardLayout(eight, .init(width: width))
                check("board layout (\(Int(width)) pt): 8 cards, 3 to a row, don't overlap and fit", l.frames.count == 8 && l.hasNoOverlap
                      && l.frames.values.allSatisfy { $0.minX >= 0 && $0.maxX <= width && $0.width >= 80 })
                check("board layout (\(Int(width)) pt): the 8-node board's arrows go around cards", throughCards(eight, l).isEmpty)
                check("board layout (\(Int(width)) pt): the height grows with the rows", abs(l.size.height - (2 + 5 * l.nodeSize.height + 4 * 30 + 2)) < 0.5
                      && l.nodeSize.height == (l.nodeSize.width < 140 ? 78 : 52))
            }
        }
        check("board layout: a grid with gaps is compacted (columns 0 and 5, rows 0 and 9)",
              BoardSpec.parse(board(#"{"id":"a","t":"A","c":0,"r":0},{"id":"b","t":"B","c":5,"r":9}"#, okEdge, okStep))
                .map { BoardLayout($0, .init(width: 348)).size.height == 2 + 2 * 38 + 30 + 2 } == true)

        if let s = spec {
            let l = BoardLayout(s, .init(width: 348))
            check("board layout: the board grows one step at a time and ends at its full height",
                  l.height(showing: ["cap"]) < l.height(showing: ["cap", "qd", "qs"]) && l.height(showing: Set(s.nodes.map(\.id))) == l.size.height)
        }
        // Hard arrows: each is either drawn cleanly (inside the board, through no card) or the board falls back to text.
        let hard: [(String, String, Bool?)] = [
            ("a jump down column 0 over a card, with a card beside it",
             board(#"{"id":"a","t":"A","c":0,"r":0},{"id":"m","t":"M","c":0,"r":1},{"id":"x","t":"X","c":1,"r":1},{"id":"d","t":"D","c":0,"r":2}"#,
                   #"{"f":"a","to":"m"},{"f":"m","to":"d"},{"f":"a","to":"d"},{"f":"a","to":"x"}"#,
                   #"{"c":"1","n":["a"]},{"c":"2","n":["m","x"]},{"c":"3","n":["d"]}"#), true),
            ("a jump down the right column over a card",
             board(#"{"id":"a","t":"A","c":1,"r":0},{"id":"m","t":"M","c":1,"r":1},{"id":"x","t":"X","c":0,"r":1},{"id":"d","t":"D","c":1,"r":2}"#,
                   #"{"f":"a","to":"m"},{"f":"m","to":"d"},{"f":"a","to":"d"},{"f":"a","to":"x"}"#,
                   #"{"c":"1","n":["a"]},{"c":"2","n":["m","x"]},{"c":"3","n":["d"]}"#), true),
            ("a same-row arrow over the middle card",
             board(#"{"id":"a","t":"A","c":0,"r":0},{"id":"b","t":"B","c":1,"r":0},{"id":"c","t":"C","c":2,"r":0}"#,
                   #"{"f":"a","to":"b"},{"f":"b","to":"c"},{"f":"a","to":"c"}"#, #"{"c":"1","n":["a","b","c"]}"#), false),
            ("an upward arrow", board(ab, okEdge + #",{"f":"b","to":"a","d":1}"#, okStep), true),
            ("a diagonal across a card",
             board(#"{"id":"a","t":"A","c":0,"r":0},{"id":"m","t":"M","c":1,"r":1},{"id":"d","t":"D","c":2,"r":2}"#,
                   #"{"f":"a","to":"m"},{"f":"m","to":"d"},{"f":"a","to":"d"}"#, #"{"c":"1","n":["a"]},{"c":"2","n":["m","d"]}"#), nil),
        ]
        for (name, json, expectDrawn) in hard {
            let drawn = BoardSpec.parse(json)
            if let expectDrawn { check("board routing: \(name) is \(expectDrawn ? "drawn" : "sent back as text")", (drawn != nil) == expectDrawn) }
            if let drawn {
                for width: CGFloat in [300, 348, 600] {
                    let l = BoardLayout(drawn, .init(width: width))
                    check("board routing (\(Int(width)) pt): \(name) stays inside and crosses no card", l.crossings.isEmpty && throughCards(drawn, l).isEmpty)
                }
            } else {
                check("board routing: \(name) shows its captions instead", !Answer.plainText("<board>\(json)</board>").contains("{"))
            }
        }

        check("board click: a card asks to explain that step", BoardView.followUpQuestion(for: "Shortage") == "Explain this step more: Shortage")
    }
}
