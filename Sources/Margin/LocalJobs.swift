import Foundation

/// The file jobs people ask for most, planned on this Mac by rules, so they cost no Claude tokens at all:
/// "scatter my screenshots", "arrange these in a grid", "trash the old installers in Downloads", "put my PDFs in a Papers
/// folder". Anything with a twist ("rename them…", "only the ones from last week and bigger than 5 MB") isn't
/// recognised here and goes to Claude as before. The plan is built from the same steps and checked by the same safety
/// rules as one Claude makes, and it's shown to you the same way.
enum LocalJobs {
    enum Object: Equatable {
        case screenshots, installers, pdfs, zips, images, videos, documents, allFiles, selection

        var words: String {
            switch self {
            case .screenshots: return "screenshots"
            case .installers: return "installers"
            case .pdfs: return "PDFs"
            case .zips: return "archives"
            case .images: return "images"
            case .videos: return "videos"
            case .documents: return "documents"
            case .allFiles: return "files"
            case .selection: return "selected items"
            }
        }
    }

    enum Action: Equatable {
        case place(FinderDesktop.Layout)
        case trash
        case move(folder: String)
    }

    struct Job: Equatable {
        var action: Action
        var object: Object
        var olderDays: Int?
        /// "Downloads", "Desktop", "Documents" when the request names one.
        var rootName: String?
        /// "these": use what's selected in Finder.
        var wantsSelection: Bool
        /// What to use if nothing is selected.
        var fallback: Object?
    }

    enum Outcome {
        case plan(CustomAgent.Plan)
        /// Understood, but there's nothing to do it to: the message says so.
        case nothing(String)
    }

