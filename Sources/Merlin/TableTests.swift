import CoreGraphics
import Foundation

/// R1: tables in answers. Finding a table, splitting cells, streaming without raw pipes, uneven rows, plain text for
/// voice and search, Copy table's tab-separated text, column widths, and the prompt rule and its gate.
extension FeatureTests {
    static func tableChecks(_ check: (String, Bool) -> Void) {
        typealias T = MarkdownTable
        let sample = T.economicsSample
        func tables(_ blocks: [T.Block]) -> [T] { blocks.compactMap { if case .table(let t) = $0 { return t } else { return nil } } }
        func texts(_ blocks: [T.Block]) -> [String] { blocks.compactMap { if case .text(let t) = $0 { return t } else { return nil } } }

        // A 3-column table parses, with the prose around it kept.
        let parsed = T.blocks(sample)
        let table = tables(parsed).first
        check("table: the economics answer is prose, one table, prose", parsed.count == 3 && tables(parsed).count == 1
              && texts(parsed).first?.hasPrefix("Here are five") == true && texts(parsed).last?.hasPrefix("**Remember:**") == true)
        check("table: header Term | Definition | Formula, 5 rows of 3 cells",
              table?.header == ["Term", "Definition", "Formula"] && table?.rows.count == 5 && table?.rows.allSatisfy { $0.count == 3 } == true)
        check("table: cells keep marks and maths as written",
              table?.rows[0][0] == "Price elasticity of demand" && table?.rows[1][1] == "The ==extra cost== of producing one more unit."
                && table?.rows[0][2] == #"$PED = \frac{\%\Delta Q_d}{\%\Delta P}$"#)
        check("table: text with no table comes back unchanged",
              T.blocks("Plain answer.\n\n- a list\n- of things") == [.text("Plain answer.\n\n- a list\n- of things")]
                && T.blocks("P(A|B) is a probability.\n---\nNext line.") == [.text("P(A|B) is a probability.\n---\nNext line.")]
                && T.blocks("a | b on one line") == [.text("a | b on one line")])

        // Cells split only on real borders.
        check("table cells: a | inside $…$, code and ==marks== does not split; \\| is a pipe",
              T.cells(#"| $|x| + 1$ | `a | b` | ==x | y== | c \| d |"#) == ["$|x| + 1$", "`a | b`", "==x | y==", "c | d"])
        check("table cells: money is not maths, so \"$5 | $10\" splits", T.cells("| $5 | $10 |") == ["$5", "$10"])
        check("table cells: \\(…\\) maths is protected too", T.cells(#"| \(a|b\) | z |"#) == [#"\(a|b\)"#, "z"])
        check("table cells: empty cells stay", T.cells("| a | | c |") == ["a", "", "c"])
        let bare = tables(T.blocks("Name | Age\n--- | ---\nAda | 36"))
        check("table: missing outer pipes are forgiven", bare.first?.header == ["Name", "Age"] && bare.first?.rows == [["Ada", "36"]])
        check("table: alignment colons in the delimiter row", tables(T.blocks("| a | b |\n|:--|--:|\n| 1 | 2 |")).first?.rows == [["1", "2"]])
        let uneven = tables(T.blocks("| a | b | c |\n|---|---|---|\n| 1 |\n| 1 | 2 | 3 | 4 |")).first
        check("table: uneven rows render (short rows padded, a long row's extra cell kept)",
              uneven?.columnCount == 4 && uneven.map { $0.padded($0.rows[0]) } == ["1", "", "", ""]
                && uneven.map { $0.padded($0.header) } == ["a", "b", "c", ""] && uneven?.rows[1] == ["1", "2", "3", "4"])
        check("table: a blank line ends the table", texts(T.blocks("| a | b |\n|---|---|\n| 1 | 2 |\n\nAfter.")) == ["After."])
        check("table: delimiter helpers", T.isDelimiter("|---|---|") && T.isDelimiter("--|--") && !T.isDelimiter("---")
              && !T.isDelimiter("| a |") && T.isDelimiterPrefix("") && T.isDelimiterPrefix("|--") && !T.isDelimiterPrefix("| T"))

        // Streaming: every prefix of the answer, through the same path the chat uses, never shows a raw pipe or the |---| row.
        func shownWhileStreaming(_ prefix: String) -> [T.Block] {
            Answer.pieces(prefix, hidePartial: true).flatMap { piece -> [T.Block] in
                guard case .text(let t) = piece else { return [] }
                // VoiceMessageView trims newlines, then MarkdownText splits out ``` code before finding tables.
                return MarkdownText.segments(t.trimmingCharacters(in: .newlines)).filter { !$0.isCode }
                    .flatMap { T.blocks($0.text, streaming: true) }
            }
        }
        for (name, full) in [("with prose around it", sample),
                             ("at the very start and end", "| Term | Meaning |\n|---|---|\n| GDP | Total ==output== |\n| CPI | A price index, $\\frac{a}{b}$ |")] {
            var leaks: [String] = []
            var index = full.startIndex
            var lastRows = 0, rowsShrank = false
            while true {
                let prefix = String(full[..<index])
                let shown = shownWhileStreaming(prefix)
                if texts(shown).contains(where: { $0.contains("|") || $0.contains("---") }) { leaks.append(prefix) }
                if tables(shown).contains(where: { t in ([t.header] + t.rows).joined().contains { $0.contains("|") || $0.hasPrefix("--") } }) {
                    leaks.append(prefix)
                }
                let rows = tables(shown).first?.rows.count ?? 0
                if rows < lastRows { rowsShrank = true }
                lastRows = rows
                if index == full.endIndex { break }
                index = full.index(after: index)
            }
            check("table streaming (\(name)): no prefix of \(full.count) characters shows a raw pipe or the |---| row (\(leaks.count) leaks)",
                  leaks.isEmpty)
            check("table streaming (\(name)): rows only ever get added", !rowsShrank)
        }
        check("table streaming: a header waits for its delimiter row",
              T.blocks("Intro.\n| Term | Def", streaming: true) == [.text("Intro.")]
                && T.blocks("Intro.\n| Term | Def |\n|--", streaming: true) == [.text("Intro.")]
                && T.blocks("Intro.\n| Term | Def |\n|---|---|", streaming: true) == [.text("Intro.")])
        check("table streaming: once the delimiter row ends, the header shows",
              tables(T.blocks("| Term | Def |\n|---|---|\n", streaming: true)).first == T(header: ["Term", "Def"], rows: []))
        let cutMark = sample.components(separatedBy: "willing")[0] // inside an ==mark
        let cutMaths = sample.components(separatedBy: #"{\Delta TC}"#)[0] // inside $\frac{
        check("table streaming: a half-written row shows only its closed cells (cut inside a ==mark)",
              tables(T.blocks(cutMark, streaming: true)).first?.rows.last == ["Consumer surplus"])
        check("table streaming: a half-written formula's cell waits (cut inside $\\frac{)",
              tables(T.blocks(cutMaths, streaming: true)).first?.rows.last == ["Marginal cost", "The ==extra cost== of producing one more unit."])
        check("table: a stopped answer with a header and no delimiter row stays text (nothing says it is a table)",
              T.blocks("| Term | Def |", streaming: false) == [.text("| Term | Def |")])

        // Plain text (voice read-out, previews, titles, search, quiz input) and Copy table.
        let plain = Answer.plainText(sample)
        check("table plain text: no pipes, no |---| row, no marks", !plain.contains("|") && !plain.contains("---") && !plain.contains("=="))
        check("table plain text: one readable line per row, header names first",
              plain.contains("Term: Marginal cost. Definition: The extra cost of producing one more unit. Formula: ")
                && plain.contains("Term: Total revenue.") && plain.contains("Here are five") && plain.contains("Remember:"))
        check("table plain text: an answer with no table is unchanged", Answer.plainText("Just **this** answer.") == "Just **this** answer.")
        let tsv = table?.tsv ?? ""
        let tsvLines = tsv.components(separatedBy: "\n")
        check("copy table: tab-separated, header first, one line per row",
              tsvLines.count == 6 && tsvLines.allSatisfy { $0.components(separatedBy: "\t").count == 3 } && tsvLines[0] == "Term\tDefinition\tFormula")
        check("copy table: marks and maths as plain text (\(tsvLines.count > 1 ? tsvLines[1] : ""))",
              !tsv.contains("==") && !tsv.contains("$") && !tsv.contains("\\frac") && !tsv.contains("|")
                && tsvLines[2].hasPrefix("Marginal cost\tThe extra cost of producing one more unit.\tMC = "))
        check("copy table: short rows padded, so columns line up", uneven?.tsv.components(separatedBy: "\n").allSatisfy { $0.components(separatedBy: "\t").count == 4 } == true)
        check("table cells: <br> is a line break on screen and a space in plain text",
              TableCard.cellText("one<br>two<br/>three") == "one\ntwo\nthree" && T.plainCell("one<br>two") == "one two")
        check("table cells: bold and code markers go in plain text", T.plainCell("**big** and `code`") == "big and code")
        check("table cells: powers and subscripts survive in plain text (\(T.plainCell("$E = mc^2$")), \(T.plainCell("$x^{-3/2}$")), \(T.plainCell("$Q_d$")))",
              T.plainCell("$E = mc^2$") == "E = mc^2" && T.plainCell("$x^{-3/2}$") == "x^(−3/2)" && T.plainCell("$Q_d$") == "Q_d")
        // Column widths: by content, 90 pt minimum, sideways scroll only when the minimums don't fit.
        let fits = T.columnWidths(natural: [120, 200, 100], minimum: [90, 90, 90], available: 600)
        check("table widths: one-line content fills the card in proportion",
              abs(fits.reduce(0, +) - 600) < 0.5 && fits[1] > fits[0] && fits[0] > fits[2])
        let wraps = T.columnWidths(natural: [220, 640, 150], minimum: [100, 90, 110], available: 340)
        check("table widths: long text wraps, sharing the card by how much each column wants (\(wraps.map { Int($0) }))",
              abs(wraps.reduce(0, +) - 340) < 0.5 && zip(wraps, [100, 90, 110]).allSatisfy { $0 >= $1 } && wraps[1] > wraps[0])
        let narrow = T.columnWidths(natural: [50, 60], minimum: [20, 30], available: 100)
        check("table widths: never under 90 pt; too wide scrolls sideways", narrow == [90, 90] && narrow.reduce(0, +) > 100)
        let scrolls = T.columnWidths(natural: [200, 600, 185], minimum: [104, 92, 185], available: 340)
        check("table widths: a table that must scroll is at most a quarter wider than the card, the long column getting the room (\(scrolls.map { Int($0) }))",
              abs(scrolls.reduce(0, +) - 425) < 0.5 && zip(scrolls, [104, 92, 185]).allSatisfy { $0 >= $1 } && scrolls[1] > scrolls[0] && scrolls[2] == 185)
        check("table widths: minimums wider than that are kept (scrolls further)",
              T.columnWidths(natural: [300, 300, 300], minimum: [200, 200, 200], available: 340) == [200, 200, 200])
        let measured = TableCard.widths(table ?? T(header: [], rows: []), available: 340, dark: false)
        check("table widths: the economics table in a 340 pt answer: 3 columns, each 90 pt or more (\(measured.map { Int($0) }))",
              measured.count == 3 && measured.allSatisfy { $0 >= 90 })

        // The prompt rule and its gate.
        let rule = Prompts.tableRule
        check("table rule: 40 tokens or fewer (\(rule.count) characters, about \(rule.count / 4) tokens)", rule.count <= 160)
        check("table rule: says when, the Markdown form, and when not", rule.contains("Terms with definitions") && rule.contains("compared")
              && rule.contains("Markdown table") && rule.contains("|---|") && rule.contains("Not for steps"))
        func f(_ q: String) -> Prompts.Features { Prompts.features(question: q, selection: "") }
        func occurrences(_ needle: String, in text: String) -> Int { text.components(separatedBy: needle).count - 1 }
        check("table gate: table / terms / definitions / glossary / compare / vs / differences questions get it",
              ["Make a table of 5 microeconomics terms with definitions", "Define these terms", "Give me a glossary",
               "Compare mitosis and meiosis", "Monopoly vs oligopoly", "What are the differences between a virus and a bacterium?",
               "Fiscal versus monetary policy"].allSatisfy { f($0).contains(.table) })
        check("table gate: plain questions, \"in terms of\", Pronounce and quizzes don't",
              !f("What does this mean?").contains(.table) && !f("Explain it in terms of energy").contains(.table)
                && !f(Prompts.pronounce).contains(.table) && !f(Prompts.quiz).contains(.table) && !f("Why does it happen?").contains(.table))
        check("table gate: never part of .all", !Prompts.Features.all.contains(.table))
        check("table gate: in the prompt with .table or .graphs, once; not without",
              Prompts.system(webSearch: false, features: .table).contains(rule) && Prompts.system(webSearch: false, features: .graphs).contains(rule)
                && Prompts.system(webSearch: false, features: .all).contains(rule) && !Prompts.system(webSearch: false, features: []).contains(rule)
                && !Prompts.system(webSearch: false, features: [.board, .learn]).contains(rule)
                && occurrences(rule, in: Prompts.system(webSearch: true, features: [.all, .table])) == 1)
        let tableLater = Prompts.extraInstructions(for: "Make a table of these terms", have: [])
        check("table gate: a later table question carries the rule once", tableLater?.added.contains(.table) == true && tableLater?.text.contains(rule) == true)
        check("table gate: not again once the chat has it, or has the graphs rule",
              Prompts.extraInstructions(for: "Make a table of these terms", have: .table) == nil
                && Prompts.extraInstructions(for: "Make a table of these terms", have: .graphs) == nil)
        let plotLater = Prompts.extraInstructions(for: "Plot the demand curve", have: [])
        check("table gate: a later graph question brings the table rule with the graphs rule, once",
              plotLater.map { occurrences(rule, in: $0.text) == 1 && $0.added.contains(.table) && $0.added.contains(.graphs) } == true)
        check("table gate: the quick and local models never get it (as with the graphs rule)",
              !Prompts.quickSystem(seeing: true, model: Settings.haikuID, features: [.all, .table, .learn]).contains(rule)
                && !Prompts.quickSystem(seeing: false, model: "qwen3:8b", features: [.all, .table]).contains(rule) && !Prompts.localSystem.contains(rule))
        check("board rule: comparisons are no longer a board's job",
              !Prompts.boardRule.contains("Steps/causes/comparisons") && Prompts.boardRule.hasPrefix("Steps/causes (not curves/comparisons"))
    }
}
