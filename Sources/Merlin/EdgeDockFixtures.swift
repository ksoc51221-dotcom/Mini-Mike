import AppKit

// Stand-ins for the dock's system parts, for the tests and the pictures: no live workspace (nothing is launched), no live
// Spotify, and throwaway defaults (never the app's own).

/// Apps that exist only here. Their icons are coloured rounded squares; `open` only records the URL.
final class FixtureDockWorkspace: DockWorkspace, @unchecked Sendable {
    static let sample: [DockApp] = [
        DockApp(bundleID: DockAppStore.claudeBundleID, name: "Claude"),
        DockApp(bundleID: "fixture.calendar", name: "Calendar"),
        DockApp(bundleID: "fixture.figma", name: "Figma"),
        DockApp(bundleID: "fixture.mail", name: "Mail"),
        DockApp(bundleID: "fixture.notion", name: "Notion"),
        DockApp(bundleID: "fixture.preview", name: "Preview"),
        DockApp(bundleID: "fixture.safari", name: "Safari"),
        DockApp(bundleID: "fixture.terminal", name: "Terminal"),
        DockApp(bundleID: "fixture.xcode", name: "Xcode"),
    ]

    private let apps: [DockApp]
    private let lock = NSLock()
    private var openedURLs: [URL] = []

    init(apps: [DockApp] = FixtureDockWorkspace.sample) { self.apps = apps }

    var opened: [URL] { lock.lock(); defer { lock.unlock() }; return openedURLs }

    func url(forBundleID id: String) -> URL? { URL(fileURLWithPath: "/fixture/\(id).app") }

    func open(_ url: URL) { lock.lock(); openedURLs.append(url); lock.unlock() }

    func installedApps() -> [DockApp] { apps }

    func icon(for url: URL) -> NSImage {
        // djb2, so neighbouring names get clearly different hues.
        let seed = url.lastPathComponent.unicodeScalars.reduce(UInt64(5381)) { ($0 &<< 5) &+ $0 &+ UInt64($1.value) }
        let hue = CGFloat(seed % 12) / 12
        return NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            let r = rect.insetBy(dx: 4, dy: 4)
            NSGradient(starting: NSColor(hue: hue, saturation: 0.55, brightness: 0.95, alpha: 1),
                       ending: NSColor(hue: hue, saturation: 0.75, brightness: 0.70, alpha: 1))?
                .draw(in: NSBezierPath(roundedRect: r, xRadius: 13, yRadius: 13), angle: -90)
            NSColor.white.withAlphaComponent(0.85).setFill()
            NSBezierPath(ovalIn: NSRect(x: r.midX - 9, y: r.midY - 9, width: 18, height: 18)).fill()
            return true
        }
    }
}

/// A Spotify that answers from memory and records every command.
final class FixtureSpotifyBackend: SpotifyBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var current: SpotifyState
    private var commands: [SpotifyCommand] = []
    private var sources: [String] = []

    init(_ state: SpotifyState) { current = state }

    /// The script text the live backend would run for each command sent (built, never run).
    var scripts: [String] { lock.lock(); defer { lock.unlock() }; return sources }

    var state: SpotifyState {
        get { lock.lock(); defer { lock.unlock() }; return current }
        set { lock.lock(); current = newValue; lock.unlock() }
    }
    var sent: [SpotifyCommand] { lock.lock(); defer { lock.unlock() }; return commands }

    func isRunning() -> Bool { state != .notRunning }
    func fetch() -> SpotifyState { state }
    func send(_ command: SpotifyCommand) {
        let source = LiveSpotifyBackend.source(for: command) // nil: no script built (a bad track URI)
        lock.lock(); commands.append(command); if let source { sources.append(source) }; lock.unlock()
    }
}

/// Hands back one image for every URL, at once.
struct FixtureImageLoader: DockImageLoader {
    let image: NSImage?
    func load(_ url: URL, completion: @escaping (NSImage?) -> Void) { completion(image) }
}

enum EdgeDockFixtures {
    /// A song playing, with a cover URL the fixture loader answers.
    static let track = SpotifyTrack(title: "Midnight City", artist: "M83",
                                    artworkURL: URL(string: "https://i.scdn.co/image/fixture"), isPlaying: true,
                                    uri: "spotify:track:6GyFP1nfCDB8lbD2bG0Hq9")

    /// Made-up saved songs (memory only, nothing on disk): three, the second starred, newest first.
    static func songs(_ count: Int = 3) -> SpotifySongs {
        let store = SpotifySongs(folder: nil)
        seed(store, count)
        return store
    }

