import CoreGraphics
import Foundation

/// A GitHub-style Markdown table in an answer: a header row, a `|---|` row, then body rows. Outer pipes may be missing
/// and rows may have uneven cell counts. A `|` inside `$…$`, `\(…\)`, inline code or `==marks==` is part of the cell, and
/// `\|` is a literal pipe.
///
/// `blocks` is the one place a table is found: the renderer (`MarkdownText`), `Answer.plainText` and Copy table all use it.
struct MarkdownTable: Equatable {
    var header: [String]
    var rows: [[String]]

    /// The widest row decides: a short row gets empty cells, a long row's extra cells are kept (a header cell is blank).
    var columnCount: Int { max(header.count, rows.map(\.count).max() ?? 0) }

    /// A row padded to `columnCount` with empty cells.
    func padded(_ row: [String]) -> [String] { row + Array(repeating: "", count: max(0, columnCount - row.count)) }

    /// A stretch of answer text: prose (shown as before) or a table.
    enum Block: Equatable {
        case text(String)
        case table(MarkdownTable)
    }

    // MARK: Finding tables

    /// `text` as prose and tables, in order. With no table the result is the text unchanged.
    ///
    /// `streaming`: the text is still arriving, so its last line may be half-written. Raw pipes never show: a header row
    /// waits until its `|---|` row has fully arrived (the line has ended), and a half-written body row shows only the cells
    /// already closed by a `|` (none yet: the row waits).
    static func blocks(_ text: String, streaming: Bool = false) -> [Block] {
        guard text.contains("|") else { return text.isEmpty ? [] : [.text(text)] }
        let lines = text.components(separatedBy: "\n")
        // While streaming, the last line is the one still being written (empty when the text ends with a newline).
        let partial = streaming ? lines.count - 1 : -1
        var out: [Block] = []
        var prose: [String] = []
        func flush() {
            let joined = prose.joined(separator: "\n")
            if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(.text(joined)) }
            prose = []
        }
        var i = 0
        while i < lines.count {
            let line = lines[i]
            // A table starts here: a row with a pipe, then a finished delimiter row.
            if i + 1 < lines.count, i + 1 != partial, hasPipe(line), isDelimiter(lines[i + 1]) {
                var table = MarkdownTable(header: cells(line), rows: [])
                var j = i + 2
                while j < lines.count {
                    let row = lines[j]
                    if j == partial {
                        if hasPipe(row, openEnded: true) {
                            let done = completeCells(row)
                            if !done.isEmpty { table.rows.append(done) }
                            j += 1
                        }
                        break
                    }
                    guard !row.trimmingCharacters(in: .whitespaces).isEmpty, hasPipe(row) else { break }
                    table.rows.append(cells(row))
                    j += 1
                }
                flush()
                out.append(.table(table))
                i = j
                continue
            }
            if streaming {
                // The line being written has a pipe: it may be a header row. Wait for its delimiter row.
                if i == partial && hasPipe(line, openEnded: true) { i += 1; continue }
                // A finished row with a pipe, and the line after it is (so far) only a delimiter row's characters.
                if i == partial - 1 && hasPipe(line) && isDelimiterPrefix(lines[partial]) { i += 2; continue }
            }
            prose.append(line)
            i += 1
        }
        flush()
        // Next to a table, the prose loses the blank lines that separated it (the card has its own spacing).
        guard out.contains(where: { if case .table = $0 { return true } else { return false } }) else { return out }
        return out.compactMap { block in
            guard case .text(let t) = block else { return block }
            let trimmed = t.trimmingCharacters(in: .newlines)
            return trimmed.isEmpty ? nil : .text(trimmed)
        }
    }

    /// `|---|---|`, `:--|--:`, `| :-: |`: every cell is dashes (with optional colons), and there is at least one pipe.
    static func isDelimiter(_ line: String) -> Bool {
        line.contains("|") && line.range(of: #"^\s*\|?\s*:?-+:?\s*(?:\|\s*:?-+:?\s*)*\|?\s*$"#, options: .regularExpression) != nil
    }

    /// What a delimiter row looks like before it has fully arrived (empty counts: nothing has arrived yet).
    static func isDelimiterPrefix(_ line: String) -> Bool {
        line.range(of: #"^[\s|:\-]*$"#, options: .regularExpression) != nil
    }

    // MARK: Cells

    /// Inline code, display and inline maths, and complete marks: a pipe inside one of these is not a cell border.
    /// The `$…$` rule matches MathRender's (no space just inside the dollars, not followed by a digit), so "$5 | $10" splits.
    private static let protectedRegex = try! NSRegularExpression(pattern:
        #"(`+)[^`].*?\1(?!`)|\$\$.+?\$\$|\\\(.+?\\\)|(?<![\\$\w])\$(?=[^\s$])[^$\n]+?(?<=\S)\$(?!\d)|==(?=[^\s=])[^\n]*?(?<=[^\s=])=="#)
    /// Just the maths spans (for the plain-text form of a cell).
    private static let mathRegex = try! NSRegularExpression(pattern:
        #"\$\$(.+?)\$\$|\\\((.+?)\\\)|(?<![\\$\w])\$(?=[^\s$])([^$\n]+?)(?<=\S)\$(?!\d)"#)

    /// Which UTF-16 positions of `line` are inside a protected span. `openEnded` (a row still arriving): an opener that has no
    /// closer yet (`$`, a backtick, `==`, `\(`) protects the rest of the line, so a half-written formula's pipe doesn't split.
    private static func protectedMask(_ ns: NSString, openEnded: Bool) -> [Bool] {
        let n = ns.length
        var mask = [Bool](repeating: false, count: n)
        for m in protectedRegex.matches(in: ns as String, range: NSRange(location: 0, length: n)) {
            for k in m.range.location..<(m.range.location + m.range.length) { mask[k] = true }
        }
        guard openEnded else { return mask }
        var k = 0
        while k < n {
            let c = ns.character(at: k)
            let escaped = k > 0 && ns.character(at: k - 1) == 92 && !mask[k - 1]
            let next: unichar = k + 1 < n ? ns.character(at: k + 1) : 0
            if !mask[k] && !escaped && (c == 96 || c == 36 || (c == 61 && next == 61) || (c == 92 && next == 40)) {
                for j in k..<n { mask[j] = true }
                break
            }
            k += 1
        }
        return mask
    }

    /// The line has a cell border: a `|` that is not escaped and not inside a protected span.
    static func hasPipe(_ line: String, openEnded: Bool = false) -> Bool {
        guard line.contains("|") else { return false }
        let ns = line as NSString
        let mask = protectedMask(ns, openEnded: openEnded)
        for k in 0..<ns.length where ns.character(at: k) == 124 && !mask[k] {
            if k > 0 && ns.character(at: k - 1) == 92 { continue }
            return true
        }
        return false
    }

    /// Splits a row into trimmed cells. `closed`: the cells a border has closed so far, and the rest after the last border.
    private static func split(_ line: String, openEnded: Bool) -> (closed: [String], rest: String) {
        let ns = line as NSString
        let mask = protectedMask(ns, openEnded: openEnded)
        let n = ns.length
        var k = 0
        while k < n, let s = UnicodeScalar(ns.character(at: k)), CharacterSet.whitespaces.contains(s) { k += 1 }
        if k < n && ns.character(at: k) == 124 { k += 1 } // the leading outer pipe
        var closed: [String] = []
        var current: [unichar] = []
        func trimmed(_ u: [unichar]) -> String { String(utf16CodeUnits: u, count: u.count).trimmingCharacters(in: .whitespaces) }
        while k < n {
            let c = ns.character(at: k)
            if mask[k] { current.append(c); k += 1; continue }
            if c == 92 && k + 1 < n && ns.character(at: k + 1) == 124 { current.append(124); k += 2; continue } // \| is a pipe
            if c == 124 { closed.append(trimmed(current)); current = []; k += 1; continue }
            current.append(c)
            k += 1
        }
        return (closed, trimmed(current))
    }

    /// A finished row's cells (a missing trailing pipe is fine).
    static func cells(_ line: String) -> [String] {
        let s = split(line, openEnded: false)
        return s.rest.isEmpty ? s.closed : s.closed + [s.rest]
    }

    /// A half-written row's cells that a `|` has already closed.
    static func completeCells(_ line: String) -> [String] { split(line, openEnded: true).closed }

    // MARK: Plain text

    /// A cell as plain words: marks, bold and code markers gone, maths as readable plain maths, `<br>` as a space.
    static func plainCell(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"<br\s*/?>"#, with: " ", options: [.regularExpression, .caseInsensitive])
        t = Highlights.strip(t)
        // Maths out first (markdown would eat its backslashes), back in as plain maths after.
        var maths: [String] = []
        let ns = t as NSString
        var rebuilt = ""
        var at = 0
        for m in mathRegex.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
            rebuilt += ns.substring(with: NSRange(location: at, length: m.range.location - at))
            let g = (1..<m.numberOfRanges).first { m.range(at: $0).location != NSNotFound }
            maths.append(MathRender.fallbackText(g.map { ns.substring(with: m.range(at: $0)) } ?? ""))
            rebuilt += "\u{E1F0}\(maths.count - 1)\u{E1F1}"
            at = m.range.location + m.range.length
        }
        rebuilt += ns.substring(from: at)
        if let a = try? AttributedString(markdown: rebuilt, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            rebuilt = String(a.characters)
        }
        for (i, m) in maths.enumerated() { rebuilt = rebuilt.replacingOccurrences(of: "\u{E1F0}\(i)\u{E1F1}", with: m) }
        // MathPretty's sub/superscript stand-ins back to plain ^ and _ (x^2, x^(−3/2), Q_d), so powers are not lost;
        // any other private-use characters go.
        for (open, close, sign) in [(MathPretty.supOpen, MathPretty.supClose, "^"), (MathPretty.subOpen, MathPretty.subClose, "_")] {
            let pattern = "\(open)([^\(close)]*)\(close)"
            while let r = rebuilt.range(of: pattern, options: .regularExpression) {
                let inner = String(rebuilt[r].dropFirst().dropLast())
                rebuilt.replaceSubrange(r, with: sign + (inner.count > 1 ? "(\(inner))" : inner))
            }
        }
        rebuilt = String(String.UnicodeScalarView(rebuilt.unicodeScalars.filter { !(0xE000...0xF8FF).contains($0.value) }))
        return rebuilt.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    /// Tab-separated plain text, one line per row with the header first: pastes into Notes, Numbers or a spreadsheet.
    var tsv: String {
        ([header] + rows).map { padded($0).map(Self.plainCell).joined(separator: "\t") }.joined(separator: "\n")
    }

    /// Readable lines for voice read-out, search, previews and prompts: "Term: Marginal cost. Definition: The extra cost."
    var plainLines: String {
        let heads = padded(header).map(Self.plainCell)
        guard !rows.isEmpty else { return heads.filter { !$0.isEmpty }.joined(separator: ", ") }
        return rows.map { row in
            zip(heads, padded(row).map(Self.plainCell)).compactMap { head, cell -> String? in
                guard !cell.isEmpty else { return nil }
                let part = head.isEmpty ? cell : "\(head): \(cell)"
                return part.last.map { ".!?:;".contains($0) } == true ? part : part + "."
            }.joined(separator: " ")
        }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// Text with each table turned into `plainLines` (other text unchanged).
    static func plainText(_ text: String) -> String {
        let parts = blocks(text)
        guard parts.contains(where: { if case .table = $0 { return true } else { return false } }) else { return text }
        return parts.map { block -> String in
            switch block {
            case .text(let t): return t
            case .table(let table): return table.plainLines
            }
        }.joined(separator: "\n")
    }

    /// The maths in a cell (for measuring it as a typeset image).
    static func mathSpans(_ s: String) -> (latex: [String], rest: String) {
        let ns = s as NSString
        var latex: [String] = []
        var rest = ""
        var at = 0
        for m in mathRegex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            rest += ns.substring(with: NSRange(location: at, length: m.range.location - at)) + " "
            let g = (1..<m.numberOfRanges).first { m.range(at: $0).location != NSNotFound }
            latex.append(g.map { ns.substring(with: m.range(at: $0)) } ?? "")
            at = m.range.location + m.range.length
        }
        rest += ns.substring(from: at)
        return (latex, rest)
    }

    /// The answer from Merlin's report (an economics terms table with marks and formulas), for checks and pictures.
    static let economicsSample = #"""
    Here are five core microeconomics terms, with how to calculate each.

    | Term | Definition | Formula |
    |---|---|---|
    | Price elasticity of demand | How strongly ==quantity demanded== responds to a change in price. | $PED = \frac{\%\Delta Q_d}{\%\Delta P}$ |
    | Marginal cost | The ==extra cost== of producing one more unit. | $MC = \frac{\Delta TC}{\Delta Q}$ |
    | Consumer surplus | The gap between what buyers are ==willing to pay== and the price they pay. | $CS = \frac{1}{2} \times Q \times (P_{max} - P)$ |
    | Opportunity cost | The value of the ==next best alternative== you give up. | $OC = \frac{\text{given up}}{\text{gained}}$ |
    | Total revenue | All the money a firm takes in from its sales. | $TR = P \times Q$ |

    **Remember:** elasticity measures ==responsiveness==, not slope.
    """#

    // MARK: Column widths

    static let minimumColumn: CGFloat = 90

    /// How wide each column is, from its content. `natural`: a column's width with every cell on one line; `minimum`: the
    /// narrowest it can wrap to (its longest word or formula). Both include the cell padding.
    /// - Everything fits on one line: each column gets its natural width, and the spare width is shared in proportion.
    /// - Otherwise columns wrap: each gets its minimum plus a share of the spare width in proportion to how much it wants.
    /// - Even the minimums don't fit: the table scrolls sideways inside its card anyway, so it may be up to a quarter wider
    ///   than the card (`overflow`), shared the same way: wrapping text gets readable lines instead of one word per line,
    ///   and most of the table still shows before any scrolling.
    /// No column is narrower than `floor` (90 pt).
    static let overflow: CGFloat = 1.25
    static func columnWidths(natural: [CGFloat], minimum: [CGFloat], available: CGFloat, floor: CGFloat = minimumColumn) -> [CGFloat] {
        let mins = minimum.map { max(floor, $0) }
        let nats = zip(natural, mins).map { max($0, $1) }
        let sumNat = nats.reduce(0, +), sumMin = mins.reduce(0, +)
        guard available > 0, !nats.isEmpty else { return mins }
        if sumNat <= available {
            let spare = available - sumNat
            return nats.map { $0 + spare * $0 / sumNat }
        }
        let target = sumMin <= available ? available : min(sumNat, max(sumMin, available * overflow))
        let want = zip(nats, mins).map { $0 - $1 }
        let sumWant = want.reduce(0, +)
        let spare = target - sumMin
        return zip(mins, want).map { $0 + (sumWant > 0 ? spare * $1 / sumWant : spare / CGFloat(mins.count)) }
    }
}
