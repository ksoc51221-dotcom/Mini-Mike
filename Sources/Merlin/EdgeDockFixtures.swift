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

    init(_ state: SpotifyState) { current = state }

    var state: SpotifyState {
        get { lock.lock(); defer { lock.unlock() }; return current }
        set { lock.lock(); current = newValue; lock.unlock() }
    }
    var sent: [SpotifyCommand] { lock.lock(); defer { lock.unlock() }; return commands }

    func isRunning() -> Bool { state != .notRunning }
    func fetch() -> SpotifyState { state }
    func send(_ command: SpotifyCommand) { lock.lock(); commands.append(command); lock.unlock() }
}

/// Hands back one image for every URL, at once.
struct FixtureImageLoader: DockImageLoader {
    let image: NSImage?
    func load(_ url: URL, completion: @escaping (NSImage?) -> Void) { completion(image) }
}

enum EdgeDockFixtures {
    /// A song playing, with a cover URL the fixture loader answers.
    static let track = SpotifyTrack(title: "Midnight City", artist: "M83",
                                    artworkURL: URL(string: "https://i.scdn.co/image/fixture"), isPlaying: true)

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
