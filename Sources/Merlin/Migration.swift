import Foundation

/// One-time move from the app's old name (Margin, bundle id com.kien.margin) to Merlin.
/// It only ever COPIES: the old preferences and the old Application Support folder are left exactly as they were,
/// so the old app keeps working and nothing can be lost. Every function takes its folders and defaults as parameters
/// so the checks in `migrationChecks` can run it against a temporary folder and a throwaway suite.
enum Migration {
    static let oldBundleID = "com.kien.margin"
    static let newBundleID = "com.kien.merlin"
    static let oldFolderName = "Margin"
    static let newFolderName = "Merlin"
    /// Written to the new settings once they have been carried over; its presence means "never do this again".
    static let marker = "migratedFromMargin"

    /// True for a normal launch (and the MCP server, which reads the same data folder). Every test, shot, demo and
    /// live-check flag starts with "--", so any such flag keeps the migration away from the real settings and folder.
    static func isNormalLaunch(_ arguments: [String]) -> Bool {
        !arguments.dropFirst().contains { $0.hasPrefix("--") && $0 != "--mcp" }
    }

    /// The new name for a persisted settings key. Window positions were saved under "NSWindow Frame MarginDashboard"
    /// and "NSWindow Frame MarginLibrarySettings"; the windows are now named Merlin…, so those keys follow.
    static func newKey(for old: String) -> String {
        let prefix = "NSWindow Frame Margin"
        if old.hasPrefix(prefix) { return "NSWindow Frame Merlin" + old.dropFirst(prefix.count) }
        return old
    }

    /// Copies every key of the old settings into `defaults` (whose own domain is `domain`), then sets the marker.
    /// The old value WINS over one already there: with no marker, Merlin has never had a normal launch, so anything
    /// already in its settings was left by a test run, not chosen by the user. Keys the old settings don't have are left alone.
    /// Does nothing at all if the marker is already there. Returns how many keys were copied.
    @discardableResult
    static func migrateSettings(old: [String: Any]?, into defaults: UserDefaults, domain: String) -> Int {
        let current = defaults.persistentDomain(forName: domain) ?? [:]
        guard current[marker] == nil else { return 0 }
        var copied = 0
        for (key, value) in old ?? [:] {
            let target = newKey(for: key)
            guard target != marker else { continue }
            defaults.set(value, forKey: target)
            copied += 1
        }
        defaults.set(true, forKey: marker)
        return copied
    }

    /// True when there is nothing at `url` worth keeping: no such folder, or a folder with no files anywhere in it (the app creates
    /// its empty data folder the first time anything asks for its path, which could happen before the first real launch).
    static func isMissingOrEmpty(_ url: URL, fileManager fm: FileManager = .default) -> Bool {
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return true }
        guard isDirectory.boolValue, let walker = fm.enumerator(atPath: url.path) else { return false }
        for case let name as String in walker where (name as NSString).lastPathComponent != ".DS_Store" {
            var childIsDirectory: ObjCBool = false
            if !fm.fileExists(atPath: url.appendingPathComponent(name).path, isDirectory: &childIsDirectory) || !childIsDirectory.boolValue { return false }
        }
        return true // folders only, no files anywhere
    }

    /// Copies `old` to `new` when `old` exists and `new` does not (or is an empty folder). Never moves or deletes `old`, never touches an
    /// existing `new`. The copy is made under a temporary name and renamed at the end, so a crash half-way can't leave
    /// a half-filled folder that would then count as "already migrated". Returns whether it copied.
    @discardableResult
    static func migrateFolder(from old: URL, to new: URL, fileManager fm: FileManager = .default) -> Bool {
        guard fm.fileExists(atPath: old.path), isMissingOrEmpty(new, fileManager: fm) else { return false }
        let staging = new.deletingLastPathComponent().appendingPathComponent(new.lastPathComponent + ".migrating", isDirectory: true)
        try? fm.removeItem(at: staging) // only ever our own half-finished copy from an interrupted run
        do {
            try fm.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: old, to: staging)
            if fm.fileExists(atPath: new.path) { try fm.removeItem(at: new) } // only ever an empty folder, checked above
            try fm.moveItem(at: staging, to: new)
            return true
        } catch {
            try? fm.removeItem(at: staging)
            return false
        }
    }

    /// Called first thing from main.swift, before anything reads settings or the data folder.
    static func runIfNeeded(arguments: [String] = CommandLine.arguments) {
        guard isNormalLaunch(arguments) else { return }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        migrateFolder(from: support.appendingPathComponent(oldFolderName, isDirectory: true),
                      to: support.appendingPathComponent(newFolderName, isDirectory: true))
        // Settings only for the real app bundle: a bare binary run from .build has no bundle id, and its "standard" domain isn't ours.
        if Bundle.main.bundleIdentifier == newBundleID {
            migrateSettings(old: UserDefaults.standard.persistentDomain(forName: oldBundleID), into: .standard, domain: newBundleID)
        }
    }
}

