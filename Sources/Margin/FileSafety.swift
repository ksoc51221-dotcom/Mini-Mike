import Foundation

/// The only code in Margin that changes your files. Everything a background agent wants to do is described first as a
/// plan of `Op`s; this runs them, and only after you've approved. The rules, enforced here and tested:
/// - only inside the folders you've allowed (Desktop, Downloads and Documents unless you change that);
/// - never hidden files, shortcuts (symbolic links), or anything inside an app or other package;
/// - never overwrites: if a name is taken, the new one gets "2", "3"…;
/// - never deletes for good: "remove" means the Trash, and Undo takes it back out;
/// - every change is written to a ledger, so a whole task can be undone.
enum FileSafety {
    /// The folders agents may work in (tests point this at a temporary folder).
    static var roots: [URL] = defaultRoots

    static var defaultRoots: [URL] {
        let fm = FileManager.default
        return [FileManager.SearchPathDirectory.desktopDirectory, .downloadsDirectory, .documentDirectory]
            .compactMap { fm.urls(for: $0, in: .userDomainMask).first }
    }

    // MARK: Rules

    enum Refusal: LocalizedError, Equatable {
        case outsideAllowedFolders(String)
        case isAllowedFolder(String)
        case hidden(String)
        case shortcut(String)
        case insidePackage(String)
        case missing(String)

        var errorDescription: String? {
            switch self {
            case .outsideAllowedFolders(let p): return "“\(p)” isn't in a folder Margin is allowed to change."
            case .isAllowedFolder(let p): return "“\(p)” is one of the allowed folders itself."
            case .hidden(let p): return "“\(p)” is a hidden file."
            case .shortcut(let p): return "“\(p)” is a shortcut (alias or symbolic link)."
            case .insidePackage(let p): return "“\(p)” is inside an app or package."
            case .missing(let p): return "“\(p)” is gone."
            }
        }
    }

    private static let packageExtensions: Set<String> = ["app", "bundle", "framework", "plugin", "photoslibrary", "musiclibrary",
                                                          "tvlibrary", "xcodeproj", "xcworkspace", "playground", "pkg", "kext", "rtfd",
                                                          "pages", "numbers", "key", "sparsebundle", "dmg"]

    /// Apps and libraries, which open-ended agents leave out of what they look at (documents like .pages and installers
    /// like .dmg are ordinary files).
    private static let appExtensions: Set<String> = ["app", "bundle", "framework", "plugin", "photoslibrary", "musiclibrary",
                                                      "tvlibrary", "xcodeproj", "xcworkspace", "playground", "kext", "sparsebundle"]

    static func isAppOrLibrary(_ name: String) -> Bool { appExtensions.contains((name as NSString).pathExtension.lowercased()) }

    /// The real location of a folder or file's parent: symbolic links and `..` resolved.
    /// (A name that doesn't exist yet is resolved through the folders that do: `resolvingSymlinksInPath` alone treats
    /// `/private/var/…/new.pdf` and `/var/…/new.pdf` differently once the file isn't there.)
    private static func real(_ url: URL) -> URL {
        let fm = FileManager.default
        var existing = url.standardizedFileURL
        var tail: [String] = []
        while !fm.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
            tail.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        var resolved = existing.resolvingSymlinksInPath()
        for part in tail { resolved.appendPathComponent(part) }
        return resolved
    }

    private static func path(_ url: URL) -> String { real(url).path }

    /// Is `url` strictly inside one of the allowed folders?
    static func root(containing url: URL) -> URL? {
        let p = path(url)
        return roots.first { r in
            let rp = path(r)
            return p.hasPrefix(rp.hasSuffix("/") ? rp : rp + "/")
        }
    }

