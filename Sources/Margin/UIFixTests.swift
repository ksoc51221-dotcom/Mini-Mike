import AppKit
import Foundation

extension FeatureTests {
    /// A picture of some words, as PNG data (what a screenshot of a page would carry for the OCR to read).
    static func wordsPNG(_ words: String, width: Int = 1100, height: Int = 320) -> Data {
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            (words as NSString).draw(at: NSPoint(x: 40, y: 110), withAttributes: [
                .font: NSFont.systemFont(ofSize: 72, weight: .bold), .foregroundColor: NSColor.black,
            ])
            return true
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return Data() }
        return png
    }

    /// The sidebar's place, the chat limit, the screenshot inbox (finding, keeping and labeling), and the dashboard's store.
    static func uiFixChecks(_ check: (String, Bool) -> Void) {
        // The sidebar's frame: where you drag it stays put, and it always stays on a screen.
        let laptop = NSRect(x: 0, y: 0, width: 1440, height: 875)
        let external = NSRect(x: 1440, y: 0, width: 1920, height: 1055)
        let small = NSSize(width: AgentSidebar.width, height: 150)
        let tall = NSSize(width: AgentSidebar.width, height: 400)
        let home = AgentSidebar.frame(size: small, anchor: nil, screens: [laptop, external], dockScreen: laptop)
        check("sidebar: home is the top-right corner of the laptop screen",
              abs(home.maxX - (laptop.maxX - AgentSidebar.margin)) < 0.01 && abs(home.maxY - (laptop.maxY - AgentSidebar.margin)) < 0.01)
        let dropped = AgentSidebar.frame(size: small, anchor: NSPoint(x: 700, y: 600), screens: [laptop, external], dockScreen: laptop)
        check("sidebar: it opens where it was dropped", dropped.maxX == 700 && dropped.maxY == 600 && dropped.size == small)
        let grown = AgentSidebar.frame(size: tall, anchor: NSPoint(x: 700, y: 600), screens: [laptop, external], dockScreen: laptop)
        check("sidebar: more rows grow it downward, keeping the top-right corner", grown.maxX == 700 && grown.maxY == 600 && grown.minY == 200)
        let folded = AgentSidebar.frame(size: NSSize(width: AgentSidebar.stripWidth, height: 150), anchor: NSPoint(x: 700, y: 600),
                                        screens: [laptop, external], dockScreen: laptop)
        check("sidebar: folding keeps the right edge", folded.maxX == 700 && folded.maxY == 600)
        let low = AgentSidebar.frame(size: tall, anchor: NSPoint(x: 700, y: 250), screens: [laptop, external], dockScreen: laptop)
        check("sidebar: it can't grow off the bottom of the screen", low.minY >= laptop.minY && low.height == 400)
        let off = AgentSidebar.frame(size: small, anchor: NSPoint(x: 5000, y: 5000), screens: [laptop, external], dockScreen: laptop)
        check("sidebar: a corner far off every screen comes back onto the laptop", laptop.contains(off))
        let second = AgentSidebar.frame(size: small, anchor: NSPoint(x: 3000, y: 800), screens: [laptop, external], dockScreen: laptop)
        check("sidebar: dropped on the second screen, it stays there", external.contains(second) && second.maxX == 3000)
        let gone = AgentSidebar.frame(size: small, anchor: NSPoint(x: 3000, y: 800), screens: [laptop], dockScreen: laptop)
        check("sidebar: if that screen is unplugged it comes back to the laptop", laptop.contains(gone))
        check("chats: room for ten", Settings.shared.maxAgents == 10)

        // Labels: from the window's title, then the heading in the picture, then the app.
        check("label: a browser's own name comes off the page title",
              ScreenshotLabel.cleanWindowTitle("ESL Coverwork – Google Docs – Google Chrome", app: "Google Chrome") == "ESL Coverwork – Google Docs")
        check("label: a browser's profile name after it comes off too",
              ScreenshotLabel.cleanWindowTitle("Stitch - Projects - Google Chrome - Kien", app: "Google Chrome") == "Stitch - Projects")
        check("label: a page that just mentions Safari keeps its title",
              ScreenshotLabel.cleanWindowTitle("Fixing Safari - tips and tricks", app: "Safari") == "Fixing Safari - tips and tricks")
        check("label: the app's name comes off", ScreenshotLabel.cleanWindowTitle("Budget.pdf — Preview", app: "Preview") == "Budget.pdf")
        check("label: “Untitled” or just the app name says nothing",
              ScreenshotLabel.cleanWindowTitle("Untitled", app: "Pages") == "" && ScreenshotLabel.cleanWindowTitle("Safari", app: "Safari") == "")
        check("label: the window's title is the context",
              ScreenshotLabel.quick(app: "Safari", windowTitle: "BIDV SmartBanking - Safari", text: "other words") == "BIDV SmartBanking")
        check("label: no window title, the heading in the picture is",
              ScreenshotLabel.quick(app: "Preview", windowTitle: "", text: "x\nQuarterly budget report for 2026\nrow\nrow") == "Quarterly budget report for 2026")
        check("label: nothing to go on names the app", ScreenshotLabel.quick(app: "Preview", windowTitle: "", text: "") == "Screenshot from Preview")
        check("label: …or just calls it a screenshot", ScreenshotLabel.quick(app: "", windowTitle: "", text: "") == "Screenshot")
        check("label: the words in it file it under a subject",
              ScreenshotLabel.sector(app: "Preview", bundleID: nil, title: "Homework", text: "Find the derivative of the quadratic and the integral") == "Math")
        check("label: a code editor files under Computer Science",
              ScreenshotLabel.sector(app: "Xcode", bundleID: "com.apple.dt.Xcode", title: "Main", text: "") == "Computer Science")
        check("label: anything else is Other", ScreenshotLabel.sector(app: "Notes", bundleID: nil, title: "Shopping", text: "milk eggs") == Sector.other)

        // The chord that takes a screenshot is noticed (never swallowed), where you were is remembered for the file that follows.
        let cmdShift: CGEventFlags = [.maskCommand, .maskShift]
        check("hotkeys: ⌘⇧3, ⌘⇧4 and ⌘⇧5 are the screenshot chords",
              [20, 21, 23].allSatisfy { Hotkeys.isSystemScreenshotChord(keyCode: $0, flags: cmdShift) })
        check("hotkeys: with Control it's a copy to the clipboard, so no file to wait for",
              !Hotkeys.isSystemScreenshotChord(keyCode: 21, flags: [.maskCommand, .maskShift, .maskControl]))
        check("hotkeys: a plain 4 or ⌘4 isn't one",
              !Hotkeys.isSystemScreenshotChord(keyCode: 21, flags: []) && !Hotkeys.isSystemScreenshotChord(keyCode: 21, flags: [.maskCommand]))
        check("hotkeys: ⌘⇧L is still the history, not a screenshot", Hotkeys.action(keyCode: 37, flags: cmdShift, tabHeld: false) == .history
              && !Hotkeys.isSystemScreenshotChord(keyCode: 37, flags: cmdShift))
        let noted = ScreenshotInbox(library: Library(directory: FileManager.default.temporaryDirectory.appendingPathComponent("margin-note-\(UUID().uuidString)")))
        let pressed = Date()
        noted.debugNote(ScreenWhere(app: "Safari", bundleID: "com.apple.Safari", windowTitle: "Photosynthesis - Wikipedia", pid: 0), at: pressed)
        check("screenshots: a file that appears a few seconds after the key press gets that window as its context",
              noted.noteFor(created: pressed.addingTimeInterval(5.5))?.windowTitle == "Photosynthesis - Wikipedia")
        check("screenshots: …but not one from long after, or from before it",
              noted.noteFor(created: pressed.addingTimeInterval(200)) == nil && noted.noteFor(created: pressed.addingTimeInterval(-30)) == nil)

        // Finding screenshot files.
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("margin-shots-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        func put(_ name: String, mark: Bool = false, age: TimeInterval = 0) -> URL {
            let url = folder.appendingPathComponent(name)
            try? Data([1, 2, 3, 4]).write(to: url)
            if mark {
                url.withUnsafeFileSystemRepresentation { path in
                    guard let path else { return }
                    _ = setxattr(path, "com.apple.metadata:kMDItemIsScreenCapture", [UInt8(1)], 1, 0, 0)
                }
            }
            if age != 0 { try? fm.setAttributes([.creationDate: Date().addingTimeInterval(-age), .modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path) }
            return url
        }
        let named = put("Screenshot 2026-10-14 at 10.00.00.png")
        let marked = put("Pasted picture.png", mark: true)
        _ = put("holiday.png")
        _ = put("Screenshot notes.txt")
        _ = put(".Screenshot 2026-10-14 hidden.png")
        _ = put("Screenshot 2026-09-01 at 09.00.00.png", age: 86_400 * 30)
        var problem: String?
        let found = ScreenshotInbox.candidates(in: folder, since: Date().addingTimeInterval(-3600), skipping: [], problem: &problem)
        check("screenshots: finds the ones named like screenshots or marked by macOS",
              Set(found.map(\.url.lastPathComponent)) == [named.lastPathComponent, marked.lastPathComponent])
        check("screenshots: ignores other pictures, text files, hidden files and old ones", found.count == 2 && problem == nil)
        // (The folder listing may spell the temp folder's path differently from how it was made, so use the listing's own.)
        let keptPath = found.first { $0.url.lastPathComponent == named.lastPathComponent }?.url.path ?? ""
        let again = ScreenshotInbox.candidates(in: folder, since: Date().addingTimeInterval(-3600), skipping: [keptPath], problem: &problem)
        check("screenshots: ones already kept are skipped", again.map(\.url.lastPathComponent) == [marked.lastPathComponent])
        check("screenshots: a folder that isn't there is just empty",
              ScreenshotInbox.candidates(in: folder.appendingPathComponent("nope"), since: .distantPast, skipping: [], problem: &problem).isEmpty)
        check("screenshots: the folder is a real folder", { var d: ObjCBool = false; return fm.fileExists(atPath: ScreenshotInbox.screenshotFolder().path, isDirectory: &d) && d.boolValue }())

        // Keeping one: copied, read, labeled, filed.
        let libDir = fm.temporaryDirectory.appendingPathComponent("margin-shotlib-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: libDir) }
        let library = Library(directory: libDir)
        let inbox = ScreenshotInbox(library: library)
        let savedLocal = ScreenshotInbox.useLocal, savedGenerate = ScreenshotInbox.localGenerate, savedClaude = ChatNaming.claudeRun
        defer { ScreenshotInbox.useLocal = savedLocal; ScreenshotInbox.localGenerate = savedGenerate; ChatNaming.claudeRun = savedClaude }
        ScreenshotInbox.useLocal = { false }

        let png = wordsPNG("Quarterly Budget Report")
        let original = folder.appendingPathComponent("Screenshot 2026-10-14 at 11.11.11.png")
        try? png.write(to: original)
        var kept: ScreenshotRecord?
        inbox.onKept = { kept = $0 }
        inbox.keep(file: original, created: Date(), context: ScreenWhere(app: "Preview", bundleID: "com.apple.Preview", windowTitle: "Budget 2026.pdf — Preview", pid: 0))
        pump(20) { kept != nil }
        check("keep: the screenshot is saved to the dashboard", kept != nil && library.screenshots.count == 1)
        if let kept {
            check("keep: it's labeled by its window", kept.title == "Budget 2026.pdf" && kept.app == "Preview" && kept.source == .system)
            check("keep: its words were read on this Mac", kept.text.lowercased().contains("budget"))
            check("keep: the picture is stored in the library", fm.fileExists(atPath: library.imageURL(for: kept).path) && kept.width > 0 && kept.width <= 2000)
            check("keep: the original is left exactly where it was", fm.fileExists(atPath: original.path) && kept.originalPath == original.path)
            check("keep: it's found by the words in it and by its app",
                  library.search(screenshots: "budget").count == 1 && library.search(screenshots: "preview").count == 1 && library.search(screenshots: "zebra").isEmpty)
            let reloaded = Library(directory: libDir)
            reloaded.flush()
            check("keep: it's still there after a restart", reloaded.screenshots.map(\.id) == [kept.id] || { library.flush(); return Library(directory: libDir).screenshots.map(\.id) == [kept.id] }())
        }
        let after = ScreenshotInbox.candidates(in: folder, since: Date().addingTimeInterval(-3600), skipping: Set(library.screenshots.compactMap(\.originalPath)), problem: &problem)
        check("keep: after a restart it isn't kept a second time", !after.contains { $0.url == original })

        // Excluded apps are never saved.
        var count = library.screenshots.count
        let secret = folder.appendingPathComponent("Screenshot 2026-10-14 at 12.00.00.png")
        try? png.write(to: secret)
        inbox.keep(file: secret, created: Date(), context: ScreenWhere(app: "1Password", bundleID: "com.1password.1password", windowTitle: "Vault", pid: 0))
        pump(2) { library.screenshots.count > count }
        check("keep: a password manager's window is never saved", library.screenshots.count == count)

        // A snip: no file, straight from the picker.
        count = library.screenshots.count
        let snip = inbox.make(data: wordsPNG("Verb conjugation table"), created: Date(), source: .snip,
                              place: ScreenWhere(app: "Safari", bundleID: "com.apple.Safari", windowTitle: "", pid: 0), originalPath: nil)
        pump(5) { library.screenshots.count > count }
        check("snip: a Tab+\\ snip is kept too", snip?.source == .snip && library.screenshots.count == count + 1 && snip?.originalPath == nil)
        check("snip: with no window title, the heading in the picture labels it", snip?.title.lowercased().contains("conjugation") == true)

        // The model on this Mac writes a better title, unless you named it.
        guard let target = library.screenshots.first(where: { $0.source == .snip }) else { return }
        ScreenshotInbox.useLocal = { true }
        var asked = ""
        ScreenshotInbox.localGenerate = { system, prompt, done in asked = prompt; done(#"{"title": "Spanish verb conjugation chart", "sector": "Language"}"#) }
        var refined = false
        inbox.refine(target) { refined = true }
        pump(3) { refined }
        check("label: the on-Mac model is told the app and what's written in it", asked.contains("App: Safari") && asked.lowercased().contains("conjugation"))
        check("label: its title and subject replace the quick ones",
              library.screenshot(target.id)?.title == "Spanish verb conjugation chart" && library.screenshot(target.id)?.sector == "Language")
        library.rename(screenshot: target.id, to: "My own name")
        refined = false
        inbox.refine(library.screenshot(target.id)!) { refined = true }
        pump(1) { refined }
        check("label: a name you typed is never replaced", library.screenshot(target.id)?.title == "My own name" && library.screenshot(target.id)?.titleLocked == true)
        ScreenshotInbox.useLocal = { false }
        var calls = 0
        ChatNaming.claudeRun = { _, _, _, done in calls += 1; done(fakeReply(#"{"title": "Conjugation chart", "sector": "Language"}"#, tokens: 400)) }
        library.unlockTitle(screenshot: target.id)
        var spent = -1
        inbox.relabel(target.id) { spent = $0 }
        pump(3) { spent >= 0 }
        check("relabel: with Local Mode off, Claude does it once and says what it cost", calls == 1 && spent == 400 && library.screenshot(target.id)?.title == "Conjugation chart")

        // The store: rename, sector, delete.
        library.move(screenshot: target.id, toSector: "History")
        check("store: moving it files it under that sector for good",
              library.screenshot(target.id)?.sector == "History" && library.screenshot(target.id)?.sectorLocked == true
                && library.usedScreenshotSectors.contains { $0.name == "History" && $0.count == 1 })
        let imagePath = library.imageURL(for: library.screenshot(target.id)!).path
        library.delete(screenshot: target.id)
        library.flush()
        check("store: deleting it takes it off the dashboard but keeps its picture in the Bin", library.screenshot(target.id) == nil
              && library.binItem(target.id)?.kind == .screenshot && fm.fileExists(atPath: imagePath))
        library.deleteForever(target.id)
        library.flush()
        check("store: deleting it for good removes its picture too", library.binItem(target.id) == nil && !fm.fileExists(atPath: imagePath))
        library.deleteAllScreenshots()
        library.flush()
        check("store: delete all empties the dashboard but not the folder", library.screenshots.isEmpty && fm.fileExists(atPath: original.path))
    }

    /// --historytest: the History window comes up over your work without taking over. It must not make Margin the active
    /// app (so your front window stays yours), must float on the Space you're on, and still take typing.
    static func liveHistoryTest() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        var failures = 0
        func check(_ name: String, _ ok: Bool) {
            print((ok ? "ok   " : "FAIL ") + name)
            if !ok { failures += 1 }
        }
        let frontBefore = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let window = LibraryWindow.shared
        window.show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let panel = window.debugWindow
            check("history: it opens", window.isVisible)
            print("   NSApp.isActive=\(NSApp.isActive) system-active=\(NSRunningApplication.current.isActive) front=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?")")
            check("history: Margin did not become the active app", !NSRunningApplication.current.isActive)
            check("history: the app in front is still the one you were in", NSWorkspace.shared.frontmostApplication?.bundleIdentifier == frontBefore)
            check("history: it's a non-activating panel", panel?.styleMask.contains(.nonactivatingPanel) == true)
            check("history: it floats over other windows", panel?.level == .floating)
            check("history: it opens on the Space you're on, even over full-screen apps",
                  panel?.collectionBehavior.contains(.moveToActiveSpace) == true && panel?.collectionBehavior.contains(.fullScreenAuxiliary) == true)
            check("history: it can still take typing (the search box)", panel?.canBecomeKey == true && panel?.isKeyWindow == true)
            check("history: it's movable and resizable", panel?.isMovable == true && panel?.styleMask.contains(.resizable) == true)
            window.show(mode: .screenshots)
            check("history: the screenshots section opens", window.debugMode == .screenshots)
            window.toggle()
            check("history: ⌘⇧L in the screenshots section shows chats rather than hiding", window.debugMode == .chats && window.isVisible)
            window.toggle()
            check("history: ⌘⇧L again puts it away", !window.isVisible)
            check("history: still not the active app", !NSRunningApplication.current.isActive)
            print(failures == 0 ? "HISTORYTEST PASS" : "HISTORYTEST FAIL (\(failures))")
            exit(failures == 0 ? 0 : 1)
        }
        app.run()
        exit(0)
    }

    /// --screenshottest: the real watcher, end to end, on a temporary screenshots folder (your Desktop is never touched). A
    /// screenshot file appears the way macOS makes it (marked as a screenshot, first as a hidden temp file that is then renamed,
    /// then another) and must reach the dashboard on its own, quickly, once, with its words read and a label from its context.
    /// Then, if this process is allowed to capture the screen, a real `screencapture` file is dropped in too.
    static func liveScreenshotTest() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("margin-livefolder-\(UUID().uuidString)", isDirectory: true)
        let libDir = fm.temporaryDirectory.appendingPathComponent("margin-livelib-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let wasSave = Settings.shared.saveScreenshots, wasScan = Settings.shared.lastScreenshotScan, wasPaused = Settings.shared.paused
        Settings.shared.saveScreenshots = true
        Settings.shared.paused = false
        ScreenshotInbox.folderOverride = folder
        let savedLocal = ScreenshotInbox.useLocal
        ScreenshotInbox.useLocal = { false }
        let library = Library(directory: libDir)
        let inbox = ScreenshotInbox(library: library)
        var failures = 0
        func check(_ name: String, _ ok: Bool) {
            print((ok ? "ok   " : "FAIL ") + name)
            if !ok { failures += 1 }
        }
        func mark(_ url: URL) {
            url.withUnsafeFileSystemRepresentation { path in
                guard let path else { return }
                _ = setxattr(path, "com.apple.metadata:kMDItemIsScreenCapture", [UInt8(1)], 1, 0, 0)
            }
        }
        func finish() -> Never {
            inbox.stop()
            ScreenshotInbox.folderOverride = nil
            ScreenshotInbox.useLocal = savedLocal
            Settings.shared.saveScreenshots = wasSave
            Settings.shared.lastScreenshotScan = wasScan
            Settings.shared.paused = wasPaused
            try? fm.removeItem(at: folder)
            try? fm.removeItem(at: libDir)
            print(failures == 0 ? "SCREENSHOTTEST PASS" : "SCREENSHOTTEST FAIL (\(failures))")
            exit(failures == 0 ? 0 : 1)
        }
        var made = Date()
        var firstKept: Date?
        inbox.onKept = { _ in if firstKept == nil { firstKept = Date() } }
        inbox.start()

        // 1. A screenshot macOS-style: a hidden temp file, renamed into place a moment later.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let temp = folder.appendingPathComponent(".Screenshot 2026-10-14 at 15.30.00.png.tmp")
            try? wordsPNG("Verb Conjugation Practice").write(to: temp)
            let final = folder.appendingPathComponent("Screenshot 2026-10-14 at 15.30.00.png")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                try? fm.moveItem(at: temp, to: final)
                mark(final)
                made = Date()
            }
        }
        // 2. Something that isn't a screenshot, and a second real one.
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) {
            check("a screenshot dropped in appears in the dashboard by itself", library.screenshots.count == 1)
            if let s = library.screenshots.first {
                check("…its words were read", s.text.lowercased().contains("conjugation"))
                // (The window in front when the file appeared, here your real one, is the context; with none, the picture's heading.)
                check("…it's labeled from its context, not left generic",
                      s.title == ScreenshotLabel.quick(app: s.app, windowTitle: s.windowTitle, text: s.text) && !s.title.hasPrefix("Screenshot"))
                check("…and it's filed as a macOS screenshot", s.source == .system && s.originalPath?.hasSuffix("at 15.30.00.png") == true)
            }
            if let firstKept { print(String(format: "   dashboard had it %.1f s after the file appeared", firstKept.timeIntervalSince(made))) }
            check("it arrived within five seconds of the file appearing", firstKept.map { $0.timeIntervalSince(made) < 5 } ?? false)
            try? wordsPNG("Not a screenshot").write(to: folder.appendingPathComponent("holiday photo.png"))
            let second = folder.appendingPathComponent("Screenshot 2026-10-14 at 15.31.00.png")
            try? wordsPNG("Budget Meeting Notes").write(to: second)
            mark(second)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 11.0) {
            check("a second screenshot joins it", library.screenshots.count == 2)
            check("an ordinary picture in the folder is left out", !library.screenshots.contains { $0.text.lowercased().contains("not a screenshot") })
            check("nothing is kept twice", Set(library.screenshots.compactMap(\.originalPath)).count == library.screenshots.count)
            check("both originals are untouched", fm.fileExists(atPath: folder.appendingPathComponent("Screenshot 2026-10-14 at 15.30.00.png").path)
                  && fm.fileExists(atPath: folder.appendingPathComponent("Screenshot 2026-10-14 at 15.31.00.png").path))
            // 3. The real thing, if this process may capture the screen.
            if !CGPreflightScreenCaptureAccess() {
                print("   (no Screen Recording permission for this process: skipped the real screencapture)")
                finish()
            }
            let real = folder.appendingPathComponent("Screenshot 2026-10-14 at 15.32.00.png")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", real.path]
            try? p.run()
            p.waitUntilExit()
            if fm.fileExists(atPath: real.path) { mark(real) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 7.0) {
                check("a real screencapture of this screen reaches the dashboard too", library.screenshots.count == 3)
                if let s = library.screenshots.first(where: { $0.originalPath?.hasSuffix("at 15.32.00.png") == true }) {
                    print("   real capture: \(s.width)×\(s.height), \"\(s.title)\", \(s.text.count) characters read")
                }
                finish()
            }
        }
        app.run()
        exit(0)
    }
}
