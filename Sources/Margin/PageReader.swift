import AppKit
import ApplicationServices
import PDFKit
import Vision

/// One piece of a document, small enough to send on its own.
struct Passage: Equatable {
    var text: String
    /// 1-based page, for PDFs.
    var page: Int?
}

/// A whole page, PDF or file read on this Mac and cut into passages. A question is answered by sending Claude only
/// the few passages that match it (found here, with no Claude call), not the whole document: a 400-page textbook
/// costs about as much as a paragraph.
struct DocIndex {
    var title: String
    var kind: String
    var pageCount: Int?
    var passages: [Passage]
    /// Notes for the chat's footnote ("scanned: read the first 40 pages").
    var note: String?

    var isEmpty: Bool { passages.isEmpty }
    var characters: Int { passages.reduce(0) { $0 + $1.text.count } }

    // MARK: Cutting up

    /// Passages of about `size` characters, cut at paragraph and sentence breaks.
    static func passages(from text: String, page: Int? = nil, size: Int = 900) -> [Passage] {
        let paragraphs = text.replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n\n").flatMap { $0.components(separatedBy: "\n") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var out: [Passage] = []
        var current = ""
        func flush() {
            let t = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.count > 20 { out.append(Passage(text: t, page: page)) }
            current = ""
        }
        for p in paragraphs {
            if p.count > size * 2 {
                flush()
                // A very long paragraph: cut at sentence ends.
                var piece = ""
                for sentence in p.split(separator: ".", omittingEmptySubsequences: true) {
                    if piece.count + sentence.count > size, !piece.isEmpty { current = piece; flush(); piece = "" }
                    piece += sentence + "."
                }
                current = piece
                flush()
                continue
            }
            if current.count + p.count > size { flush() }
            current += (current.isEmpty ? "" : "\n") + p
        }
        flush()
        return out
    }

    // MARK: Finding

    private static let stop: Set<String> = ["the", "a", "an", "and", "or", "of", "to", "in", "on", "for", "is", "are", "was", "were",
                                            "it", "this", "that", "with", "as", "by", "at", "be", "what", "how", "why", "does", "do",
                                            "me", "my", "i", "you", "about", "from", "can", "explain", "tell", "mean", "means"]

    static func tokens(_ s: String) -> [String] {
        s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 2 && !stop.contains($0) }
    }

    /// The passages that best match `query` (BM25), in document order. Empty if nothing matches.
    func relevant(to query: String, limit: Int = 6) -> [Passage] {
        let q = Set(Self.tokens(query))
        guard !q.isEmpty, !passages.isEmpty else { return [] }
        let docs = passages.map { Self.tokens($0.text) }
        let avg = max(1, Double(docs.reduce(0) { $0 + $1.count }) / Double(docs.count))
        var df: [String: Int] = [:]
        for d in docs { for t in Set(d) where q.contains(t) { df[t, default: 0] += 1 } }
        let n = Double(docs.count)
        var scored: [(Int, Double)] = []
        for (i, d) in docs.enumerated() {
            var score = 0.0
            var tf: [String: Int] = [:]
            for t in d where q.contains(t) { tf[t, default: 0] += 1 }
            for (t, f) in tf {
                let idf = log(1 + (n - Double(df[t] ?? 0) + 0.5) / (Double(df[t] ?? 0) + 0.5))
                let f = Double(f)
                score += idf * (f * 2.5) / (f + 1.5 * (0.25 + 0.75 * Double(d.count) / avg))
            }
            if score > 0 { scored.append((i, score)) }
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0).sorted().map { passages[$0] }
    }

    /// Excerpts spread evenly through the document, for "summarize this" (about `budget` characters).
    func overview(budget: Int = 9000) -> [Passage] {
        guard !passages.isEmpty else { return [] }
        let each = 450
        let count = max(1, min(passages.count, budget / each))
        return (0..<count).map { i in
            var p = passages[Int(Double(i) * Double(passages.count) / Double(count))]
            if p.text.count > each { p.text = String(p.text.prefix(each)) + "…" }
            return p
        }
    }

    // MARK: Showing it to Claude

    static func render(_ passages: [Passage]) -> String {
        passages.map { p in (p.page.map { "[p. \($0)] " } ?? "") + p.text }.joined(separator: "\n\n")
    }
}

