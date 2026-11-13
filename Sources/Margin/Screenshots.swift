import AppKit
import ApplicationServices

// MARK: - Where you were

/// The app and window a screenshot was taken in: the context its label comes from.
struct ScreenWhere: Equatable {
    var app = ""
    var bundleID: String?
    var windowTitle = ""
    /// The process, so the window's title can be read.
    var pid: pid_t = 0
}

/// Remembers the last app you were really using, so a screenshot taken with ⌘⇧5 (whose own little window can come to the
/// front) is still filed under the app it shows.
final class FrontAppTracker {
    static let shared = FrontAppTracker()
    private(set) var app: NSRunningApplication?
    private var observer: Any?

    static let ignored: Set<String> = ["com.apple.screencaptureui", "com.apple.loginwindow", "com.apple.dock",
                                       "com.apple.WindowManager", "com.apple.controlcenter", "com.apple.notificationcenterui"]

    static func counts(_ a: NSRunningApplication) -> Bool {
        a.processIdentifier != ProcessInfo.processInfo.processIdentifier && !ignored.contains(a.bundleIdentifier ?? "")
    }

    func start() {
        guard observer == nil else { return }
        if let front = NSWorkspace.shared.frontmostApplication, Self.counts(front) { app = front }
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                                     object: nil, queue: .main) { [weak self] note in
            if let a = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, Self.counts(a) { self?.app = a }
        }
    }

    /// The title of an app's focused window (a web page's title, a document's name), if Accessibility lets us read it.
    static func windowTitle(pid: pid_t) -> String {
        guard AXIsProcessTrusted(), pid > 0 else { return "" }
        let app = AXUIElementCreateApplication(pid)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return "" }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success else { return "" }
        return (title as? String) ?? ""
    }

    /// Where you are right now (call from the main thread; the window title is read on whatever thread calls `fill`).
    func current() -> NSRunningApplication? { app ?? NSWorkspace.shared.frontmostApplication }
}

// MARK: - Labels

/// What a screenshot is called. The label comes from its context: the window's title, then the heading found in the picture;
/// with Local Mode on, the model on this Mac reads both and writes a proper title (no Claude tokens).
enum ScreenshotLabel {
    /// "Page title – Google Chrome" → "Page title". Nothing left (or just the app's name) → "".
    static func cleanWindowTitle(_ raw: String, app: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let separators = [" — ", " – ", " - ", " | ", " · "]
        // Take the app's name off either end.
        if !app.isEmpty {
            for sep in separators {
                if t.hasSuffix(sep + app) { t = String(t.dropLast((sep + app).count)) }
                else if t.hasPrefix(app + sep) { t = String(t.dropFirst((app + sep).count)) }
            }
        }
        // Browsers add their own name, and often a profile after it ("Page - Google Chrome - Kien"), that the app name may
        // not match exactly ("Google Chrome" vs "Chrome"). Cut from the browser's name on.
        for browser in ["Google Chrome", "Microsoft Edge", "Brave Browser", "Safari", "Firefox", "Brave", "Opera", "Arc", "Chrome"] {
            for sep in separators {
                guard let r = t.range(of: sep + browser, options: .backwards) else { continue }
                let rest = t[r.upperBound...]
                // Only when that's the end of the title or a profile name follows (not "Fixing Safari - tips").
                if rest.isEmpty || separators.contains(where: { rest.hasPrefix($0) }) { t = String(t[..<r.lowerBound]) }
            }
        }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = t.lowercased()
        if t.isEmpty || lower == app.lowercased() || ["untitled", "new tab", "start page", "loading…", "loading..."].contains(lower) { return "" }
        return t
    }

