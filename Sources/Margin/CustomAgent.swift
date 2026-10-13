import AppKit

/// An agent for any file job you can put in words: "scatter these screenshots around the desktop", "rename my PDFs Paper 1,
/// Paper 2…", "put everything older than a month in an Archive folder". The hard-coded agents (Tidy, Find, Study, Batch) each
/// do one thing; this one asks Claude to *plan* the job out of a small, safe set of steps (move, copy, rename, trash,
/// make a folder, place icons, write a text file), which Margin then checks against its safety rules, shows you, and
/// only runs after you press Allow. Claude never touches a file: it sees names, sizes and ages, never what's inside.
///
/// A big job asks first: before spending tokens on a long file list, the agent says roughly what it will cost.
final class CustomAgent {
    let request: String
    init(request: String) { self.request = request }

    static func title(for request: String) -> String {
        let t = request.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        return t.count > 32 ? String(t.prefix(32)).trimmingCharacters(in: .whitespaces) + "…" : t
    }

    // MARK: - Limits

    /// Above this many tokens (about 200 files) the agent asks before spending them.
    static var gateTokens = 4_000
    /// Above this, the job is too big for one go: the agent asks for a narrower one.
    static var hardLimitTokens = 30_000
    /// Most items shown to Claude in one go.
    static var listLimit = 600
    static let maxSteps = 12
    static let maxFilesPerStep = 500

    /// Asks Claude for a plan (replaced in tests, which never call Claude).
    static var ask: (_ prompt: String, _ system: String) -> Result<ClaudeOneShot.Reply, ClaudeOneShot.Failure> = { prompt, system in
        ClaudeOneShot.runSync(prompt, system: system, model: .haiku, timeout: 120)
    }

    /// The common jobs ("scatter my screenshots", "trash old installers") are planned on this Mac with no Claude call.
    static var localPlanning = true

    /// Where Desktop icons live (replaced in tests).
    static var desktopRoot: URL? = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first

    // MARK: - What Claude is shown

    struct Entry: Identifiable, Equatable {
        let id: Int
        let url: URL
        /// "Desktop"
        let root: String
        /// "Desktop/Screenshots/a.png"
        let rel: String
        let isDir: Bool
        let sizeKB: Int
        let ageDays: Int
        let kind: String
        var selected = false

        var name: String { url.lastPathComponent }
        var ext: String { url.pathExtension.lowercased() }
        var parent: String { (rel as NSString).deletingLastPathComponent }
    }

    struct Listing {
        var entries: [Entry]
        /// Items left out because the list is capped.
        var notShown: Int
        var roots: [URL]

        /// The list as Claude reads it, grouped by folder: `id|name|sizeKB|ageDays` (a trailing / on a name is a folder,
        /// a * before the id means it's selected in Finder).
        var text: String { text(detail: true) }

        /// With `detail` false, names only: sizes and ages are left out unless the request needs them.
        func text(detail: Bool) -> String {
            var order: [String] = []
            var groups: [String: [Entry]] = [:]
            for e in entries {
                if groups[e.parent] == nil { order.append(e.parent) }
                groups[e.parent, default: []].append(e)
            }
            var lines: [String] = []
            for parent in order {
                lines.append(parent + ":")
                for e in groups[parent] ?? [] {
                    let head = "\(e.selected ? "*" : "")\(e.id)|\(e.name)\(e.isDir ? "/" : "")"
                    lines.append(detail ? head + "|\(e.isDir ? "" : String(e.sizeKB))|\(e.ageDays)" : head)
                }
            }
            if notShown > 0 { lines.append("(\(notShown) more items not shown)") }
            return lines.joined(separator: "\n")
        }

        func entry(_ id: Int) -> Entry? { id >= 1 && id <= entries.count && entries[id - 1].id == id ? entries[id - 1] : entries.first { $0.id == id } }
    }

    static func kind(ofExtension ext: String, isDir: Bool) -> String {
        if isDir { return "folder" }
        switch ext {
        case "png", "jpg", "jpeg", "heic", "heif", "gif", "webp", "tif", "tiff", "bmp", "svg", "raw", "cr2": return "image"
        case "pdf": return "pdf"
        case "mov", "mp4", "m4v", "avi", "mkv", "webm": return "video"
        case "mp3", "m4a", "wav", "aac", "flac", "aiff", "ogg": return "audio"
        case "doc", "docx", "txt", "rtf", "md", "pages", "odt", "key", "ppt", "pptx", "xls", "xlsx", "csv", "numbers": return "document"
        case "zip", "rar", "7z", "tar", "gz", "tgz": return "archive"
        case "dmg", "pkg": return "installer"
        default: return "other"
        }
    }