/// Reads whatever the front window is showing: a PDF or file on disk, a web page, or (failing that) the visible text.
enum PageReader {
    // MARK: What's open?

    /// The document the app's front window has open (a file or a web address), from Accessibility. Cheap, no reading.
    static func documentURL(pid: pid_t) -> URL? {
        guard pid > 0 else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.4) // an app that's busy mustn't hold Margin up
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window else { return nil }
        var doc: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXDocumentAttribute as CFString, &doc) == .success,
              let s = doc as? String, !s.isEmpty else { return nil }
        if let url = URL(string: s), url.scheme != nil { return url }
        return URL(fileURLWithPath: s)
    }

    /// A short name for a chip: the file's name, or the site.
    static func displayName(_ url: URL) -> String {
        if url.isFileURL { return url.lastPathComponent }
        let host = url.host ?? url.absoluteString
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    static func isReadable(_ url: URL) -> Bool {
        if url.isFileURL { return fileKinds.contains(url.pathExtension.lowercased()) }
        return url.scheme == "http" || url.scheme == "https"
    }

    private static let fileKinds: Set<String> = ["pdf", "txt", "md", "markdown", "rtf", "rtfd", "html", "htm", "docx", "doc", "odt", "csv", "tex"]

    // MARK: Reading

    /// Reads it on a background queue. `done` is called on the main queue with nil if nothing could be read.
    static func read(_ url: URL, pid: pid_t, done: @escaping (DocIndex?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var index: DocIndex?
            if url.isFileURL {
                index = readFile(url)
            } else {
                index = readWeb(url)
                if index == nil || index!.characters < 600 { index = readVisibleText(pid: pid, title: displayName(url)) ?? index }
            }
            DispatchQueue.main.async { done(index?.isEmpty == false ? index : nil) }
        }
    }

    static func readFile(_ url: URL) -> DocIndex? {
        let name = url.deletingPathExtension().lastPathComponent
        switch url.pathExtension.lowercased() {
        case "pdf":
            return readPDF(url, title: name)
        case "txt", "md", "markdown", "csv", "tex":
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return DocIndex(title: name, kind: "file", pageCount: nil, passages: DocIndex.passages(from: text))
        default:
            guard let text = try? NSAttributedString(url: url, options: [:], documentAttributes: nil).string else { return nil }
            return DocIndex(title: name, kind: "document", pageCount: nil, passages: DocIndex.passages(from: text))
        }
    }

    /// Cap on pages read by character recognition (it takes about a second a page).
    static let maxOCRPages = 40

    static func readPDF(_ url: URL, title: String) -> DocIndex? {
        guard let pdf = PDFDocument(url: url) else { return nil }
        var passages: [Passage] = []
        var blank: [Int] = []
        for i in 0..<pdf.pageCount {
            guard let page = pdf.page(at: i) else { continue }
            let text = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.count < 20 { blank.append(i); continue }
            passages += DocIndex.passages(from: text, page: i + 1)
        }
        var note: String?
        // Pages with no text are pictures of text (a scan): read them with on-device character recognition.
        if !blank.isEmpty, passages.count < pdf.pageCount / 2 + 1 {
            let take = Array(blank.prefix(maxOCRPages))
            for i in take {
                guard let page = pdf.page(at: i), let image = render(page), let text = OCR.text(in: image), text.count > 20 else { continue }
                passages += DocIndex.passages(from: text, page: i + 1)
            }
            passages.sort { ($0.page ?? 0) < ($1.page ?? 0) }
            note = blank.count > take.count ? "scanned PDF: read the first \(take.count) pages" : "scanned PDF, read on this Mac"
        }
        return DocIndex(title: title, kind: "PDF", pageCount: pdf.pageCount, passages: passages, note: note)
    }

    private static func render(_ page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let scale: CGFloat = 2
        let size = NSSize(width: bounds.width * scale, height: bounds.height * scale)
        let image = page.thumbnail(of: size, for: .mediaBox)
        var rect = NSRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    static func readWeb(_ url: URL) -> DocIndex? {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        let box = Box<Data?>(nil)
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse, http.statusCode == 200 { box.value = data }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 12)
        guard let data = box.value, let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        let (title, text) = HTMLText.extract(html)
        return DocIndex(title: title ?? displayName(url), kind: "web page", pageCount: nil, passages: DocIndex.passages(from: text))
    }

    /// Last resort: the text the app exposes to Accessibility (what's on the page, even behind a login).
    static func readVisibleText(pid: pid_t, title: String) -> DocIndex? {
        guard pid > 0 else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success, let window else { return nil }
        var lines: [String] = []
        var budget = 6000
        func walk(_ el: AXUIElement, _ depth: Int) {
            guard depth < 40, budget > 0 else { return }
            budget -= 1
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
            if let r = role as? String, r == "AXStaticText" || r == "AXTextArea" || r == "AXHeading" {
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &value) == .success, let s = value as? String,
                   s.count > 1 { lines.append(s) }
            }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &children) == .success, let kids = children as? [AXUIElement] {
                for k in kids { walk(k, depth + 1) }
            }
        }
        walk(window as! AXUIElement, 0)
        let text = lines.joined(separator: "\n\n")
        guard text.count > 200 else { return nil }
        return DocIndex(title: title, kind: "page", pageCount: nil, passages: DocIndex.passages(from: text), note: "read from what's on the page")
    }

    private final class Box<T> { var value: T; init(_ v: T) { value = v } }
}