    /// A label worked out right here from the context, instantly and free.
    static func quick(app: String, windowTitle: String, text: String) -> String {
        let clean = cleanWindowTitle(windowTitle, app: app)
        if clean.filter(\.isLetter).count >= 4, let t = ChatNaming.cleanTitle(clean) { return t }
        if let heading = heuristicTitle(text), let t = ChatNaming.cleanTitle(heading) { return t }
        return app.isEmpty ? "Screenshot" : "Screenshot from \(app)"
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

    /// A subject for the sector list: from the words in it, else from the kind of app.
    static func sector(app: String, bundleID: String?, title: String, text: String) -> String {
        if let s = Sector.guess(from: title + " " + String(text.prefix(1500))) { return s }
        let id = (bundleID ?? "").lowercased(), name = app.lowercased()
        if ["xcode", "terminal", "iterm", "vscode", "cursor", "sublime", "jetbrains", "github"].contains(where: { id.contains($0) || name.contains($0) }) {
            return "Computer Science"
        }
        if ["excel", "numbers", "powerpoint", "keynote"].contains(where: { id.contains($0) || name.contains($0) }) { return "Business" }
        return Sector.other
    }

    static func system(sectors: [String]) -> String {
        """
        You label a screenshot for a searchable dashboard. Reply with ONLY JSON: {"title": "…", "sector": "…"}.
        title: 3 to 7 plain words saying what the screenshot shows (the page, document, chat, error or app screen), as specific as the text allows, in the language of the text. No quotes, no full stop.
        sector: the subject it belongs under, one of: \(sectors.joined(separator: ", ")). Use another short subject name only if none of those fits.
        """
    }

    static func prompt(app: String, windowTitle: String, text: String) -> String {
        var lines: [String] = []
        if !app.isEmpty { lines.append("App: \(app)") }
        if !windowTitle.isEmpty { lines.append("Window title: \(windowTitle)") }
        let body = text.replacingOccurrences(of: "\n", with: " | ")
        lines.append("Text found in the screenshot: " + (body.isEmpty ? "(none)" : String(body.prefix(900))))
        return lines.joined(separator: "\n")
    }
}

// MARK: - The inbox

/// Every screenshot you take goes into the dashboard on its own: Margin's snips (Tab+\) as they happen, and the ones macOS
/// saves (⌘⇧3, ⌘⇧4, ⌘⇧5) as soon as their file shows up in your screenshots folder. Each is copied (never moved or touched
/// where it is), read for its words on this Mac, and labeled by its context. The picture never leaves the Mac unless you ask
/// Margin about it.
final class ScreenshotInbox {
    static let shared = ScreenshotInbox()

    /// How the on-Mac model is reached (replaced in tests).
    static var useLocal: () -> Bool = { Settings.shared.localMode && OllamaClient.shared.status.isUsable }
    static var localGenerate: (_ system: String, _ prompt: String, _ done: @escaping (String?) -> Void) -> Void = { system, prompt, done in
        OllamaClient.shared.generate(system: system, prompt: prompt, maxTokens: 120, completion: done)
    }
    /// The longest side of a kept picture, in pixels.
    static let maxEdge: CGFloat = 2000
    static let maxTextLength = 4000
    /// A screenshot older than this when found isn't tied to whatever app is in front now.
    static let freshSeconds: TimeInterval = 12

    let library: Library
    /// Set while the screenshots folder can't be read (macOS hasn't let Margin into it), for the menu to say so.
    private(set) var folderProblem: String?
    /// Called on the main queue when a screenshot has been kept (tests use it to wait).
    var onKept: ((ScreenshotRecord) -> Void)?

    private let queue = DispatchQueue(label: "margin.screenshots", qos: .utility)
    private var source: DispatchSourceFileSystemObject?
    private var watched: URL?
    private var timer: Timer?
    private var pending: DispatchWorkItem?
    private var pendingWhere: ScreenWhere?
    /// Files already kept or being kept (by path), and how many times each has failed to read.
    private var seen = Set<String>()
    private var attempts: [String: Int] = [:]
    /// Where you were when you pressed ⌘⇧3/4/5. The file can show up several seconds later (macOS holds it back while its
    /// little preview is on screen), by which time you may be somewhere else.
    private var captureNote: (place: ScreenWhere, at: Date)?
    /// How long after the key press a new screenshot file is still that screenshot.
    static let noteLifetime: TimeInterval = 90
    private var lastScan = Date()
    private var started = false