    private static func has(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    // MARK: Understanding the words

    static func object(in text: String) -> Object? {
        if has(#"\bscreen ?shots?\b"#, text) { return .screenshots }
        if has(#"\b(?:dmgs?|installers?|disk images?)\b"#, text) { return .installers }
        if has(#"\bpdfs?\b"#, text) { return .pdfs }
        if has(#"\b(?:zips?|zip files?|archives?)\b"#, text) { return .zips }
        if has(#"\b(?:images?|photos?|pictures?|pngs?|jpe?gs?|heic)\b"#, text) { return .images }
        if has(#"\b(?:videos?|movies?|recordings?)\b"#, text) { return .videos }
        if has(#"\b(?:documents? files|word docs?|docx?|text files?)\b"#, text) { return .documents }
        if has(#"\b(?:icons?|files|everything|stuff|items)\b"#, text) { return .allFiles }
        return nil
    }

    /// nil when the request isn't one of the simple, common jobs.
    static func interpret(_ raw: String) -> Job? {
        let text = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t.!?"))
        guard !text.isEmpty else { return nil }
        // A twist the rules don't follow: leave it to Claude.
        if has(#"\b(?:rename|except|containing|duplicates?|sort|group|by (?:date|type|kind|name|size|month|year)|larger|bigger|smaller|largest|biggest|mb|gb|then|half)\b"#, text) { return nil }
        if has(#"\b(?:called|named)\b"#, text), !has(#"\bfolder\s+(?:called|named)\b"#, text) { return nil }

        var rootName: String?
        if let m = text.range(of: #"\b(?:in|on|from|under|inside)\s+(?:my |the )?(downloads?|desktop|documents)\b"#, options: [.regularExpression, .caseInsensitive]) {
            let word = text[m].lowercased()
            rootName = word.contains("download") ? "Downloads" : word.contains("document") ? "Documents" : "Desktop"
        } else if has(#"\bmy (?:downloads|documents)\b"#, text) || has(#"\b(?:downloads|desktop) folder\b"#, text) {
            rootName = has(#"downloads"#, text) ? "Downloads" : has(#"documents"#, text) ? "Documents" : "Desktop"
        }

        // Older than…
        var older: Int?
        if let m = text.range(of: #"\b(?:older|more) than (\d+|a|an|one|two|three|a couple of)\s*(day|week|month|year)s?\b"#, options: [.regularExpression, .caseInsensitive]) {
            let part = String(text[m]).lowercased()
            let nums = ["a": 1, "an": 1, "one": 1, "two": 2, "three": 3]
            let n = part.split(separator: " ").compactMap { Int($0) ?? nums[String($0)] }.first ?? 1
            let unit = part.contains("year") ? 365 : part.contains("month") ? 30 : part.contains("week") ? 7 : 1
            older = n * unit
        } else if has(#"\bold(?:er)?\s+(?:dmgs?|installers?|zips?|archives?|files|pdfs?|screenshots?)\b"#, text) {
            older = 30
        }

        let wantsSelection = CustomAgent.refersToSelection(text)
        var obj = object(in: text)
        var fallback: Object?
        if wantsSelection { fallback = obj; obj = .selection }
        guard let object = obj else { return nil }

        // The action
        if has(#"\b(?:scatter|spread|shuffle|strew)\b"#, text) {
            return Job(action: .place(.scatter), object: object, olderDays: older, rootName: rootName, wantsSelection: wantsSelection, fallback: fallback)
        }
        if has(#"\b(?:arrange|line up|lay out|align|straighten)\b"#, text) {
            let layout: FinderDesktop.Layout = has(#"\bcolumn\b|\bvertical"#, text) ? .column : has(#"\brow\b|\bline\b|\bhorizontal"#, text) ? .row : .grid
            return Job(action: .place(layout), object: object, olderDays: older, rootName: rootName, wantsSelection: wantsSelection, fallback: fallback)
        }
        if has(#"\b(?:to|in|into) (?:the )?(?:trash|bin)\b"#, text) || has(#"\b(?:trash|delete|remove|throw (?:away|out)|get rid of)\b"#, text) {
            guard object != .allFiles else { return nil } // never "delete everything" on a rule
            return Job(action: .trash, object: object, olderDays: older, rootName: rootName, wantsSelection: wantsSelection, fallback: fallback)
        }
        if has(#"\b(?:put|move|file|store|drop|stick|shift)\b"#, text), let folder = destination(in: text) {
            guard object != .allFiles || wantsSelection else { return nil }
            return Job(action: .move(folder: folder), object: object, olderDays: older, rootName: rootName == folder ? nil : rootName, wantsSelection: wantsSelection, fallback: fallback)
        }
        return nil
    }

    /// "…into a Papers folder", "…to Archive/2025", "…in a folder called Econ": the folder's name.
    static func destination(in raw: String) -> String? {
        let text = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t.!?"))
        let pattern = #"\b(?:in|into|to|inside|onto)\s+(?:(?:a|an|the|my|new)\s+)*(?:folder\s+(?:called|named)\s+)?([A-Za-z0-9][A-Za-z0-9 _\-/]{0,40}?)(?:\s+folder)?(?:\s+(?:in|on|under)\s+(?:my\s+)?(?:desktop|downloads|documents))?$"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        var name = String(text[r]).trimmingCharacters(in: .whitespaces)
        let lower = name.lowercased()
        // Not folders: "a new place", "the desktop" handled as a root, words that are really something else.
        if ["trash", "bin", "the trash", "a folder", "folder", "it", "there", "them", "one", "me"].contains(lower) { return nil }
        if name.contains("..") || name.hasPrefix(".") { return nil }
        if name == lower { name = name.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ") }
        return name
    }

    /// Which of the allowed folders to look in.
    static func roots(for job: Job, all: [URL] = FileSafety.roots) -> [URL] {
        func named(_ n: String) -> URL? { all.first { $0.lastPathComponent.caseInsensitiveCompare(n) == .orderedSame } }
        if let n = job.rootName, let r = named(n) { return [r] }
        switch job.action {
        case .place: return named("Desktop").map { [$0] } ?? Array(all.prefix(1))
        default: return job.object == .screenshots ? (named("Desktop").map { [$0] } ?? all) : all
        }
    }

    // MARK: Making the plan

    private static func matches(_ e: CustomAgent.Entry, _ object: Object) -> Bool {
        if e.isDir { return false }
        switch object {
        case .screenshots: return e.kind == "image" && (e.name.lowercased().hasPrefix("screenshot") || e.name.lowercased().hasPrefix("screen shot"))
        case .installers: return ["dmg", "pkg"].contains(e.ext)
        case .pdfs: return e.ext == "pdf"
        case .zips: return e.kind == "archive"
        case .images: return e.kind == "image"
        case .videos: return e.kind == "video"
        case .documents: return e.kind == "document"
        case .allFiles: return true
        case .selection: return e.selected
        }
    }

    private static func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)" }

    static func build(_ job: Job, listing: CustomAgent.Listing, desktop: URL?, roots: [URL] = FileSafety.roots) -> Outcome? {
        var entries = listing.entries.filter { e in
            if e.isDir { return job.object == .selection && e.selected }
            return matches(e, job.object)
        }
        var object = job.object
        if job.object == .selection, entries.isEmpty, let fallback = job.fallback {
            object = fallback
            entries = listing.entries.filter { matches($0, fallback) }
        }
        if let days = job.olderDays { entries = entries.filter { $0.ageDays >= days } }
        // "Everything" on a rule is only for arranging what's lying loose on the Desktop, never for moving or deleting.
        if object == .allFiles { entries = entries.filter { $0.parent == $0.root } }
        let noun = object == .selection ? "selected items" : object.words
        if entries.isEmpty {
            let where_ = listing.roots.map(\.lastPathComponent).joined(separator: " or ")
            if job.wantsSelection, object == .selection { return .nothing("Nothing is selected in Finder. Select the items first, or say which ones, like “my screenshots”.") }
            return .nothing("I didn't find any \(noun)\(job.olderDays.map { " older than \($0) days" } ?? "") in \(where_).")
        }
        let n = entries.count
        var plan = CustomAgent.Plan(say: "", steps: [])
        func label(_ verb: String, _ tail: String) -> String { "\(verb) \(plural(n, n == 1 ? singular(noun) : noun)) \(tail)" }

        switch job.action {
        case .place(let layout):
            guard let desktop else { return nil }
            let desktopPath = desktop.standardizedFileURL.resolvingSymlinksInPath().path
            guard entries.allSatisfy({ $0.url.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(desktopPath + "/") }) else { return nil }
            let nested = entries.filter { $0.url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path != desktopPath }
            if !nested.isEmpty {
                plan.steps.append(.init(label: "Move \(nested.count) \(singularIf(nested.count, noun)) onto the Desktop", files: nested, action: .move(desktop)))
            }
            let verb = layout == .scatter ? "Scatter" : "Arrange"
            plan.steps.append(.init(label: "\(verb) \(n) icon\(n == 1 ? "" : "s") on the Desktop", files: entries, action: .place(layout)))
            plan.say = layout == .scatter ? "Scatter \(n) \(singularIf(n, noun)) around the Desktop." : "Arrange \(n) \(singularIf(n, noun)) in a \(layout.rawValue) on the Desktop."
        case .trash:
            plan.steps.append(.init(label: label("Move", "to the Trash"), files: entries, action: .trash))
            plan.say = "Move \(n) \(singularIf(n, noun)) to the Trash."
        case .move(let folder):
            let rootName = job.rootName ?? entries[0].root
            let isRoot = roots.contains { $0.lastPathComponent.caseInsensitiveCompare(folder) == .orderedSame }
            let path = isRoot ? folder : rootName + "/" + folder
            guard let dest = CustomAgent.resolveFolder(path, roots: roots) else {
                return .nothing("“\(folder)” isn't a place I can put files: only folders inside Desktop, Downloads and Documents.")
            }
            let destPath = dest.standardizedFileURL.resolvingSymlinksInPath().path
            let toMove = entries.filter { $0.url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path != destPath }
            guard !toMove.isEmpty else { return .nothing("They're already in \(dest.lastPathComponent).") }
            let exists = FileManager.default.fileExists(atPath: dest.path)
            if !isRoot, !exists { plan.steps.append(.init(label: "Make the folder “\(dest.lastPathComponent)”", files: [], action: .makeFolder(dest))) }
            plan.steps.append(.init(label: "Move \(toMove.count) \(singularIf(toMove.count, noun)) to \(dest.lastPathComponent)", files: toMove, action: .move(dest)))
            plan.say = "Put \(toMove.count) \(singularIf(toMove.count, noun)) in \(dest.lastPathComponent)."
        }
        return .plan(plan)
    }

    private static func singular(_ noun: String) -> String {
        switch noun {
        case "screenshots": return "screenshot"
        case "installers": return "installer"
        case "PDFs": return "PDF"
        case "archives": return "archive"
        case "images": return "image"
        case "videos": return "video"
        case "documents": return "document"
        case "files": return "file"
        default: return "selected item"
        }
    }

    private static func singularIf(_ n: Int, _ noun: String) -> String { n == 1 ? singular(noun) : noun }
}