    /// Lists what's in the folders (names, sizes, ages), three levels deep, skipping hidden files, shortcuts and apps.
    static func list(roots: [URL], selected: Set<String> = [], limit: Int = CustomAgent.listLimit, depth: Int = 3,
                     now: Date = Date()) -> Listing {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey, .isAliasFileKey, .isPackageKey]
        var entries: [Entry] = []
        var notShown = 0
        func walk(_ dir: URL, rootName: String, rel: String, level: Int) {
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return }
            for found in items.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
                // Built from the folder we asked about, so every path is spelled the way FileSafety's roots are.
                let url = dir.appendingPathComponent(found.lastPathComponent)
                let v = try? url.resourceValues(forKeys: Set(keys))
                if v?.isSymbolicLink == true || v?.isAliasFile == true { continue }
                if FileSafety.isAppOrLibrary(url.lastPathComponent) { continue }
                // A document package (.pages, .key) is one item, not a folder to look inside.
                let isDir = v?.isDirectory == true && v?.isPackage != true
                if entries.count >= limit { notShown += 1; continue }
                let age = max(0, Int(now.timeIntervalSince(v?.contentModificationDate ?? now) / 86_400))
                let path = rel + "/" + url.lastPathComponent
                entries.append(Entry(id: entries.count + 1, url: url, root: rootName, rel: path, isDir: isDir,
                                     sizeKB: isDir ? 0 : max(0, ((v?.fileSize ?? 0) + 1023) / 1024), ageDays: age,
                                     kind: kind(ofExtension: url.pathExtension.lowercased(), isDir: isDir),
                                     selected: selected.contains(url.standardizedFileURL.resolvingSymlinksInPath().path)))
                if isDir, level < depth { walk(url, rootName: rootName, rel: path, level: level + 1) }
            }
        }
        for root in roots { walk(root, rootName: root.lastPathComponent, rel: root.lastPathComponent, level: 1) }
        return Listing(entries: entries, notShown: notShown, roots: roots)
    }

    /// Which of the allowed folders the request is about (Desktop unless it says otherwise).
    static func scope(for request: String, roots: [URL] = FileSafety.roots) -> [URL] {
        let lower = request.lowercased()
        if lower.contains("everywhere") || lower.contains("all my files") || lower.contains("all folders") { return roots }
        var chosen = roots.filter { lower.contains($0.lastPathComponent.lowercased()) }
        if chosen.isEmpty, let desktop = roots.first(where: { $0.lastPathComponent.lowercased() == "desktop" }) { chosen = [desktop] }
        return chosen.isEmpty ? Array(roots.prefix(1)) : chosen
    }

    /// "these", "the selected files": the request is about what's selected in Finder.
    static func refersToSelection(_ request: String) -> Bool {
        request.range(of: #"\b(?:these|those|selected|selection|highlighted|this (?:one|file|folder|image|picture|photo))\b"#,
                      options: [.regularExpression, .caseInsensitive]) != nil
    }

    // MARK: - Cost

    static let systemPrompt = """
    You plan Mac file jobs. Reply with ONLY JSON, no prose: {"say":"under 8 words","steps":[…]} or {"cannot":"why, one sentence"}.
    The list is grouped by folder: id|name, then |sizeKB|ageDays when shown (a trailing / is a folder, a leading * means selected in Finder). You see names only, never contents.
    Steps run in order. Pick files with "files": a list of ids, "all", "selected", or a filter {"under":"Desktop/Sub","ext":["png"],"name":"text","kind":"image|pdf|video|audio|document|archive|installer|folder","olderThanDays":N,"newerThanDays":N,"largerThanMB":N}. Prefer filters. Filters and ids mean where files were when listed, even in later steps (a later step finds files wherever an earlier one put them).
    - {"do":"move"|"copy","files":…,"to":"Desktop|Downloads|Documents[/Sub]"} (folders are made)
    - {"do":"rename","files":…,"pattern":"Trip {n}"} or {"do":"rename","names":{"12":"New.pdf"}} (extension kept)
    - {"do":"trash","files":…} (Trash only)
    - {"do":"folder","path":"Documents/School"}
    - {"do":"place","files":…,"layout":"scatter|grid|row|column"} (positions icons; files must be directly on the Desktop: move them there first)
    - {"do":"write","path":"Documents/list.txt","text":"…"} (.txt .md .csv .json, new file only)
    Leave out "label". Screenshots are images named "Screenshot…" or "Screen Shot…". "These" with nothing marked * means the likeliest files from the request. Touch only what was asked; if unclear, take the likeliest reading.
    """

    /// Sizes and ages cost tokens for every file; only send them when the request is about age or size.
    static func needsDetail(_ request: String) -> Bool {
        request.range(of: #"\b(?:old|older|oldest|new|newer|newest|recent|recently|last|days?|weeks?|months?|years?|yesterday|big|bigger|biggest|large|larger|largest|small|smaller|smallest|size|sizes|mb|gb|kb|heavy|stale)\b"#,
                      options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// About how many tokens planning this job will cost: the instructions, the list and the request going in (about three
    /// characters a token), plus Claude's fixed overhead and the plan coming back (measured: 1,800 to 2,800 for a small job).
    static func estimateTokens(listing: Listing, request: String) -> Int {
        (systemPrompt.count + listing.text(detail: needsDetail(request)).count + request.count + 80) / 3 + 1_350
    }

    static func tokensLabel(_ tokens: Int) -> String {
        tokens >= 1000 ? "\(String(format: "%.1f", Double(tokens) / 1000).replacingOccurrences(of: ".0", with: ""))k" : "\(tokens)"
    }

    // MARK: - A plan

    struct Step: Identifiable {
        enum Action {
            case move(URL)
            case copy(URL)
            /// The new name for each file.
            case rename([Int: String])
            case trash
            case makeFolder(URL)
            case place(FinderDesktop.Layout)
            case write(URL, String)
        }
        let id = UUID()
        var label: String
        var files: [Entry]
        var action: Action
    }

    struct Plan {
        var say: String
        var steps: [Step]
        /// Things dropped, and why.
        var notes: [String] = []
        var cannot: String?
    }

    // MARK: Choosing files

    static func resolve(_ value: Any?, in listing: Listing) -> [Entry] {
        var out: [Entry] = []
        var seen = Set<Int>()
        func add(_ e: Entry) { if seen.insert(e.id).inserted { out.append(e) } }
        func number(_ any: Any) -> Int? {
            if let n = any as? NSNumber { return n.intValue }
            if let s = any as? String { return Int(s.trimmingCharacters(in: CharacterSet(charactersIn: "* ")) ) }
            return nil
        }
        switch value {
        case let s as String:
            switch s.lowercased() {
            case "all", "everything": listing.entries.filter { !$0.isDir }.forEach(add)
            case "selected", "selection": listing.entries.filter(\.selected).forEach(add)
            default: // "3" or "1,2,3"
                for part in s.split(whereSeparator: { $0 == "," || $0 == " " }) { if let n = Int(part), let e = listing.entry(n) { add(e) } }
            }
        case let list as [Any]:
            for item in list {
                if let n = number(item), let e = listing.entry(n) { add(e) }
                else if item is [String: Any] || item is String { resolve(item, in: listing).forEach(add) }
            }
        case let filter as [String: Any]:
            listing.entries.filter { matches($0, filter) }.forEach(add)
        default: break
        }
        return Array(out.prefix(maxFilesPerStep))
    }

    private static func matches(_ e: Entry, _ f: [String: Any]) -> Bool {
        func strings(_ any: Any?) -> [String] {
            if let s = any as? String { return [s] }
            return (any as? [Any])?.compactMap { $0 as? String } ?? []
        }
        func double(_ any: Any?) -> Double? { (any as? NSNumber)?.doubleValue ?? (any as? String).flatMap(Double.init) }
        let wantsFolders = (f["dirs"] as? Bool) == true || strings(f["kind"]).contains { $0.lowercased() == "folder" }
        if e.isDir && !wantsFolders { return false }
        if !e.isDir && strings(f["kind"]).contains(where: { $0.lowercased() == "folder" }) && strings(f["kind"]).count == 1 { return false }
        if let under = strings(f["under"]).first, !under.isEmpty {
            let u = under.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")).lowercased()
            let rel = e.rel.lowercased(), parent = e.parent.lowercased()
            let rooted = rel.hasPrefix(u + "/") || parent == u || parent.hasPrefix(u + "/")
            // "Screenshots" on its own: any folder with that name along the way.
            let named = !u.contains("/") && parent.split(separator: "/").contains { $0 == Substring(u) }
            if !(rooted || named) { return false }
        }
        let exts = strings(f["ext"]).map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". ")) }
        if !exts.isEmpty, !exts.contains(e.ext) { return false }
        let kinds = strings(f["kind"]).map { $0.lowercased() }.filter { $0 != "folder" }
        if !kinds.isEmpty, !kinds.contains(e.kind) { return false }
        let needle = strings(f["name"]).first ?? strings(f["name_contains"]).first ?? strings(f["nameContains"]).first
        if let needle, !needle.isEmpty, !e.name.localizedCaseInsensitiveContains(needle) { return false }
        if let d = double(f["olderThanDays"]), Double(e.ageDays) < d { return false }
        if let d = double(f["newerThanDays"]), Double(e.ageDays) > d { return false }
        if let mb = double(f["largerThanMB"]), Double(e.sizeKB) < mb * 1024 { return false }
        if let mb = double(f["smallerThanMB"]), Double(e.sizeKB) > mb * 1024 { return false }
        return true
    }

    // MARK: Reading Claude's plan

    /// A folder path like "Desktop/Sub Folder" (or an absolute one) inside the allowed folders; nil otherwise.
    static func resolveFolder(_ raw: String, roots: [URL]) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.hasPrefix("~") { s = NSString(string: s).expandingTildeInPath }
        let root: URL
        let parts: [String]
        if s.hasPrefix("/") {
            let path = URL(fileURLWithPath: s).standardizedFileURL.path
            guard let r = roots.first(where: { path == $0.standardizedFileURL.path || path.hasPrefix($0.standardizedFileURL.path + "/") }) else { return nil }
            root = r
            parts = path.dropFirst(r.standardizedFileURL.path.count).split(separator: "/").map(String.init)
        } else {
            let comps = s.split(separator: "/").map(String.init).filter { $0 != "." }
            guard let first = comps.first, let r = roots.first(where: { $0.lastPathComponent.caseInsensitiveCompare(first) == .orderedSame }) else { return nil }
            root = r
            parts = Array(comps.dropFirst())
        }
        var url = root
        for part in parts {
            guard part != "..", !part.hasPrefix(".") else { return nil }
            let name = cleanName(part)
            guard !name.isEmpty else { return nil }
            url.appendPathComponent(name)
        }
        return url
    }

    /// A file or folder name that's safe to use: no slashes, not hidden, not absurdly long.
    static func cleanName(_ raw: String) -> String {
        var n = raw.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while n.hasPrefix(".") { n.removeFirst() }
        return String(n.prefix(120))
    }

    private static func nonEmptyLabel(_ raw: Any?, fallback: String) -> String {
        let t = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.isEmpty ? fallback : String(t.prefix(90))
    }

    /// Reads the JSON Claude replied with. Anything the safety rules wouldn't allow is dropped, with a note saying so.
    static func parsePlan(_ reply: String, listing: Listing) -> Plan? {
        guard let object = ClaudeOneShot.json(from: reply) as? [String: Any] else { return nil }
        // Files can be sent to any of the allowed folders, not only the ones that were looked at.
        let roots = FileSafety.roots
        let say = (object["say"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let cannot = (object["cannot"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !cannot.isEmpty {
            return Plan(say: say, steps: [], cannot: cannot)
        }
        guard let rawSteps = object["steps"] as? [[String: Any]] else { return nil }
        var plan = Plan(say: say, steps: [])
        for (index, raw) in rawSteps.enumerated() {
            guard plan.steps.count < maxSteps else { plan.notes.append("Only the first \(maxSteps) steps are used."); break }
            let verb = ((raw["do"] as? String) ?? (raw["action"] as? String) ?? "").lowercased()
            let n = index + 1
            let files = resolve(raw["files"] ?? raw["ids"] ?? raw["where"], in: listing)
            func skip(_ why: String) { plan.notes.append("Step \(n) (\(verb.isEmpty ? "?" : verb)) was left out: \(why).") }
            switch verb {
            case "move", "copy":
                guard !files.isEmpty else { skip("no matching files"); continue }
                guard let dest = (raw["to"] as? String).flatMap({ resolveFolder($0, roots: roots) }) else {
                    skip("its destination isn't inside Desktop, Downloads or Documents"); continue
                }
                let word = verb == "move" ? "Move" : "Copy"
                plan.steps.append(Step(label: nonEmptyLabel(raw["label"], fallback: "\(word) \(files.count) item\(files.count == 1 ? "" : "s") to \(dest.lastPathComponent)"),
                                       files: files, action: verb == "move" ? .move(dest) : .copy(dest)))
            case "rename":
                var names: [Int: String] = [:]
                var targets = files
                if let map = raw["names"] as? [String: Any] {
                    targets = []
                    for (key, value) in map {
                        guard let id = Int(key.trimmingCharacters(in: CharacterSet(charactersIn: "* "))), let e = listing.entry(id),
                              let new = value as? String else { continue }
                        names[id] = new
                        targets.append(e)
                    }
                    targets.sort { $0.id < $1.id }
                } else if let pattern = raw["pattern"] as? String, !pattern.isEmpty {
                    for (i, e) in targets.enumerated() {
                        let base = pattern.contains("{n}") ? pattern.replacingOccurrences(of: "{n}", with: String(i + 1)) : pattern + " \(i + 1)"
                        names[e.id] = base
                    }
                }
                guard !targets.isEmpty, !names.isEmpty else { skip("nothing to rename"); continue }
                // Keep the extension unless the new name brings its own.
                for e in targets {
                    guard var new = names[e.id].map(cleanName), !new.isEmpty else { names[e.id] = nil; continue }
                    if (new as NSString).pathExtension.isEmpty, !e.ext.isEmpty, !e.isDir { new += "." + e.url.pathExtension }
                    names[e.id] = new
                }
                targets = targets.filter { names[$0.id] != nil }
                guard !targets.isEmpty else { skip("no usable names"); continue }
                plan.steps.append(Step(label: nonEmptyLabel(raw["label"], fallback: "Rename \(targets.count) item\(targets.count == 1 ? "" : "s")"),
                                       files: targets, action: .rename(names)))
            case "trash", "delete", "remove":
                guard !files.isEmpty else { skip("no matching files"); continue }
                plan.steps.append(Step(label: nonEmptyLabel(raw["label"], fallback: "Move \(files.count) item\(files.count == 1 ? "" : "s") to the Trash"),
                                       files: files, action: .trash))
            case "folder", "mkdir", "create_folder", "makefolder":
                guard let url = (raw["path"] as? String ?? raw["to"] as? String).flatMap({ resolveFolder($0, roots: roots) }),
                      !roots.contains(where: { $0.standardizedFileURL.path == url.standardizedFileURL.path }) else {
                    skip("that folder isn't inside Desktop, Downloads or Documents"); continue
                }
                plan.steps.append(Step(label: nonEmptyLabel(raw["label"], fallback: "Make the folder “\(url.lastPathComponent)”"), files: [], action: .makeFolder(url)))
            case "place", "arrange", "scatter":
                guard !files.isEmpty else { skip("no matching files"); continue }
                let layoutName = ((raw["layout"] as? String) ?? (verb == "scatter" ? "scatter" : "grid")).lowercased()
                let layout = FinderDesktop.Layout(rawValue: layoutName) ?? .scatter
                plan.steps.append(Step(label: nonEmptyLabel(raw["label"], fallback: "\(layout == .scatter ? "Scatter" : "Arrange") \(files.count) icon\(files.count == 1 ? "" : "s") on the Desktop"),
                                       files: files, action: .place(layout)))
            case "write", "create_file", "file":
                guard let path = raw["path"] as? String, let text = raw["text"] as? String ?? raw["content"] as? String, !text.isEmpty else {
                    skip("it has no path or text"); continue
                }
                let ns = path as NSString
                let folder = resolveFolder(ns.deletingLastPathComponent.isEmpty ? "" : ns.deletingLastPathComponent, roots: roots)
                let ext = ns.pathExtension.lowercased()
                guard let folder, ["txt", "md", "csv", "json"].contains(ext), text.count <= 20_000 else {
                    skip("it isn't a short .txt, .md, .csv or .json file inside Desktop, Downloads or Documents"); continue
                }
                let file = folder.appendingPathComponent(cleanName(ns.lastPathComponent))
                plan.steps.append(Step(label: nonEmptyLabel(raw["label"], fallback: "Write “\(file.lastPathComponent)”"), files: [], action: .write(file, text)))
            default:
                skip("Margin can't do “\(verb)”")
            }
        }
        return plan
    }

    // MARK: Showing a plan

    private static func shortPath(_ url: URL) -> String {
        let roots = FileSafety.roots
        for r in roots where url.standardizedFileURL.path.hasPrefix(r.standardizedFileURL.path) {
            let rest = String(url.standardizedFileURL.path.dropFirst(r.standardizedFileURL.path.count))
            return r.lastPathComponent + rest
        }
        return url.lastPathComponent
    }

    static func group(for step: Step, index: Int) -> PlanGroup {
        var lines: [String] = []
        var subtitle = ""
        var symbol = "folder"
        var removes = false
        switch step.action {
        case .move(let to):
            subtitle = "to " + shortPath(to)
            lines = step.files.map { "\($0.rel)  →  \(shortPath(to))" }
        case .copy(let to):
            subtitle = "copies go to " + shortPath(to)
            symbol = "doc.on.doc"
            lines = step.files.map { "\($0.rel)  →  \(shortPath(to))" }
        case .rename(let names):
            symbol = "pencil"
            lines = step.files.map { "\($0.name)  →  \(names[$0.id] ?? $0.name)" }
        case .trash:
            symbol = "trash"
            removes = true
            subtitle = "They can be put back with Undo"
            lines = step.files.map(\.rel)
        case .makeFolder(let url):
            symbol = "folder.badge.plus"
            lines = [shortPath(url)]
        case .place(let layout):
            symbol = "square.grid.3x3"
            subtitle = layout == .scatter ? "at random spots on the Desktop" : "in a \(layout.rawValue) on the Desktop"
            lines = step.files.map(\.name)
        case .write(let url, let text):
            symbol = "doc.badge.plus"
            subtitle = "\(text.count) characters"
            lines = [shortPath(url)]
        }
        return PlanGroup(key: "step\(index)", title: step.label, subtitle: subtitle, symbol: symbol, ops: [], files: lines, removes: removes)
    }

    // MARK: - Running

    private var steps: [Step] = []
    private var ledgerBox: FileSafety.Ledger?

    func run(_ task: BackgroundTask) {
        task.onCancel = { [weak task] in task?.cancelRequested = true }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            task.progress("Looking at your files…")
            let local = Self.localPlanning ? LocalJobs.interpret(request) : nil
            let roots = local.map { LocalJobs.roots(for: $0) } ?? Self.scope(for: request)
            var selectedPaths = Set<String>()
            var selectionNote: String?
            if Self.refersToSelection(request) {
                let selection = FinderDesktop.selection()
                for p in selection.paths where FileSafety.root(containing: URL(fileURLWithPath: p)) != nil {
                    selectedPaths.insert(URL(fileURLWithPath: p).standardizedFileURL.resolvingSymlinksInPath().path)
                }
                if selection.needsPermission { selectionNote = "I couldn't see what you've selected in Finder: allow Margin to control Finder in System Settings → Privacy & Security → Automation." }
            }
            let listing = Self.list(roots: roots, selected: selectedPaths)
            if task.cancelRequested { return finishCancelled(task) }
            guard !listing.entries.isEmpty else {
                return DispatchQueue.main.async {
                    task.finish(TaskReport(headline: "There's nothing in \(roots.map(\.lastPathComponent).joined(separator: " or ")) to work with"))
                }
            }
            // The common jobs are worked out right here: no Claude, no tokens.
            if let job = local, let outcome = LocalJobs.build(job, listing: listing, desktop: Self.desktopRoot) {
                return DispatchQueue.main.async { [self] in
                    guard !task.cancelRequested else { return finishCancelled(task) }
                    switch outcome {
                    case .plan(let plan): present(task, plan: plan, listing: listing, used: 0, selectionNote: selectionNote, onMac: true)
                    case .nothing(let message): task.finish(TaskReport(headline: message))
                    }
                }
            }
            let estimate = Self.estimateTokens(listing: listing, request: request)
            if estimate > Self.hardLimitTokens {
                return DispatchQueue.main.async {
                    task.fail("That's too much for one job (about \(Self.tokensLabel(estimate)) tokens to read \(listing.entries.count + listing.notShown) items). Try a narrower one, like “in my Downloads folder” or “just the screenshots”.")
                }
            }
            if estimate >= Self.gateTokens {
                // A bigger job: say what it costs and wait for a yes before reading it all out to Claude.
                DispatchQueue.main.async { [self] in
                    task.gate = TaskGate(
                        headline: "This is a bigger job",
                        detail: "To plan it, Claude would read the names, sizes and ages of \(listing.entries.count) items (never what's inside them), about \(Self.tokensLabel(estimate)) tokens. That's more than a small request (about double if Claude has to try twice). Go ahead?",
                        summary: "≈\(Self.tokensLabel(estimate)) tokens · \(listing.entries.count) items")
                    task.detail = "Waiting for your OK (about \(Self.tokensLabel(estimate)) tokens)"
                    task.state = .needsApproval
                    task.onApprove = { [self] t in
                        t.gate = nil
                        t.detail = "Asking Claude…"
                        t.state = .working
                        DispatchQueue.global(qos: .userInitiated).async { self.plan(t, listing: listing, estimate: estimate, selectionNote: selectionNote) }
                    }
                }
                return
            }
            plan(task, listing: listing, estimate: estimate, selectionNote: selectionNote)
        }
    }

    private func finishCancelled(_ task: BackgroundTask) {
        DispatchQueue.main.async {
            guard task.state != .cancelled else { return }
            task.state = .cancelled
            task.detail = "Cancelled · nothing was changed"
        }
    }

    /// Asks Claude for the plan and puts it up for your approval. Runs off the main thread.
    private func plan(_ task: BackgroundTask, listing: Listing, estimate: Int, selectionNote: String?) {
        task.progress("Asking Claude for a plan…")
        let detail = Self.needsDetail(request)
        let prompt = "Request: \(request)\n" + (detail ? "Today is \(Date().formatted(.iso8601.year().month().day())).\n" : "") + "\n" + listing.text(detail: detail)
        var tokens = 0
        var reply = Self.ask(prompt, Self.systemPrompt)
        var parsed: Plan?
        if case .success(let r) = reply {
            tokens += r.tokens
            parsed = Self.parsePlan(r.text, listing: listing)
            if parsed == nil, !task.cancelRequested { // not valid JSON: one more try, saying so
                task.progress("Asking Claude again…")
                reply = Self.ask(prompt + "\n\nYour last reply wasn't valid JSON. Reply with ONLY the JSON object.", Self.systemPrompt)
                if case .success(let r2) = reply { tokens += r2.tokens; parsed = Self.parsePlan(r2.text, listing: listing) }
            }
        }
        if task.cancelRequested { return finishCancelled(task) }
        let used = tokens
        DispatchQueue.main.async { [self] in
            task.tokens += used
            guard !task.cancelRequested else { return finishCancelled(task) }
            guard case .success = reply else {
                if case .failure(let f) = reply { task.fail(f.localizedDescription) }
                return
            }
            guard let plan = parsed else { return task.fail("I couldn't understand Claude's plan. Try saying it a different way.") }
            if let cannot = plan.cannot { return task.fail("Can't do that one: " + cannot) }
            guard !plan.steps.isEmpty else {
                return task.fail(plan.notes.first ?? "Claude didn't find anything to do for that.")
            }
            present(task, plan: plan, listing: listing, used: used, selectionNote: selectionNote, onMac: false)
        }
    }

    /// Puts a plan up for your approval (main thread).
    private func present(_ task: BackgroundTask, plan: Plan, listing: Listing, used: Int, selectionNote: String?, onMac: Bool) {
        steps = plan.steps
        var notes = plan.notes
        if let selectionNote { notes.insert(selectionNote, at: 0) }
        if listing.notShown > 0 { notes.append("Only the first \(listing.entries.count) items were looked at (\(listing.notShown) more were left out).") }
        if plan.steps.contains(where: { if case .place = $0.action { return true } else { return false } }) {
            notes.append("To keep icons where they're put, Finder's Sort By is switched to None (Undo puts it back). macOS may ask to let Margin control Finder.")
        }
        notes.append(onMac ? "Planned on your Mac: no Claude tokens used." : "Claude read names only, about \(Self.tokensLabel(used)) tokens.")
        let files = plan.steps.reduce(0) { $0 + max($1.files.count, 1) }
        var shown = TaskPlan(headline: plan.say.isEmpty ? "\(plan.steps.count) step\(plan.steps.count == 1 ? "" : "s")" : plan.say,
                             groups: plan.steps.enumerated().map { Self.group(for: $1, index: $0) }, notes: notes)
        shown.summaryOverride = "\(plan.steps.count) step\(plan.steps.count == 1 ? "" : "s") · \(files) item\(files == 1 ? "" : "s")"
        task.plan = shown
        task.detail = "Waiting for your OK"
        task.state = .needsApproval
        task.onApprove = { [self] t in approve(t) }
    }

    // MARK: Doing it

    private func approve(_ task: BackgroundTask) {
        guard let plan = task.plan else { return }
        let chosen = steps.enumerated().filter { i, _ in plan.groups.first { $0.key == "step\(i)" }?.enabled ?? false }.map(\.element)
        task.plan = nil
        task.state = .working
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            var ledger = FileSafety.Ledger(title: task.title)
            let outcome = Self.execute(chosen, ledger: &ledger, progress: { done, total in
                task.progress("Working: \(done) of \(total)", Double(done) / Double(max(1, total)))
            }, cancelled: { task.cancelRequested })
            FileSafety.save(ledger)
            ledgerBox = ledger
            DispatchQueue.main.async { [self] in
                var headline = "Done: " + (outcome.parts.isEmpty ? "nothing needed changing" : outcome.parts.joined(separator: ", "))
                if outcome.cancelled { headline = "Stopped. " + headline }
                var lines = outcome.notes
                if !outcome.skipped.isEmpty {
                    lines.append("Skipped \(outcome.skipped.count): " + outcome.skipped.prefix(3).map { "\($0.name) (\($0.reason))" }.joined(separator: "; "))
                }
                lines.append(task.tokens > 0 ? "Claude used about \(Self.tokensLabel(task.tokens)) tokens to plan this." : "Planned on your Mac: no Claude tokens used.")
                task.onUndo = { [self] t in
                    DispatchQueue.global().async {
                        var l = self.ledgerBox ?? ledger
                        let result = FileSafety.undo(&l)
                        FileSafety.save(l)
                        DispatchQueue.main.async {
                            t.undone = true
                            t.canUndo = false
                            t.detail = "Undone: put back \(result.restored)" + (result.couldNotRestore.isEmpty ? "" : ", \(result.couldNotRestore.count) couldn't be")
                            t.report = TaskReport(headline: t.detail, lines: result.couldNotRestore.isEmpty ? [] : ["Not restored (moved or deleted since): " + result.couldNotRestore.prefix(5).joined(separator: ", ")])
                        }
                    }
                }
                task.finish(TaskReport(headline: headline, lines: lines), canUndo: !ledger.records.isEmpty)
            }
        }
    }

    struct ExecutionOutcome {
        var parts: [String] = []
        var notes: [String] = []
        var skipped: [(name: String, reason: String)] = []
        var cancelled = false
    }

    /// Runs the steps in order. `current` follows each file as it's moved or renamed, so a later step finds it where it went.
    static func execute(_ steps: [Step], ledger: inout FileSafety.Ledger, progress: (Int, Int) -> Void = { _, _ in },
                        cancelled: () -> Bool = { false }) -> ExecutionOutcome {
        let fm = FileManager.default
        var outcome = ExecutionOutcome()
        var current: [Int: URL] = [:] // entry id → where it is now (absent: trashed)
        var gone = Set<Int>()
        func location(_ e: Entry) -> URL? { gone.contains(e.id) ? nil : (current[e.id] ?? e.url) }
        let total = max(1, steps.reduce(0) { $0 + max($1.files.count, 1) })
        var done = 0
        var moved = 0, copied = 0, renamed = 0, trashed = 0, folders = 0, placed = 0, wrote = 0

        func fail(_ name: String, _ error: Error) { outcome.skipped.append((name, error.localizedDescription)) }

        stepLoop: for step in steps {
            switch step.action {
            case .move(let folder), .copy(let folder):
                let isMove: Bool = { if case .move = step.action { return true } else { return false } }()
                for e in step.files {
                    if cancelled() { outcome.cancelled = true; break stepLoop }
                    done += 1; progress(done, total)
                    guard let src = location(e) else { continue }
                    do {
                        let op: FileSafety.Op = isMove ? .move(src, to: folder.appendingPathComponent(src.lastPathComponent))
                                                       : .copy(src, to: folder.appendingPathComponent(src.lastPathComponent))
                        if let result = try FileSafety.perform(op, ledger: &ledger) {
                            if isMove { current[e.id] = result; moved += 1 } else { copied += 1 }
                        }
                    } catch { fail(e.name, error) }
                }
            case .rename(let names):
                for e in step.files {
                    if cancelled() { outcome.cancelled = true; break stepLoop }
                    done += 1; progress(done, total)
                    guard let src = location(e), let new = names[e.id] else { continue }
                    do {
                        let op = FileSafety.Op.move(src, to: src.deletingLastPathComponent().appendingPathComponent(new))
                        if let result = try FileSafety.perform(op, ledger: &ledger) { current[e.id] = result; renamed += 1 }
                    } catch { fail(e.name, error) }
                }
            case .trash:
                for e in step.files {
                    if cancelled() { outcome.cancelled = true; break stepLoop }
                    done += 1; progress(done, total)
                    guard let src = location(e) else { continue }
                    do {
                        try FileSafety.perform(.trash(src), ledger: &ledger)
                        gone.insert(e.id)
                        trashed += 1
                    } catch { fail(e.name, error) }
                }
            case .makeFolder(let url):
                done += 1; progress(done, total)
                do {
                    try FileSafety.checkDestination(url)
                    var isDir: ObjCBool = false
                    if !(fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue) {
                        var missing: [URL] = []
                        var probe = url
                        while !fm.fileExists(atPath: probe.path), FileSafety.root(containing: probe) != nil { missing.append(probe); probe = probe.deletingLastPathComponent() }
                        for dir in missing.reversed() {
                            try fm.createDirectory(at: dir, withIntermediateDirectories: false)
                            ledger.records.append(.init(kind: .createdFolder, original: dir.path, now: dir.path))
                        }
                        folders += 1
                    }
                } catch { fail(url.lastPathComponent, error) }
            case .write(let url, let text):
                done += 1; progress(done, total)
                do {
                    try FileSafety.createFile(Data(text.utf8), at: url, ledger: &ledger)
                    wrote += 1
                } catch { fail(url.lastPathComponent, error) }
            case .place(let layout):
                if cancelled() { outcome.cancelled = true; break stepLoop }
                guard let desktop = desktopRoot?.standardizedFileURL.resolvingSymlinksInPath() else { break }
                var targets: [URL] = []
                for e in step.files {
                    done += 1; progress(done, total)
                    guard let loc = location(e), fm.fileExists(atPath: loc.path) else { continue }
                    if !FinderDesktop.isSafeName(loc.lastPathComponent) {
                        outcome.skipped.append((e.name, "its name can't be sent to Finder"))
                    } else if loc.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path == desktop.path {
                        targets.append(loc)
                    } else {
                        outcome.skipped.append((e.name, "only icons directly on the Desktop can be placed"))
                    }
                }
                guard !targets.isEmpty else { break }
                var generator = SystemRandomNumberGenerator()
                let points = FinderDesktop.positions(for: layout, count: targets.count, in: FinderDesktop.usableArea(), using: &generator)
                let placements = zip(targets, points).map { FinderDesktop.Placement(name: $0.lastPathComponent, x: Int($1.x.rounded()), y: Int($1.y.rounded())) }
                let result = FinderDesktop.place(placements)
                if result.needsPermission {
                    outcome.notes.append("Margin isn't allowed to control Finder yet, so nothing was placed. Turn it on in System Settings → Privacy & Security → Automation (Margin → Finder), then try again.")
                    break
                }
                let failedNames = Set(result.failed.map(\.name))
                for f in result.failed { outcome.skipped.append((f.name, f.reason)) }
                for old in result.old {
                    ledger.records.append(.init(kind: .positioned, original: desktop.appendingPathComponent(old.name).path, now: "\(old.x),\(old.y)"))
                }
                if let arrangement = result.arrangement, !arrangement.isEmpty, arrangement != "not arranged",
                   !ledger.records.contains(where: { $0.kind == .arrangement }) {
                    ledger.records.append(.init(kind: .arrangement, original: "desktop", now: arrangement))
                }
                placed += placements.filter { !failedNames.contains($0.name) }.count
            }
        }
        var parts: [String] = []
        if moved > 0 { parts.append("moved \(moved)") }
        if copied > 0 { parts.append("copied \(copied)") }
        if renamed > 0 { parts.append("renamed \(renamed)") }
        if trashed > 0 { parts.append("trashed \(trashed)") }
        if folders > 0 { parts.append(folders == 1 ? "made a folder" : "made \(folders) folders") }
        if wrote > 0 { parts.append("wrote \(wrote)") }
        if placed > 0 { parts.append("placed \(placed)") }
        outcome.parts = parts
        return outcome
    }
}