    /// Throws unless Margin may change this existing item.
    static func checkSource(_ url: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) || (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true else {
            throw Refusal.missing(url.lastPathComponent)
        }
        if roots.contains(where: { path($0) == path(url) }) { throw Refusal.isAllowedFolder(url.lastPathComponent) }
        guard let root = root(containing: url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent)) else {
            throw Refusal.outsideAllowedFolders(url.path)
        }
        // The item itself must not be a shortcut (a link could point out of the allowed folders).
        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isAliasFileKey])
        if values?.isSymbolicLink == true || values?.isAliasFile == true { throw Refusal.shortcut(url.lastPathComponent) }
        // Everything between the allowed folder and the item: no hidden names, no packages.
        let below = path(url.deletingLastPathComponent()).dropFirst(path(root).count).split(separator: "/").map(String.init)
            + [url.lastPathComponent]
        if below.contains(where: { $0.hasPrefix(".") }) { throw Refusal.hidden(url.lastPathComponent) }
        if below.dropLast().contains(where: { packageExtensions.contains(($0 as NSString).pathExtension.lowercased()) }) {
            throw Refusal.insidePackage(url.lastPathComponent)
        }
    }

    /// Throws unless Margin may put something at this location.
    static func checkDestination(_ url: URL) throws {
        guard let root = root(containing: url) else { throw Refusal.outsideAllowedFolders(url.path) }
        let below = path(url.deletingLastPathComponent()).dropFirst(path(root).count).split(separator: "/").map(String.init)
            + [url.lastPathComponent]
        if below.contains(where: { $0.hasPrefix(".") }) { throw Refusal.hidden(url.lastPathComponent) }
        // Only the folders on the way count: a file called Setup.dmg is fine to put somewhere.
        if below.dropLast().contains(where: { packageExtensions.contains(($0 as NSString).pathExtension.lowercased()) }) {
            throw Refusal.insidePackage(url.lastPathComponent)
        }
    }

    /// A name that isn't taken: "report.pdf" → "report 2.pdf" → "report 3.pdf".
    static func unique(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var n = 2
        while true {
            let name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            let candidate = url.deletingLastPathComponent().appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    // MARK: Plans and the ledger

    struct Op: Codable, Equatable, Identifiable {
        enum Kind: String, Codable { case move, trash, copy }
        var id = UUID()
        var kind: Kind
        var from: String
        /// Where it goes (for a move).
        var to: String?

        static func move(_ from: URL, to: URL) -> Op { Op(kind: .move, from: from.path, to: to.path) }
        static func trash(_ from: URL) -> Op { Op(kind: .trash, from: from.path) }
        static func copy(_ from: URL, to: URL) -> Op { Op(kind: .copy, from: from.path, to: to.path) }
    }

    /// What actually happened, so it can be reversed.
    struct Record: Codable, Equatable {
        /// `positioned`: a Desktop icon was moved by Finder (`original` = the file, `now` = where it was, "x,y"). `arrangement`:
        /// Finder's Sort By was switched (`now` = what it was).
        enum Kind: String, Codable { case moved, trashed, createdFolder, createdFile, positioned, arrangement }
        var kind: Kind
        var original: String
        /// Where it ended up (the new place, the Trash, or the folder that was made).
        var now: String
    }

    struct Ledger: Codable {
        var id = UUID()
        var title: String
        var date = Date()
        var records: [Record] = []
        var undone = false
        var count: Int { records.filter { $0.kind != .createdFolder }.count }
    }

    struct Outcome {
        var done = 0
        var skipped: [(name: String, reason: String)] = []
        var cancelled = false
    }

    /// Runs one step and says where the item ended up (nil if there was nothing to do). Throws if a rule says no.
    @discardableResult
    static func perform(_ op: Op, ledger: inout Ledger) throws -> URL? {
        let fm = FileManager.default
        let source = URL(fileURLWithPath: op.from)
        try checkSource(source)
        switch op.kind {
        case .move, .copy:
            guard let to = op.to else { return nil }
            var destination = URL(fileURLWithPath: to)
            try checkDestination(destination)
            // Already there: nothing to do (and no "name 2").
            if real(destination).path == real(source).path { return nil }
            // Make the folders it needs (and remember them, so Undo can tidy up after itself).
            for missing in missingFolders(destination.deletingLastPathComponent()) {
                try fm.createDirectory(at: missing, withIntermediateDirectories: false)
                ledger.records.append(Record(kind: .createdFolder, original: missing.path, now: missing.path))
            }
            destination = unique(destination)
            if op.kind == .move {
                try fm.moveItem(at: source, to: destination)
                ledger.records.append(Record(kind: .moved, original: source.path, now: destination.path))
            } else {
                try fm.copyItem(at: source, to: destination)
                // A copy is a new file: Undo takes it back out through the Trash.
                ledger.records.append(Record(kind: .createdFile, original: destination.path, now: destination.path))
            }
            return destination
        case .trash:
            var resulting: NSURL?
            try fm.trashItem(at: source, resultingItemURL: &resulting)
            ledger.records.append(Record(kind: .trashed, original: source.path, now: (resulting as URL?)?.path ?? ""))
            return resulting as URL?
        }
    }

    /// Runs the plan. `progress(done, total)` after each step; `cancelled()` is asked between steps.
    static func execute(_ ops: [Op], ledger: inout Ledger, progress: (Int, Int) -> Void = { _, _ in },
                        cancelled: () -> Bool = { false }) -> Outcome {
        var outcome = Outcome()
        for (i, op) in ops.enumerated() {
            if cancelled() { outcome.cancelled = true; break }
            let before = ledger.records.count
            do {
                try perform(op, ledger: &ledger)
                if ledger.records[before...].contains(where: { $0.kind == .moved || $0.kind == .trashed || $0.kind == .createdFile }) {
                    outcome.done += 1
                }
            } catch {
                outcome.skipped.append((URL(fileURLWithPath: op.from).lastPathComponent, error.localizedDescription))
            }
            progress(i + 1, ops.count)
        }
        return outcome
    }

    /// Writes a new file (never over an existing one) and records it, so Undo can take it away again. Returns where it went.
    @discardableResult
    static func createFile(_ data: Data, at url: URL, ledger: inout Ledger) throws -> URL {
        let fm = FileManager.default
        try checkDestination(url)
        for missing in missingFolders(url.deletingLastPathComponent()) {
            try fm.createDirectory(at: missing, withIntermediateDirectories: false)
            ledger.records.append(Record(kind: .createdFolder, original: missing.path, now: missing.path))
        }
        let target = unique(url)
        try data.write(to: target, options: .withoutOverwriting)
        ledger.records.append(Record(kind: .createdFile, original: target.path, now: target.path))
        return target
    }

    /// The folders in `folder`'s path that don't exist yet (outermost first), all inside an allowed folder.
    private static func missingFolders(_ folder: URL) -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        var current = folder
        while !fm.fileExists(atPath: current.path), root(containing: current) != nil {
            out.append(current)
            current = current.deletingLastPathComponent()
        }
        return out.reversed()
    }

    struct UndoOutcome {
        var restored = 0
        var couldNotRestore: [String] = []
    }

    /// Puts everything back (newest change first). A file you've since moved or deleted yourself is left alone.
    static func undo(_ ledger: inout Ledger) -> UndoOutcome {
        let fm = FileManager.default
        var outcome = UndoOutcome()
        // Icons first, while their files are still where they were put (the moves come back out after).
        let placed = ledger.records.filter { $0.kind == .positioned }.compactMap { r -> FinderDesktop.Placement? in
            let xy = r.now.split(separator: ",").compactMap { Int($0) }
            guard xy.count == 2 else { return nil }
            return FinderDesktop.Placement(name: URL(fileURLWithPath: r.original).lastPathComponent, x: xy[0], y: xy[1])
        }
        let arrangement = ledger.records.first { $0.kind == .arrangement }?.now
        if !placed.isEmpty || arrangement != nil {
            FinderDesktop.restore(placed, arrangement: arrangement)
            outcome.restored += placed.count
        }
        for record in ledger.records.reversed() {
            switch record.kind {
            case .positioned, .arrangement:
                break // done above
            case .moved, .trashed:
                let now = URL(fileURLWithPath: record.now)
                guard !record.now.isEmpty, fm.fileExists(atPath: now.path) else {
                    outcome.couldNotRestore.append(URL(fileURLWithPath: record.original).lastPathComponent)
                    continue
                }
                let original = URL(fileURLWithPath: record.original)
                do {
                    try fm.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.moveItem(at: now, to: unique(original))
                    outcome.restored += 1
                } catch {
                    outcome.couldNotRestore.append(original.lastPathComponent)
                }
            case .createdFile:
                // A file Margin made: back out through the Trash (so even this isn't a hard delete).
                let file = URL(fileURLWithPath: record.now)
                if fm.fileExists(atPath: file.path), (try? fm.trashItem(at: file, resultingItemURL: nil)) != nil { outcome.restored += 1 }
            case .createdFolder:
                // Only if it's empty now (a folder you've filled yourself stays).
                let folder = URL(fileURLWithPath: record.now)
                if let items = try? fm.contentsOfDirectory(atPath: folder.path),
                   items.allSatisfy({ $0 == ".DS_Store" }) {
                    try? fm.removeItem(at: folder)
                }
            }
        }
        ledger.undone = true
        return outcome
    }

    // MARK: Ledger files

    static var ledgerDirectory: URL = ClaudeSession.workingDirectory.appendingPathComponent("Tasks", isDirectory: true)

    static func save(_ ledger: Ledger) {
        let fm = FileManager.default
        try? fm.createDirectory(at: ledgerDirectory, withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = .prettyPrinted
        if let data = try? e.encode(ledger) {
            try? data.write(to: ledgerDirectory.appendingPathComponent("\(ledger.id.uuidString).json"), options: .atomic)
        }
    }
}
