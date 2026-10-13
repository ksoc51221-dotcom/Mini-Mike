import Foundation
import AppKit

/// "Where's the PDF with the elasticity table?": searches your files with Spotlight (names and the text inside), on this
/// Mac, with no Claude call. Read-only: it changes nothing.
enum Find {
    struct Found: Equatable {
        var url: URL
        var nameMatches: Bool
        var modified: Date
    }

    private static let filler: Set<String> = ["find", "me", "my", "the", "a", "an", "where", "is", "are", "was", "that", "which", "with", "has", "have",
                                              "have", "file", "files", "document", "documents", "for", "of", "in", "on", "about", "locate", "search",
                                              "look", "up", "please", "can", "you", "i", "saved", "downloaded", "it", "to", "and", "or", "containing",
                                              "contains", "named", "called", "mentions", "mentioning", "from"]

    /// File-kind words and the Spotlight type they mean.
    private static let kinds: [(words: [String], clause: String)] = [
        (["pdf", "pdfs"], #"kMDItemContentType == "com.adobe.pdf""#),
        (["image", "images", "photo", "photos", "picture", "pictures", "screenshot", "screenshots"], #"kMDItemContentTypeTree == "public.image""#),
        (["video", "videos", "movie", "movies", "recording"], #"kMDItemContentTypeTree == "public.movie""#),
        (["audio", "song", "songs", "music"], #"kMDItemContentTypeTree == "public.audio""#),
        (["spreadsheet", "spreadsheets", "excel", "xlsx"], #"kMDItemContentTypeTree == "public.spreadsheet""#),
        (["presentation", "presentations", "slides", "powerpoint", "keynote"], #"kMDItemContentTypeTree == "public.presentation""#),
    ]

    /// The words that matter, and a Spotlight query for them.
    static func parse(_ text: String) -> (terms: [String], query: String) {
        var terms: [String] = []
        var clauses: [String] = []
        for word in text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init) {
            if filler.contains(word) { continue }
            if let kind = kinds.first(where: { $0.words.contains(word) }) {
                if !clauses.contains(kind.clause) { clauses.append(kind.clause) }
                continue
            }
            if word.count >= 2 { terms.append(word) }
        }
        let match = terms.map { t in
            let safe = t.replacingOccurrences(of: "\"", with: "")
            return #"(kMDItemDisplayName == "*\#(safe)*"cd || kMDItemTextContent == "\#(safe)*"cd)"#
        }
        return (terms, (match + clauses).joined(separator: " && "))
    }

    static func search(_ text: String, roots: [URL], limit: Int = 12) -> (found: [Found], terms: [String]) {
        let (terms, query) = parse(text)
        guard !query.isEmpty else { return ([], terms) }
        var paths: [String] = []
        for root in roots {
            paths += spotlight(query, in: root)
        }
        var found = rank(paths, terms: terms)
        if found.isEmpty { found = rank(walk(roots, terms: terms), terms: terms) } // Spotlight off or not indexed: walk the folders
        return (Array(found.prefix(limit)), terms)
    }

    static func rank(_ paths: [String], terms: [String]) -> [Found] {
        var seen = Set<String>()
        var out: [Found] = []
        for p in paths where seen.insert(p).inserted {
            guard !p.contains("/Library/"), !p.contains("/."), !p.contains(".app/") else { continue }
            let url = URL(fileURLWithPath: p)
            let name = url.lastPathComponent.lowercased()
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            out.append(Found(url: url, nameMatches: !terms.isEmpty && terms.allSatisfy { name.contains($0) }, modified: modified))
        }
        return out.sorted { ($0.nameMatches ? 0 : 1, -$0.modified.timeIntervalSince1970) < ($1.nameMatches ? 0 : 1, -$1.modified.timeIntervalSince1970) }
    }

    private static func spotlight(_ query: String, in root: URL) -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        p.arguments = ["-onlyin", root.path, query]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    /// Names only, a few levels down.
    static func walk(_ roots: [URL], terms: [String], depth: Int = 4) -> [String] {
        guard !terms.isEmpty else { return [] }
        var out: [String] = []
        let fm = FileManager.default
        for root in roots {
            guard let e = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in e {
                if e.level > depth { e.skipDescendants(); continue }
                let name = url.lastPathComponent.lowercased()
                if terms.allSatisfy({ name.contains($0) }) { out.append(url.path) }
                if out.count > 200 { return out }
            }
        }
        return out
    }
}

final class FindAgent {
    private let query: String
    init(query: String) { self.query = query }

    func run(_ task: BackgroundTask) {
        task.onCancel = { task.cancelRequested = true }
        task.progress("Searching your files…")
        let roots = [FileManager.default.homeDirectoryForCurrentUser]
        DispatchQueue.global(qos: .userInitiated).async { [query] in
            let (found, terms) = Find.search(query, roots: roots)
            DispatchQueue.main.async {
                guard !task.cancelRequested else { return }
                let when = RelativeDateTimeFormatter()
                when.unitsStyle = .short
                guard !found.isEmpty else {
                    task.finish(TaskReport(headline: terms.isEmpty ? "Tell me what to look for, like “the PDF about elasticity”."
                                                                    : "Nothing found for “\(terms.joined(separator: " "))”.",
                                           lines: ["Searched names and the text inside your files. Try fewer or different words."]))
                    return
                }
                task.finish(TaskReport(headline: "Found \(found.count) file\(found.count == 1 ? "" : "s")",
                                       lines: found.map { "\($0.url.lastPathComponent) · \($0.url.deletingLastPathComponent().lastPathComponent) · \(when.localizedString(for: $0.modified, relativeTo: Date()))" },
                                       links: found.map { TaskLink(title: $0.url.lastPathComponent, url: $0.url) }))
            }
        }
    }
}