extension FeatureTests {
    static func migrationChecks(_ check: (String, Bool) -> Void) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("merlin-migration-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let oldDir = root.appendingPathComponent("Margin", isDirectory: true)
        let newDir = root.appendingPathComponent("Merlin", isDirectory: true)
        try? fm.createDirectory(at: oldDir.appendingPathComponent("Library/chats", isDirectory: true), withIntermediateDirectories: true)
        try? "chat one".write(to: oldDir.appendingPathComponent("Library/chats/a.json"), atomically: true, encoding: .utf8)
        try? "sectors".write(to: oldDir.appendingPathComponent("Library/sectors.json"), atomically: true, encoding: .utf8)
        func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

        // Folder: a fresh migration copies everything and leaves the old folder alone.
        check("migration: a fresh folder migration copies", Migration.migrateFolder(from: oldDir, to: newDir))
        check("migration: …every file arrives", read(newDir.appendingPathComponent("Library/chats/a.json")) == "chat one"
              && read(newDir.appendingPathComponent("Library/sectors.json")) == "sectors")
        check("migration: …the old folder is untouched", read(oldDir.appendingPathComponent("Library/chats/a.json")) == "chat one"
              && read(oldDir.appendingPathComponent("Library/sectors.json")) == "sectors")
        check("migration: …no staging folder is left behind", !fm.fileExists(atPath: root.appendingPathComponent("Merlin.migrating").path))

        // A second run is a no-op, even after the old folder changed.
        try? "chat two".write(to: oldDir.appendingPathComponent("Library/chats/a.json"), atomically: true, encoding: .utf8)
        check("migration: the second folder run does nothing", !Migration.migrateFolder(from: oldDir, to: newDir)
              && read(newDir.appendingPathComponent("Library/chats/a.json")) == "chat one")

        // An existing new folder is never overwritten (here: written to before the first migration ever ran).
        let root2 = root.appendingPathComponent("second", isDirectory: true)
        let old2 = root2.appendingPathComponent("Margin", isDirectory: true), new2 = root2.appendingPathComponent("Merlin", isDirectory: true)
        try? fm.createDirectory(at: old2, withIntermediateDirectories: true)
        try? fm.createDirectory(at: new2, withIntermediateDirectories: true)
        try? "old".write(to: old2.appendingPathComponent("x.txt"), atomically: true, encoding: .utf8)
        try? "new".write(to: new2.appendingPathComponent("x.txt"), atomically: true, encoding: .utf8)
        check("migration: an existing Merlin folder is never overwritten", !Migration.migrateFolder(from: old2, to: new2)
              && read(new2.appendingPathComponent("x.txt")) == "new" && read(old2.appendingPathComponent("x.txt")) == "old")
        // An EMPTY new folder (created by something asking for its path) is not a reason to skip the copy.
        let old4 = root.appendingPathComponent("fourth/Margin", isDirectory: true), new4 = root.appendingPathComponent("fourth/Merlin", isDirectory: true)
        try? fm.createDirectory(at: old4, withIntermediateDirectories: true)
        try? "data".write(to: old4.appendingPathComponent("z.txt"), atomically: true, encoding: .utf8)
        try? fm.createDirectory(at: new4, withIntermediateDirectories: true)
        check("migration: an empty Merlin folder is filled from Margin", Migration.migrateFolder(from: old4, to: new4)
              && read(new4.appendingPathComponent("z.txt")) == "data" && read(old4.appendingPathComponent("z.txt")) == "data")
        check("migration: no old folder means nothing to do", !Migration.migrateFolder(from: root.appendingPathComponent("nope"), to: root.appendingPathComponent("nope2")))

        // A leftover half-copy from an interrupted run is replaced, not mistaken for a finished migration.
        let old3 = root.appendingPathComponent("third/Margin", isDirectory: true), new3 = root.appendingPathComponent("third/Merlin", isDirectory: true)
        try? fm.createDirectory(at: old3, withIntermediateDirectories: true)
        try? "whole".write(to: old3.appendingPathComponent("y.txt"), atomically: true, encoding: .utf8)
        try? fm.createDirectory(at: new3.deletingLastPathComponent().appendingPathComponent("Merlin.migrating"), withIntermediateDirectories: true)
        check("migration: a leftover staging folder doesn't block it", Migration.migrateFolder(from: old3, to: new3) && read(new3.appendingPathComponent("y.txt")) == "whole")

        // Settings, in a throwaway suite.
        let suite = "merlin.migration.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("left by a test run", forKey: "alreadyThere")
        defaults.set("only in Merlin", forKey: "onlyNew")
        let old: [String: Any] = ["localModel": "qwen3:8b", "paused": true, "alreadyThere": "old value",
                                  "NSWindow Frame MarginDashboard": "10 20 800 600", "NSWindow Frame MarginLibrarySettings": "1 2 3 4"]
        let copied = Migration.migrateSettings(old: old, into: defaults, domain: suite)
        check("migration: settings are copied across", copied == 5 && defaults.string(forKey: "localModel") == "qwen3:8b" && defaults.bool(forKey: "paused"))
        check("migration: on the first run the old setting wins over a leftover one", defaults.string(forKey: "alreadyThere") == "old value")
        check("migration: a setting the old app never had is left alone", defaults.string(forKey: "onlyNew") == "only in Merlin")
        check("migration: window positions follow the new window names", defaults.string(forKey: "NSWindow Frame MerlinDashboard") == "10 20 800 600"
              && defaults.string(forKey: "NSWindow Frame MerlinLibrarySettings") == "1 2 3 4" && defaults.object(forKey: "NSWindow Frame MarginDashboard") == nil)
        check("migration: the marker is set", defaults.bool(forKey: Migration.marker))
        defaults.set("changed since", forKey: "localModel")
        check("migration: the second settings run does nothing", Migration.migrateSettings(old: old, into: defaults, domain: suite) == 0
              && defaults.string(forKey: "localModel") == "changed since")
        check("migration: an empty old domain still sets the marker", {
            let s2 = "merlin.migration.test2.\(UUID().uuidString)"
            let d2 = UserDefaults(suiteName: s2)!
            defer { d2.removePersistentDomain(forName: s2) }
            return Migration.migrateSettings(old: nil, into: d2, domain: s2) == 0 && d2.bool(forKey: Migration.marker)
        }())

        // Which launches migrate.
        check("migration: a normal launch migrates, test and shot flags don't",
              Migration.isNormalLaunch(["/x/Merlin"]) && Migration.isNormalLaunch(["/x/Merlin", "--mcp"])
              && !Migration.isNormalLaunch(["/x/Merlin", "--unittest"]) && !Migration.isNormalLaunch(["/x/Merlin", "--livecheck", "/tmp/a"])
              && !Migration.isNormalLaunch(["/x/Merlin", "--uishots", "/tmp/a"]))

        // The notes folder keeps using "Margin Notes" only if that is all there is.
        let docs = root.appendingPathComponent("docs", isDirectory: true)
        try? fm.createDirectory(at: docs.appendingPathComponent("Margin Notes"), withIntermediateDirectories: true)
        check("migration: an existing Margin Notes folder keeps being used", Notebook.defaultFolder(documents: docs).lastPathComponent == "Margin Notes")
        try? fm.createDirectory(at: docs.appendingPathComponent("Merlin Notes"), withIntermediateDirectories: true)
        check("migration: Merlin Notes wins once it exists", Notebook.defaultFolder(documents: docs).lastPathComponent == "Merlin Notes")
        check("migration: a fresh install uses Merlin Notes", Notebook.defaultFolder(documents: root.appendingPathComponent("empty")).lastPathComponent == "Merlin Notes")
    }
}
