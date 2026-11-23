import AppKit
import Foundation
import SwiftUI

extension FeatureTests {
    /// Key-word highlights (`==like this==`): reading the marks, stripping them, the renderer's runs, and every place that
    /// takes answer text without them.
    static func highlightChecks(_ check: (String, Bool) -> Void) {
        func split(_ s: String) -> String {
            Highlights.split(s).map { ($0.marked ? "[" : "") + $0.text + ($0.marked ? "]" : "") }.joined()
        }
        /// What the answer view works from: the line through encode, markdown and the cut at the marks.
        func runs(_ s: String, streaming: Bool = false) -> [(text: String, marked: Bool, bold: Bool)] {
            var inside = false
            let a = MarkdownText.inline(Highlights.encode(s, streaming: streaming))
            return MarkdownText.highlightRuns(a, inside: &inside).flatMap { part in
                part.text.runs.map { run in
                    (String(part.text[run.range].characters), part.marked, run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true)
                }
            }
        }
        func shown(_ s: String, streaming: Bool = false) -> String { runs(s, streaming: streaming).map(\.text).joined() }
        func markedText(_ s: String) -> String { runs(s).filter(\.marked).map(\.text).joined(separator: "|") }

        // Reading marks.
        check("highlight: a simple mark", split("The ==derivative== is a rate.") == "The [derivative] is a rate.")
        check("highlight: strip drops just the markers", Highlights.strip("The ==derivative== is a rate.") == "The derivative is a rate.")
        check("highlight: several marks, a phrase", split("==Newton's second law== gives ==F = ma==.") == "[Newton's second law] gives [F = ma].")
        check("highlight: the view's runs hold the marked word and no marker", runs("The ==derivative== is a rate.").map(\.text) == ["The ", "derivative", " is a rate."]
              && runs("The ==derivative== is a rate.").map(\.marked) == [false, true, false])
        check("highlight: no marker characters left in what is shown", !shown("a ==b== c ==d==").contains(Highlights.open) && !shown("a ==b== c ==d==").contains(Highlights.close)
              && !shown("a ==b== c ==d==").contains("=="))

        // With bold.
        let boldInside = runs("The **==key idea==** here")
        check("highlight: **==x==** is bold and marked, with no ** or == on screen",
              boldInside.map(\.text).joined() == "The key idea here" && boldInside.contains { $0.text == "key idea" && $0.marked && $0.bold })
        let boldOutside = runs("The ==**key idea**== here")
        check("highlight: ==**x**== is bold and marked", boldOutside.map(\.text).joined() == "The key idea here" && boldOutside.contains { $0.text == "key idea" && $0.marked && $0.bold })
        let partBold = runs("It is **very ==important== indeed**")
        check("highlight: a mark inside a longer bold phrase keeps the rest bold",
              partBold.map(\.text).joined() == "It is very important indeed" && partBold.filter(\.marked).map(\.text) == ["important"] && partBold.filter { $0.text.contains("very") || $0.text.contains("indeed") }.allSatisfy(\.bold))

        // In a list and numbered steps.
        let items = MarkdownText.lines("- Use ==the chain rule== here\n2. Then ==differentiate== again")
        check("highlight: marks inside list items and numbered steps",
              items.count == 2 && markedText(items[0].text) == "the chain rule" && markedText(items[1].text) == "differentiate" && items[0].marker == "•" && items[1].marker == "2.")

        // Beside maths.
        let line = "==Newton's law== $F=ma$ and ==v = u + at== so $a = F/m$"
        check("highlight: beside inline maths the words are marked and the equation untouched",
              markedText("==Newton's law== $F=ma$") == "Newton's law" && Highlights.strip(line) == "Newton's law $F=ma$ and v = u + at so $a = F/m$")
        let pieces = MathRender.inlinePieces(Highlights.encode(line))
        let equations = pieces.compactMap { p -> String? in if case .inline(let l) = p { return l }; return nil }
        check("highlight: the typesetter still finds the equations, markers aside", equations == ["F=ma", "a = F/m"]
              && pieces.allSatisfy { p in if case .text(let t) = p { return !t.contains("==") }; return true })
        check("highlight: a mark with an equals sign inside is read whole", Highlights.split("==v = u + at==").map(\.text) == ["v = u + at"] && Highlights.split("==v = u + at==")[0].marked)
        check("highlight: a mark can wrap an equation", Highlights.strip("==the $F=ma$ law== holds") == "the $F=ma$ law holds" && Highlights.hasMarks("==the $F=ma$ law== holds"))
        check("highlight: a mark with plain-text maths in it comes out whole",
              shown("The ==speed v = u + at== grows") == "The speed v = u + at grows")

        // Streaming: a half-arrived mark never shows ==.
        check("highlight: streaming, an open mark loses its markers until it closes", shown("so the ==key", streaming: true) == "so the key" && shown("so the ==key idea", streaming: true) == "so the key idea")
        check("highlight: streaming, a lone = or == at the end is dropped", shown("so the ==", streaming: true) == "so the " && shown("so the =", streaming: true) == "so the ")
        check("highlight: streaming, closed marks stay marked while a later one is open",
              runs("a ==b== and ==cl", streaming: true).filter(\.marked).map(\.text) == ["b"] && shown("a ==b== and ==cl", streaming: true) == "a b and cl")
        check("highlight: streaming, the closing marker arriving makes it a mark", runs("so the ==key==", streaming: true).filter(\.marked).map(\.text) == ["key"]
              && shown("so the ==key=", streaming: true) == "so the key")
        check("highlight: streaming inside bold, once the soft closer is added",
              shown(MarkdownText.softenPartial("it is **==key"), streaming: true) == "it is key")
        check("highlight: a finished answer drops a never-closed opener, display and strip", shown("so the ==key") == "so the key" && Highlights.strip("so the ==key idea\nnext") == "so the key idea\nnext"
              && !Highlights.hasMarks("so the ==key"))
        check("highlight: a dangling opener beside a real mark", Highlights.strip("==one== and ==two") == "one and two" && split("==one== and ==two") == "[one] and two")
        check("highlight: a dangling opener on an earlier line, the next line's mark still works", Highlights.strip("==a\nb ==c==") == "a\nb c" )
        check("highlight: spaced == stays literal, a dangling opener is not confused with it", Highlights.strip("if a == b and ==c") == "if a == b and c")
        check("highlight: an over-long span keeps both markers as written", Highlights.strip("==" + String(repeating: "x", count: 90) + "==") == "==" + String(repeating: "x", count: 90) + "==")

        // Not marks.
        for plain in ["if a == b then c", "a == b and c == d", "x==y", "a==b==c", "a === b", "x >= y and y <= z", "== a ==", "== a==", "1 ==", "=====", "==\n==",
                      "the ==\n", "a = b", "price == $5 == $6"] {
            check("highlight: not a mark: \(plain.debugDescription)", Highlights.strip(plain) == plain && Highlights.encode(plain) == plain && !Highlights.hasMarks(plain))
        }
        check("highlight: spaces just inside the markers are not a mark", !Highlights.hasMarks("== word ==") && !Highlights.hasMarks("==word =="))

        // Code, maths, links and clips are left literal.
        for (what, text) in [("inline code", "use `a ==b== c` here"), ("double-backtick code", "use ``a ==b== c`` here"),
                             ("a fenced block", "see\n```\nx ==y== z\n```\nend"), ("an unclosed fence", "see\n```python\nx ==y== z"),
                             ("inline maths", "so $a ==b== c$ holds"), ("display maths", "so $$x ==y== z$$ holds"), ("\\( \\) maths", "so \\(a ==b== c\\) holds"),
                             ("a link address", "see [x](https://example.com/?a==b==c) now"), ("a bare address", "see https://example.com/?a==b==c now"),
                             ("a voice clip", "say <say lang=\"en\" ipa=\"x\">==a==</say> now")] {
            check("highlight: \(what) is left literal", Highlights.strip(text) == text && Highlights.encode(text) == text)
        }
        check("highlight: marks next to code still work", Highlights.strip("==the term== means `a ==b== c`") == "the term means `a ==b== c`")
        check("highlight: marks after a fenced block still work", Highlights.strip("```\nx ==y==\n```\nthen ==this==") == "```\nx ==y==\n```\nthen this")
        let codeRuns = runs("run `x ==y== z` for ==the result==")
        check("highlight: through the view, inline code keeps its == and the mark is drawn", codeRuns.map(\.text).joined() == "run x ==y== z for the result" && codeRuns.filter(\.marked).map(\.text) == ["the result"])

        // Length and lines.
        let long80 = String(repeating: "a", count: 80), long81 = String(repeating: "a", count: 81)
        check("highlight: a span of exactly 80 characters is a mark", Highlights.strip("==\(long80)==") == long80)
        check("highlight: a span over 80 characters is ignored", Highlights.strip("==\(long81)==") == "==\(long81)==" && !Highlights.hasMarks("==\(long81)=="))
        check("highlight: a mark never crosses a line", Highlights.strip("==one\ntwo==") == "one\ntwo==" && Highlights.strip("==one==\n==two==") == "one\ntwo")
        check("highlight: a mark is not glued to a word or another =", !Highlights.hasMarks("a==b== c") && !Highlights.hasMarks("==b==c") && Highlights.hasMarks("(==b==)") && Highlights.hasMarks("==b==, then"))
        check("highlight: other languages work", Highlights.strip("Это ==ключевое слово== тут") == "Это ключевое слово тут")
        check("highlight: stray stand-in characters in the text are dropped", Highlights.encode("a\(Highlights.open)b") == "ab" && Highlights.strip("") == "")

        // Everything that reads answer text sees no ==.
        let raw = "The ==derivative== of **==x²==** is ==2x==, and `a == b` stays.\n\n- ==chain rule==: ok"
        let plain = Answer.plainText(raw)
        check("highlight: plain text (copy, quiz, speech, naming, MCP) has no marks and keeps code", plain == "The derivative of **x²** is 2x, and `a == b` stays.\n\n- chain rule: ok")
        let turns = [ChatRecord.Turn(question: "q", answer: raw)]
        var record = ChatRecord(id: UUID(), created: Date(), updated: Date(), title: "t", sector: "Math", app: "Safari", quote: "", turns: turns)
        record.quote = ""
        check("highlight: a saved chat's list preview and transcript (search, copy) have no marks",
              !record.snippet.contains("==derivative") && !record.snippet.contains("==2x") && !record.transcript.contains("==derivative") && !record.transcript.contains("==chain")
                && record.transcript.contains("`a == b`") && record.snippet.contains("derivative"))
        check("highlight: the prompt history for a quiz or escalation has no marks",
              { () -> Bool in
                  let m = AskModel(selection: Selection(text: "x", appName: "Safari", context: ContextBox(resolved: nil), pid: 0, mouse: .zero), footnote: "")
                  m.turns = [AskModel.Turn(question: "q", answer: raw, done: true), AskModel.Turn(question: "q2")]
                  return m.earlierExchanges().first?.answer == plain
              }())

        let quiz = QuizSpec.parse(#"{"title":"T","questions":[{"q":"What is the ==chain rule==?","options":["A ==rule==","B"],"answer":"A ==rule==","why":"It is ==composition=="}]}"#)
        check("highlight: a quiz's question, options, answer and why have no marks",
              quiz?.questions.first.map { $0.text == "What is the chain rule?" && $0.options == ["A rule", "B"] && $0.answer == "A rule" && $0.correct == 0 && $0.why == "It is composition" } == true)

        // Drawn: the tint is behind the marked word, and only then.
        let on = tintPixels("The ==derivative== is a rate.", dark: false), off = tintPixels("The derivative is a rate.", dark: false)
        check("highlight: the marked word is drawn on a tint (light)", on > off + 150)
        check("highlight: with no marks there is no tint", off == 0 || off < 20)
        let onDark = tintPixels("The ==derivative== is a rate.", dark: true), offDark = tintPixels("The derivative is a rate.", dark: true)
        check("highlight: the marked word is drawn on a tint (dark)", onDark > offDark + 150)
        let wrapped = tintPixels("Start " + String(repeating: "filler words ", count: 6) + "==a mark that is long enough to wrap onto the next line of the answer== end", dark: false, width: 260)
        let single = tintPixels("Start ==a mark that is long enough to wrap onto the next line of the answer== end", dark: false, width: 900)
        check("highlight: a mark that wraps is tinted on both lines", wrapped > single * 8 / 10)
        let withMaths = tintPixels("==the speed== $v = u + at$ and ==more==", dark: false)
        check("highlight: tint beside inline maths", withMaths > 150)
        check("highlight: the tint shows with text selection on too", tintPixels("The ==derivative== is a rate.", dark: false, selectable: true) > 150)
        check("highlight: streaming, a half-arrived mark draws no tint", tintPixels("The ==deriv", dark: false, streaming: true) < 20)
    }

    /// How many pixels of the tint colour a line of answer text paints (the line drawn the way the answer view draws it).
    private static func tintPixels(_ line: String, dark: Bool, width: CGFloat = 400, streaming: Bool = false, selectable: Bool = false) -> Int {
        let view = Group {
            if selectable { MathLine(text: line, streaming: streaming).textSelection(.enabled) } else { MathLine(text: line, streaming: streaming) }
        }
            .foregroundStyle(Theme.ink.color)
            .frame(width: width, alignment: .leading)
            .padding(8)
            .background(Color(white: dark ? 0.16 : 0.97))
            .environment(\.colorScheme, dark ? .dark : .light)
        var count = 0
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        appearance.performAsCurrentDrawingAppearance {
            let host = NSHostingView(rootView: view)
            host.appearance = appearance
            host.frame = NSRect(x: 0, y: 0, width: width + 16, height: 100)
            host.layoutSubtreeIfNeeded()
            host.frame.size.height = max(24, host.fittingSize.height)
            host.layoutSubtreeIfNeeded()
            guard let rep = NSBitmapImageRep.rgba(pixelsWide: Int(host.bounds.width), pixelsHigh: Int(host.bounds.height)) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            let base = dark ? 0.16 : 0.97
            for y in 0..<rep.pixelsHigh {
                for x in 0..<rep.pixelsWide {
                    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    // The accent over the backdrop differs from it clearly in hue/saturation, which text (grey) never does.
                    let spread = max(c.redComponent, c.greenComponent, c.blueComponent) - min(c.redComponent, c.greenComponent, c.blueComponent)
                    if spread > 0.08, abs(c.brightnessComponent - base) < 0.5 { count += 1 }
                }
            }
        }
        return count
    }
}