    /// Puts the made-up songs into `store` (a panel's own in-memory list): the second is starred.
    static func seed(_ store: SpotifySongs, _ count: Int = 3) {
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        let sample: [(String, String, String)] = [
            ("Midnight City", "M83", "spotify:track:6GyFP1nfCDB8lbD2bG0Hq9"),
            ("Mint Morning", "The Low Tide Club", "spotify:track:0AbCdEfGhIjKlMnOpQrStU"),
            ("Paper Harbour", "Mira Vale", "spotify:track:1ZyXwVuTsRqPoNmLkJiHgF"),
        ]
        for (i, s) in sample.prefix(count).enumerated() {
            store.saw(SpotifyTrack(title: s.0, artist: s.1, artworkURL: nil, isPlaying: true, uri: s.2),
                      now: base.addingTimeInterval(Double(-i) * 3600))
        }
        if count > 1 { store.toggleStar(SpotifyTrack(title: sample[1].0, artist: sample[1].1, artworkURL: nil,
                                                     isPlaying: false, uri: sample[1].2)) }
    }

    /// A saturated magenta-to-orange cover (far from emerald, so the palette change shows).
    static func coverImage() -> NSImage {
        NSImage(size: NSSize(width: 300, height: 300), flipped: false) { rect in
            NSGradient(colors: [NSColor(srgbRed: 0.78, green: 0.10, blue: 0.55, alpha: 1),
                                NSColor(srgbRed: 0.96, green: 0.45, blue: 0.12, alpha: 1)])?.draw(in: rect, angle: 45)
            NSColor(srgbRed: 0.25, green: 0.05, blue: 0.30, alpha: 0.5).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 90, dy: 90)).fill()
            return true
        }
    }

    /// A generated cover: a gradient between two colours at `angle`, optionally with a centre disc.
    private static func cover(_ a: NSColor, _ b: NSColor, disc: NSColor? = nil, angle: CGFloat = 45) -> NSImage {
        NSImage(size: NSSize(width: 300, height: 300), flipped: false) { rect in
            NSGradient(colors: [a, b])?.draw(in: rect, angle: angle)
            if let disc { disc.setFill(); NSBezierPath(ovalIn: rect.insetBy(dx: 100, dy: 100)).fill() }
            return true
        }
    }

    private static func srgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }

    /// Test and picture covers (generated, no files): very bright, very dark, grey, one colour, and a blue one.
    static func coverBright() -> NSImage { cover(srgb(1, 0.98, 0.80), srgb(1, 1, 1), disc: srgb(1, 0.93, 0.55)) }
    static func coverDark() -> NSImage { cover(srgb(0.02, 0.02, 0.04), srgb(0.07, 0.06, 0.09), disc: srgb(0.04, 0.04, 0.06)) }
    static func coverGrey() -> NSImage { cover(srgb(0.35, 0.35, 0.36), srgb(0.62, 0.62, 0.63), disc: srgb(0.48, 0.48, 0.49)) }
    static func coverSingle() -> NSImage { cover(srgb(0.10, 0.60, 0.25), srgb(0.10, 0.60, 0.25)) }
    static func coverBlue() -> NSImage { cover(srgb(0.08, 0.22, 0.85), srgb(0.30, 0.55, 0.98), disc: srgb(0.05, 0.12, 0.55)) }

    /// Defaults that live in memory only (nothing reaches disk); `forget` is kept for symmetry and does nothing more.
    static func defaults() -> (UserDefaults, String) {
        let name = "merlin.dock-fixture.memory"
        return (MemoryDefaults(suiteName: name)!, name)
    }

    static func forget(_ name: String) {}

    /// A store on the fixture workspace (Claude is pinned first, as on a Mac with Claude), plus `extra` pinned apps.
    static func appStore(_ workspace: FixtureDockWorkspace, defaults: UserDefaults, extra: [DockApp] = []) -> DockAppStore {
        let store = DockAppStore(defaults: defaults, workspace: workspace)
        extra.forEach { store.pin($0) }
        return store
    }

    /// A service on the fixture backend, already holding `state` (and the cover, when a song plays).
    static func spotify(_ backend: FixtureSpotifyBackend, cover: NSImage? = nil) -> SpotifyService {
        let s = SpotifyService(backend: backend, loader: FixtureImageLoader(image: cover))
        s.refresh()
        _ = waitUntil { s.state == backend.state }
        return s
    }

    /// Runs the main run loop until `done` or the deadline.
    @discardableResult
    static func waitUntil(_ timeout: TimeInterval = 2, _ done: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !done() && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        return done()
    }
}

/// UserDefaults that keep every value in a dictionary and never read or write the real domain.
final class MemoryDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]
    override func object(forKey key: String) -> Any? { values[key] }
    override func data(forKey key: String) -> Data? { values[key] as? Data }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func removeObject(forKey key: String) { values[key] = nil }
}
