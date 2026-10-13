import Foundation
import CryptoKit
import Vision
import AppKit

/// Tidies a folder: sorts files into folders by kind (and month), names screenshots after what's in them, finds duplicates
/// and old installers. It only ever *plans*: the plan is shown, you approve, and `FileSafety` carries it out.
enum Tidy {
    enum Category: String, CaseIterable {
        case screenshot, image, pdf, document, installer, archive, audio, video, code, other

        var folder: String {
            switch self {
            case .screenshot: return "Screenshots"
            case .image: return "Images"
            case .pdf: return "PDFs"
            case .document: return "Documents"
            case .installer: return "Installers"
            case .archive: return "Archives"
            case .audio: return "Audio"
            case .video: return "Videos"
            case .code: return "Code"
            case .other: return ""
            }
        }
        var symbol: String {
            switch self {
            case .screenshot: return "camera.viewfinder"
            case .image: return "photo"
            case .pdf: return "doc.richtext"
            case .document: return "doc.text"
            case .installer: return "shippingbox"
            case .archive: return "archivebox"
            case .audio: return "music.note"
            case .video: return "film"
            case .code: return "chevron.left.forwardslash.chevron.right"
            case .other: return "questionmark.folder"
            }
        }
        /// Sorted into month folders too (these pile up fastest).
        var byMonth: Bool { self == .screenshot || self == .image || self == .pdf || self == .video }
    }

    struct Item {
        var url: URL
        var size: Int
        var created: Date
        var modified: Date
        var category: Category
        var name: String { url.lastPathComponent }
    }

    /// Files touched this recently are left alone (you're probably using them).
    static let recentSeconds: TimeInterval = 10 * 60
    static let oldInstallerDays = 30

    // MARK: Classifying

    private static let imageExts: Set<String> = ["jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tiff", "tif", "bmp", "svg", "raw", "cr2", "nef", "dng"]
    private static let docExts: Set<String> = ["doc", "docx", "pages", "txt", "rtf", "md", "odt", "xls", "xlsx", "numbers", "csv", "ppt", "pptx", "key", "epub", "tex"]
    private static let installerExts: Set<String> = ["dmg", "pkg", "iso"]
    private static let archiveExts: Set<String> = ["zip", "tar", "gz", "tgz", "rar", "7z", "bz2", "xz"]
    private static let audioExts: Set<String> = ["mp3", "m4a", "wav", "aac", "flac", "aiff", "ogg"]
    private static let videoExts: Set<String> = ["mp4", "mov", "m4v", "avi", "mkv", "webm"]
    private static let codeExts: Set<String> = ["py", "js", "ts", "swift", "java", "c", "cpp", "h", "rb", "go", "rs", "json", "yaml", "yml", "html", "css", "sh", "sql", "ipynb"]