    init(library: Library = .shared) { self.library = library }

    // MARK: Folder

    /// Tests point this at a temporary folder.
    static var folderOverride: URL?

    /// Where macOS puts screenshots: the folder set in ⌘⇧5's Options, else the Desktop.
    static func screenshotFolder() -> URL {
        if let folderOverride { return folderOverride }
        let fm = FileManager.default
        if let location = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location") {
            let path = (location as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue { return URL(fileURLWithPath: path, isDirectory: true) }
        }
        return fm.urls(for: .desktopDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory() + "/Desktop")
    }

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "tif"]

    /// macOS marks every screenshot it takes with this attribute (so Spotlight can find them).
    static func hasScreenCaptureMark(_ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return getxattr(path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0) >= 0
        }
    }

    /// A screenshot file: a picture that macOS marked as a screenshot, or is named like one.
    static func isScreenshotFile(_ url: URL) -> Bool {
        guard imageExtensions.contains(url.pathExtension.lowercased()), !url.lastPathComponent.hasPrefix(".") else { return false }
        if hasScreenCaptureMark(url) { return true }
        let name = url.lastPathComponent
        return name.hasPrefix("Screenshot ") || name.hasPrefix("Screen Shot ")
    }

    struct Candidate: Equatable {
        var url: URL
        var created: Date
    }

    /// Screenshot files in `folder` made since `since` that aren't in `seen`, oldest first. `problem` says if the folder couldn't be read.
    static func candidates(in folder: URL, since: Date, skipping seen: Set<String>, problem: inout String?) -> [Candidate] {
        let fm = FileManager.default
        let files: [URL]
        do {
            files = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
                                               options: [.skipsHiddenFiles])
            problem = nil
        } catch {
            let code = (error as NSError).code
            problem = code == NSFileReadNoPermissionError || code == 257
                ? "Allow Margin to read \(folder.lastPathComponent): System Settings → Privacy & Security → Files and Folders"
                : nil
            return []
        }
        var out: [Candidate] = []
        for url in files where imageExtensions.contains(url.pathExtension.lowercased()) && !seen.contains(url.path) {
            let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            let made = values?.creationDate ?? values?.contentModificationDate ?? .distantPast
            guard made >= since, isScreenshotFile(url) else { continue }
            out.append(Candidate(url: url, created: made))
        }
        return out.sorted { $0.created < $1.created }
    }

    // MARK: Watching

    /// Starts watching the screenshots folder. A screenshot taken while Margin was closed is picked up too (but nothing older
    /// than the first time this ever ran).
    func start() {
        guard !started else { return }
        started = true
        FrontAppTracker.shared.start()
        seen = Set((library.screenshots.map(\.originalPath) + library.binned.map { $0.screenshot?.originalPath }).compactMap { $0 }) // deleted ones too: they stay deleted
        lastScan = Settings.shared.lastScreenshotScan ?? Date()
        Settings.shared.lastScreenshotScan = Date()
        watch(Self.screenshotFolder())
        rescan(context: nil)
        let t = Timer(timeInterval: 15, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        source?.cancel()
        source = nil
        watched = nil
        started = false
    }

    private func watch(_ folder: URL) {
        source?.cancel()
        source = nil
        watched = folder
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .extend], queue: .main)
        s.setEventHandler { [weak self] in self?.folderChanged() }
        s.setCancelHandler { close(fd) }
        s.resume()
        source = s
    }

    /// A safety net: the folder may have been changed in ⌘⇧5's options, or an event missed.
    private func tick() {
        let folder = Self.screenshotFolder()
        if folder != watched { watch(folder) }
        rescan(context: nil)
    }

    /// ⌘⇧3/4/5 was pressed: note the app and window you're in right now (read in the background).
    func noteCaptureKey() {
        guard Settings.shared.saveScreenshots, var place = currentWhere() else { return }
        let when = Date()
        queue.async { [weak self] in
            if place.pid > 0 { place.windowTitle = FrontAppTracker.windowTitle(pid: place.pid) }
            DispatchQueue.main.async { self?.captureNote = (place, when) }
        }
    }

    /// The noted place for a screenshot made at `created`, if the key press just before it was noted.
    func noteFor(created: Date) -> ScreenWhere? {
        guard let note = captureNote, created >= note.at.addingTimeInterval(-1),
              created.timeIntervalSince(note.at) < Self.noteLifetime else { return nil }
        return note.place
    }

    /// Test hook: pretend ⌘⇧4 was pressed in this place at this time.
    func debugNote(_ place: ScreenWhere, at: Date) { captureNote = (place, at) }

    /// Something happened in the folder. A screenshot takes a moment to finish, and may appear in two steps, so wait a beat;
    /// remember where you were when it started.
    private func folderChanged() {
        if pendingWhere == nil { pendingWhere = currentWhere() }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let context = self.pendingWhere
            self.pendingWhere = nil
            self.rescan(context: context)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    private func currentWhere() -> ScreenWhere? {
        guard let app = FrontAppTracker.shared.current() else { return nil }
        return ScreenWhere(app: app.localizedName ?? "", bundleID: app.bundleIdentifier, windowTitle: "", pid: app.processIdentifier)
    }

    /// Looks for new screenshot files and keeps each one. `context` is what was in front when the folder changed.
    func rescan(context: ScreenWhere?) {
        guard Settings.shared.saveScreenshots, !Settings.shared.paused else { return }
        let folder = Self.screenshotFolder()
        let since = lastScan.addingTimeInterval(-2)
        lastScan = Date()
        Settings.shared.lastScreenshotScan = lastScan
        var problem: String?
        let found = Self.candidates(in: folder, since: since, skipping: seen, problem: &problem)
        folderProblem = problem
        for c in found {
            seen.insert(c.url.path)
            let fresh = Date().timeIntervalSince(c.created) < Self.freshSeconds
            keep(file: c.url, created: c.created, context: noteFor(created: c.created) ?? (fresh ? context : nil))
        }
    }

    // MARK: Keeping

    /// Keeps a macOS screenshot file in the background.
    func keep(file url: URL, created: Date, context: ScreenWhere?) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let data = Self.stableData(url) else {
                // Still being written, or not readable yet: try again on a later scan (a few times).
                DispatchQueue.main.async {
                    let n = (self.attempts[url.path] ?? 0) + 1
                    self.attempts[url.path] = n
                    if n < 4 { self.seen.remove(url.path) }
                }
                return
            }
            var place = context ?? ScreenWhere()
            if place.pid > 0, place.windowTitle.isEmpty { place.windowTitle = FrontAppTracker.windowTitle(pid: place.pid) }
            guard !Self.excluded(place) else { return }
            self.make(data: data, created: created, source: .system, place: place, originalPath: url.path)
        }
    }

    /// Keeps a Tab+\ snip (the full-size picture Margin just took).
    func addSnip(png: Data, app: NSRunningApplication?) {
        guard Settings.shared.saveScreenshots, !Settings.shared.paused else { return }
        var place = ScreenWhere(app: app?.localizedName ?? "", bundleID: app?.bundleIdentifier, windowTitle: "",
                                pid: app?.processIdentifier ?? 0)
        queue.async { [weak self] in
            guard let self else { return }
            if place.pid > 0 { place.windowTitle = FrontAppTracker.windowTitle(pid: place.pid) }
            guard !Self.excluded(place) else { return }
            self.make(data: png, created: Date(), source: .snip, place: place, originalPath: nil)
        }
    }

    /// Password managers and the like are never saved.
    static func excluded(_ place: ScreenWhere) -> Bool {
        place.bundleID.map { Settings.shared.excludedBundleIDs.contains($0) } ?? false
    }

    /// The file's bytes once it has stopped growing, or nil.
    static func stableData(_ url: URL) -> Data? {
        var last = -1
        for _ in 0..<10 {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            if size > 0, size == last, let data = try? Data(contentsOf: url) { return data }
            last = size
            Thread.sleep(forTimeInterval: 0.25)
        }
        return nil
    }

    /// Reads, stores and labels one picture. Runs on the inbox's queue; the record is added on the main queue.
    @discardableResult
    func make(data: Data, created: Date, source: ScreenshotRecord.Source, place: ScreenWhere, originalPath: String?) -> ScreenshotRecord? {
        guard let jpeg = Snipper.downscaledJPEG(data, maxEdge: Self.maxEdge), let rep = NSBitmapImageRep(data: jpeg), let image = rep.cgImage else { return nil }
        let text = String((OCR.text(in: image) ?? "").prefix(Self.maxTextLength))
        let title = ScreenshotLabel.quick(app: place.app, windowTitle: place.windowTitle, text: text)
        var record = ScreenshotRecord(created: created, title: title)
        record.sector = ScreenshotLabel.sector(app: place.app, bundleID: place.bundleID, title: title, text: text)
        record.app = place.app
        record.windowTitle = place.windowTitle
        record.source = source
        record.text = text
        record.width = rep.pixelsWide
        record.height = rep.pixelsHigh
        record.originalPath = originalPath
        guard library.writeScreenshotImage(jpeg, for: record) else { return nil }
        let kept = record
        DispatchQueue.main.async { [self] in
            library.add(kept)
            onKept?(kept)
            refine(kept)
        }
        return kept
    }

    // MARK: Better labels

    /// With Local Mode on, the model on this Mac reads the context and writes a title (no Claude tokens). Anything you named
    /// yourself is left alone.
    func refine(_ record: ScreenshotRecord, done: (() -> Void)? = nil) {
        guard !record.titleLocked, Self.useLocal(), record.text.count + record.windowTitle.count >= 12 else { return done?() ?? () }
        let system = ScreenshotLabel.system(sectors: library.allSectors)
        let prompt = ScreenshotLabel.prompt(app: record.app, windowTitle: record.windowTitle, text: record.text)
        let id = record.id
        Self.localGenerate(system, prompt) { [library] text in
            if let text, let named = ChatNaming.parse(text) { library.applyScreenshotLabel(id, title: named.title, sector: named.sector) }
            done?()
        }
    }

    /// "Re-label": the on-Mac model if it's on, else Claude (a small Haiku call, about 400 tokens). Replaces the title unless
    /// it's one you typed (taking the lock off is up to you).
    func relabel(_ id: UUID, done: @escaping (_ claudeTokens: Int) -> Void) {
        guard let record = library.screenshot(id) else { return done(0) }
        let system = ScreenshotLabel.system(sectors: library.allSectors)
        let prompt = ScreenshotLabel.prompt(app: record.app, windowTitle: record.windowTitle, text: record.text)
        func viaClaude() {
            ChatNaming.claudeRun(prompt, system, .haiku) { [library] result in
                guard case .success(let reply) = result else { return done(0) }
                if let named = ChatNaming.parse(reply.text) { library.applyScreenshotLabel(id, title: named.title, sector: named.sector) }
                done(reply.tokens)
            }
        }
        guard Self.useLocal() else { return viaClaude() }
        Self.localGenerate(system, prompt) { [library] text in
            if let text, let named = ChatNaming.parse(text), named.title != nil {
                library.applyScreenshotLabel(id, title: named.title, sector: named.sector)
                done(0)
            } else {
                viaClaude()
            }
        }
    }
}