/// On-device character recognition (Apple's Vision), for scans and screenshots.
enum OCR {
    static func text(in image: CGImage) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil else { return nil }
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

/// Plain text out of a web page (no scripts, menus or footers).
enum HTMLText {
    static func extract(_ html: String) -> (title: String?, text: String) {
        var s = html
        let title = firstGroup(#"<title[^>]*>(.*?)</title>"#, in: s).map(decode)
        for tag in ["script", "style", "noscript", "nav", "header", "footer", "aside", "form", "svg"] {
            s = s.replacingOccurrences(of: "<\(tag)\\b[^>]*>.*?</\(tag)>", with: " ", options: [.regularExpression, .caseInsensitive])
        }
        s = s.replacingOccurrences(of: "<!--.*?-->", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"</(p|div|li|h[1-6]|tr|section|article|blockquote|pre)>|<br\s*/?>"#, with: "\n\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        s = decode(s)
        s = s.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\n\\s*\\n(\\s*\\n)+", with: "\n\n", options: .regularExpression)
        return (title, s.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func firstGroup(_ pattern: String, in s: String) -> String? {
        guard let r = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let m = r.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)), m.numberOfRanges > 1 else { return nil }
        return (s as NSString).substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decode(_ s: String) -> String {
        var out = s
        for (a, b) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
                       ("&mdash;", "—"), ("&ndash;", "–"), ("&hellip;", "…"), ("&rsquo;", "’"), ("&lsquo;", "‘"), ("&ldquo;", "“"), ("&rdquo;", "”")] {
            out = out.replacingOccurrences(of: a, with: b)
        }
        // &#8217; and &#x2019;
        let numeric = try! NSRegularExpression(pattern: #"&#(x?)([0-9a-fA-F]+);"#)
        let ns = out as NSString
        var result = ""
        var cursor = 0
        for m in numeric.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            let hex = ns.substring(with: m.range(at: 1)) == "x"
            if let v = UInt32(ns.substring(with: m.range(at: 2)), radix: hex ? 16 : 10), let u = Unicode.Scalar(v) { result.unicodeScalars.append(u) }
            cursor = m.range.location + m.range.length
        }
        result += ns.substring(from: cursor)
        return result
    }
}