    private static let screenshotName = try! NSRegularExpression(pattern: #"^(?:Screenshot|Screen ?Shot|Screen Recording|CleanShot|Capture|Snip)\b"#, options: [.caseInsensitive])

    static func isScreenshotName(_ name: String) -> Bool {
        screenshotName.firstMatch(in: name, range: NSRange(location: 0, length: (name as NSString).length)) != nil
    }

    static func category(forName name: String) -> Category {
        let ext = (name as NSString).pathExtension.lowercased()
        if isScreenshotName(name), imageExts.contains(ext) || videoExts.contains(ext) { return .screenshot }
        if ext == "pdf" { return .pdf }
        if imageExts.contains(ext) { return .image }
        if docExts.contains(ext) { return .document }
        if installerExts.contains(ext) { return .installer }
        if archiveExts.contains(ext) { return .archive }
        if audioExts.contains(ext) { return .audio }
        if videoExts.contains(ext) { return .video }
        if codeExts.contains(ext) { return .code }
        return .other
    }

    // MARK: Scanning

    struct Scan {
        var items: [Item] = []
        var emptyFolders: [URL] = []
        /// What was left alone.
        var skippedRecent = 0
        var skippedOther = 0
    }

    /// Looks at the folder's top level only (folders you made stay as they are).
    static func scan(_ folder: URL, now: Date = Date()) -> Scan {
        let fm = FileManager.default
        var scan = Scan()
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isAliasFileKey, .isPackageKey, .fileSizeKey,
                                      .creationDateKey, .contentModificationDateKey, .isHiddenKey]
        guard let urls = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return scan }
        for url in urls {
            guard (try? FileSafety.checkSource(url)) != nil, let v = try? url.resourceValues(forKeys: Set(keys)) else { scan.skippedOther += 1; continue }
            if v.isSymbolicLink == true || v.isAliasFile == true || v.isPackage == true { scan.skippedOther += 1; continue }
            let modified = v.contentModificationDate ?? .distantPast
            if v.isDirectory == true {
                let contents = (try? fm.contentsOfDirectory(atPath: url.path)) ?? ["x"]
                if contents.allSatisfy({ $0 == ".DS_Store" }), now.timeIntervalSince(modified) > recentSeconds { scan.emptyFolders.append(url) }
                continue
            }
            if now.timeIntervalSince(modified) < recentSeconds { scan.skippedRecent += 1; continue }
            let name = url.lastPathComponent
            if name == ".localized" || name.hasSuffix(".crdownload") || name.hasSuffix(".download") || name.hasSuffix(".part") { scan.skippedOther += 1; continue }
            scan.items.append(Item(url: url, size: v.fileSize ?? 0, created: v.creationDate ?? modified, modified: modified,
                                   category: category(forName: name)))
        }
        return scan
    }

    // MARK: Duplicates

    /// Groups of identical files (same size and same SHA-256). The first of each group (the oldest) is the one to keep.
    static func duplicates(in items: [Item], cancelled: () -> Bool = { false }) -> [[Item]] {
        var bySize: [Int: [Item]] = [:]
        for i in items where i.size > 0 { bySize[i.size, default: []].append(i) }
        var groups: [[Item]] = []
        for (_, same) in bySize where same.count > 1 {
            var byHash: [String: [Item]] = [:]
            for item in same {
                if cancelled() { return groups }
                if let h = hash(item.url) { byHash[h, default: []].append(item) }
            }
            for (_, g) in byHash where g.count > 1 { groups.append(g.sorted { $0.created < $1.created }) }
        }
        return groups
    }

    static func hash(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Reading screenshots

    /// The text in each screenshot (Apple's on-device recognition: free, and nothing leaves the Mac).
    static func readScreenshots(_ items: [Item], progress: (Int, Int) -> Void, cancelled: () -> Bool) -> [URL: String] {
        var out: [URL: String] = [:]
        for (i, item) in items.enumerated() {
            if cancelled() { break }
            if ["png", "jpg", "jpeg", "heic", "tiff", "gif", "webp"].contains(item.url.pathExtension.lowercased()),
               let source = CGImageSourceCreateWithURL(item.url as CFURL, nil),
               let image = CGImageSourceCreateImageAtIndex(source, 0, nil), let text = OCR.text(in: image) {
                out[item.url] = text
            }
            progress(i + 1, items.count)
        }
        return out
    }

    /// A short name from the screenshot's text alone (no Claude): the most title-like line near the top.
    static func heuristicTitle(_ text: String) -> String? {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        func score(_ l: String) -> Int {
            let letters = l.filter(\.isLetter).count
            guard letters >= 8, l.count <= 70, Double(letters) / Double(l.count) > 0.7 else { return 0 }
            return letters
        }
        let best = lines.prefix(12).max { score($0) < score($1) }
        guard let best, score(best) > 0 else { return nil }
        return sanitize(best)
    }

    /// A string that's safe as part of a file name.
    static func sanitize(_ s: String, limit: Int = 60) -> String {
        var t = s.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)).joined(separator: " ")
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
        if t.count > limit { t = String(t.prefix(limit)).trimmingCharacters(in: .whitespaces) }
        return t
    }

    // MARK: Naming with Claude

    static let nameSystem = "You name screenshots from the text found in them. Reply with ONLY a JSON array of strings: one title per "
        + "screenshot, in the same order, each a 3-6 word title (no file extension, no / or : characters), in the language of the text. "
        + "Use an empty string if the text is empty or meaningless."

    /// One request for a batch of screenshots' texts (each clipped).
    static func namePrompt(_ texts: [String]) -> String {
        texts.enumerated().map { i, t in
            "\(i + 1). " + String(t.replacingOccurrences(of: "\n", with: " | ").prefix(220))
        }.joined(separator: "\n")
    }

    /// About how many Claude tokens naming these will use (each batch carries ~3.5k of fixed overhead).
    static func nameTokenEstimate(count: Int, batch: Int = 50) -> Int {
        guard count > 0 else { return 0 }
        return ((count + batch - 1) / batch) * 3500 + count * 85
    }

    /// Titles from Claude for the screenshots that have text. Returns (titles by URL, tokens used).
    static func smartNames(_ texts: [(URL, String)], model: ModelChoice, cancelled: () -> Bool, progress: (Int, Int) -> Void) -> ([URL: String], Int) {
        var out: [URL: String] = [:]
        var tokens = 0
        let batch = 50
        var start = 0
        while start < texts.count, !cancelled() {
            let slice = Array(texts[start..<min(texts.count, start + batch)])
            let r = ClaudeOneShot.runSync(namePrompt(slice.map(\.1)), system: nameSystem, model: model)
            if case .success(let reply) = r {
                tokens += reply.tokens
                if let titles = ClaudeOneShot.json(from: reply.text) as? [Any] {
                    for (i, entry) in slice.enumerated() where i < titles.count {
                        if let t = titles[i] as? String { let clean = sanitize(t); if !clean.isEmpty { out[entry.0] = clean } }
                    }
                }
            }
            start += batch
            progress(min(start, texts.count), texts.count)
        }
        return (out, tokens)
    }

    // MARK: Planning

    /// One name for a file however its URL was made (/var and /private/var are the same place).
    static func key(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }

    static func monthFolder(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    static func screenshotName(_ item: Item, title: String?) -> String {
        guard let title, !title.isEmpty else { return item.name }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        let ext = item.url.pathExtension.isEmpty ? "" : "." + item.url.pathExtension.lowercased()
        return "\(f.string(from: item.created)) \(title)\(ext)"
    }

    /// Builds the plan. `titles` are names for screenshots (from the text on them); without one, the original name stays.
    static func plan(folder: URL, scan: Scan, titles: [URL: String] = [:], screenshotTexts: Int = 0, now: Date = Date()) -> TaskPlan {
        let fm = FileManager.default
        var items = scan.items
        var groups: [PlanGroup] = []
        // Titles are looked up by path (two URLs for the same file aren't always equal).
        let titles = Dictionary(titles.map { (key($0.key), $0.value) }, uniquingKeysWith: { a, _ in a })

        // Duplicates first: they're trashed, not sorted.
        var trashedPaths = Set<String>()
        let dupes = duplicates(in: items)
        if !dupes.isEmpty {
            let extra = dupes.flatMap { $0.dropFirst() }
            trashedPaths = Set(extra.map { $0.url.path })
            let bytes = extra.reduce(0) { $0 + $1.size }
            groups.append(PlanGroup(
                key: "duplicates",
                title: "Move \(extra.count) duplicate\(extra.count == 1 ? "" : "s") to the Trash",
                subtitle: "Identical copies; the oldest of each is kept · \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))",
                symbol: "doc.on.doc", ops: extra.map { .trash($0.url) },
                files: dupes.flatMap { g in g.dropFirst().map { "\($0.name)   (same as \(g[0].name))" } }, removes: true))
        }
        items.removeAll { trashedPaths.contains($0.url.path) }

        // Old installers go to the Trash.
        let cutoff = Calendar.current.date(byAdding: .day, value: -oldInstallerDays, to: now) ?? now
        let oldInstallers = items.filter { $0.category == .installer && $0.modified < cutoff }
        if !oldInstallers.isEmpty {
            groups.append(PlanGroup(key: "old-installers", title: "Move \(oldInstallers.count) old installer\(oldInstallers.count == 1 ? "" : "s") to the Trash",
                                    subtitle: "Not touched for \(oldInstallerDays)+ days · \(ByteCountFormatter.string(fromByteCount: Int64(oldInstallers.reduce(0) { $0 + $1.size }), countStyle: .file))",
                                    symbol: "shippingbox", ops: oldInstallers.map { .trash($0.url) }, files: oldInstallers.map(\.name), removes: true))
            items.removeAll { $0.category == .installer && $0.modified < cutoff }
        }
        if !scan.emptyFolders.isEmpty {
            groups.append(PlanGroup(key: "empty-folders", title: "Move \(scan.emptyFolders.count) empty folder\(scan.emptyFolders.count == 1 ? "" : "s") to the Trash",
                                    symbol: "folder", ops: scan.emptyFolders.map { .trash($0) }, files: scan.emptyFolders.map(\.lastPathComponent), removes: true))
        }

        // Everything else is sorted by kind, then month.
        for category in Category.allCases where category != .other {
            let mine = items.filter { $0.category == category }
            guard !mine.isEmpty else { continue }
            let home = existingFolder(named: category.folder, in: folder) ?? folder.appendingPathComponent(category.folder)
            var ops: [FileSafety.Op] = []
            var files: [String] = []
            var months = Set<String>()
            for item in mine {
                var dest = home
                if category.byMonth {
                    let m = monthFolder(item.created)
                    months.insert(m)
                    dest = dest.appendingPathComponent(m)
                }
                let newName = category == .screenshot ? screenshotName(item, title: titles[key(item.url)]) : item.name
                dest = dest.appendingPathComponent(newName)
                ops.append(.move(item.url, to: dest))
                files.append(newName == item.name ? "\(item.name)  →  \(relative(dest, to: folder))" : "\(item.name)  →  \(relative(dest, to: folder))")
            }
            let renamed = category == .screenshot ? mine.filter { titles[key($0.url)] != nil }.count : 0
            var subtitle = months.isEmpty ? "" : "into month folders, \(months.sorted().first!)" + (months.count > 1 ? " to \(months.sorted().last!)" : "")
            if renamed > 0 { subtitle += (subtitle.isEmpty ? "" : " · ") + "\(renamed) renamed from what's in them" }
            groups.append(PlanGroup(key: "sort:\(category.rawValue)", title: "Sort \(mine.count) \(mine.count == 1 ? singular(category) : category.folder.lowercased()) into “\(category.folder)”",
                                    subtitle: subtitle, symbol: category.symbol, ops: ops, files: files))
        }

        var notes: [String] = []
        let others = items.filter { $0.category == .other }.count
        if others > 0 { notes.append("\(others) file\(others == 1 ? "" : "s") of other kinds left where \(others == 1 ? "it is" : "they are")") }
        if scan.skippedRecent > 0 { notes.append("\(scan.skippedRecent) file\(scan.skippedRecent == 1 ? "" : "s") changed in the last 10 minutes left alone") }
        if scan.skippedOther > 0 { notes.append("\(scan.skippedOther) shortcut, app or hidden item\(scan.skippedOther == 1 ? "" : "s") left alone") }

        var options: [PlanOption] = []
        let shots = items.filter { $0.category == .screenshot }.count
        if shots > 0 && screenshotTexts > 0 {
            let tokens = nameTokenEstimate(count: screenshotTexts)
            options.append(PlanOption(id: "smartNames", title: "Name screenshots by what's in them",
                                      detail: "Claude reads the text found in \(screenshotTexts) screenshot\(screenshotTexts == 1 ? "" : "s") (never the images) · about \(tokens / 1000)k tokens. Off: names from the text, no Claude.",
                                      on: false))
        }

        let total = groups.reduce(0) { $0 + $1.ops.count }
        let headline = total == 0 ? "\(folder.lastPathComponent) is already tidy." : "Tidy \(folder.lastPathComponent): \(total) change\(total == 1 ? "" : "s")"
        _ = fm
        return TaskPlan(headline: headline, groups: groups, options: options, notes: notes)
    }

    private static func singular(_ c: Category) -> String {
        switch c {
        case .screenshot: return "screenshot"
        case .image: return "image"
        case .pdf: return "PDF"
        case .document: return "document"
        case .installer: return "installer"
        case .archive: return "archive"
        case .audio: return "audio file"
        case .video: return "video"
        case .code: return "code file"
        case .other: return "file"
        }
    }

    /// A folder that's already there under another capitalization ("screenshots").
    private static func existingFolder(named name: String, in folder: URL) -> URL? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return nil }
        return names.first { $0.caseInsensitiveCompare(name) == .orderedSame }.map { folder.appendingPathComponent($0) }
    }

    private static func relative(_ url: URL, to folder: URL) -> String {
        let p = url.path, base = folder.path + "/"
        return p.hasPrefix(base) ? String(p.dropFirst(base.count)) : p
    }
}
