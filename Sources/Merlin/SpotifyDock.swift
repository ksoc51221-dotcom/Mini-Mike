import AppKit
import OSLog
import Combine

// MARK: - Model

struct SpotifyTrack: Equatable {
    var title: String
    var artist: String
    var artworkURL: URL?
    var isPlaying: Bool
    /// The track's `spotify url`, only when it is a valid `spotify:track:` URI (else nil).
    var uri: String? = nil
}

enum SpotifyState: Equatable {
    case notRunning, denied, stopped, track(SpotifyTrack)
}

extension SpotifyState {
    /// A short name for `DockPerf` lines.
    var perfName: String {
        switch self {
        case .notRunning: return "closed"
        case .denied: return "denied"
        case .stopped: return "stopped"
        case .track(let t): return t.isPlaying ? "playing" : "paused"
        }
    }
}

enum SpotifyCommand: Equatable { case playPause, play, pause, next, previous, stop, playTrack(String) }

protocol SpotifyBackend {
    func isRunning() -> Bool
    func fetch() -> SpotifyState          // blocking; called off the main thread
    func send(_ command: SpotifyCommand)  // blocking; called off the main thread
}

// MARK: - Live backend (Apple Events; never launches Spotify)

struct LiveSpotifyBackend: SpotifyBackend {
    static let bundleID = "com.spotify.client"
    static let delimiter = "\u{1F}"

    func isRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
    }

    /// The poll script. Constant: nothing from outside goes into it. The names are long on purpose: `st` is an
    /// AppleScript word (as in "1st"), and with it the script did not compile, so no song ever showed.
    static let fetchSource = """
    tell application id "\(bundleID)"
        set playerState to player state as text
        if playerState is "stopped" then return playerState
        set theTrack to current track
        set sep to (ASCII character 31)
        return playerState & sep & (name of theTrack) & sep & (artist of theTrack) & sep & (artwork url of theTrack) & sep & (spotify url of theTrack)
    end tell
    """

    func fetch() -> SpotifyState {
        guard isRunning() else { return .notRunning }
        var error: NSDictionary?
        let result = NSAppleScript(source: Self.fetchSource)?.executeAndReturnError(&error).stringValue
        if let code = (error?[NSAppleScript.errorNumber] as? NSNumber)?.intValue {
            return code == -1743 ? .denied : .stopped
        }
        return Self.parse(result)
    }

    static func parse(_ raw: String?) -> SpotifyState {
        guard let raw, !raw.isEmpty else { return .stopped }
        let parts = raw.components(separatedBy: delimiter)
        guard parts.count >= 3, parts[0] != "stopped" else { return .stopped }
        let art = parts.count > 3 ? URL(string: parts[3]) : nil
        let uri = parts.count > 4 && SpotifyTrackURI.isValid(parts[4]) ? parts[4] : nil
        return .track(SpotifyTrack(title: parts[1], artist: parts[2], artworkURL: art,
                                   isPlaying: parts[0].lowercased().contains("playing"), uri: uri))
    }

    /// The script for a command: constant text (only the bundle id goes in), never song or user text, except the one
    /// track URI of `playTrack`, checked again here: a value that is not exactly `spotify:track:` + 22 ASCII letters or
    /// digits builds no script (nil).
    /// Spotify has no stop command: stop is `pause`, then `player position` (read-write in its dictionary) back to 0.
    static func source(for command: SpotifyCommand) -> String? {
        switch command {
        case .playTrack(let uri):
            guard SpotifyTrackURI.isValid(uri) else { return nil }
            return "tell application id \"\(bundleID)\" to play track \"\(uri)\""
        case .playPause: return "tell application id \"\(bundleID)\" to playpause"
        case .play: return "tell application id \"\(bundleID)\" to play"
        case .pause: return "tell application id \"\(bundleID)\" to pause"
        case .next: return "tell application id \"\(bundleID)\" to next track"
        case .previous: return "tell application id \"\(bundleID)\" to previous track"
        case .stop:
            return """
            tell application id "\(bundleID)"
                pause
                set player position to 0
            end tell
            """
        }
    }

    func send(_ command: SpotifyCommand) {
        guard isRunning(), let source = Self.source(for: command) else { return }
        var error: NSDictionary?
        _ = NSAppleScript(source: source)?.executeAndReturnError(&error)
    }
}

// MARK: - Focus guard (a song from the mini player never brings Spotify to the front)

/// Spotify brings itself to the front when it gets `play track` (Merlin's script has no `activate`). The guard notes the
/// front app before the command and, if Spotify then comes to the front, gives the front back: it hides Spotify again
/// when Spotify was hidden before, else it activates the app that was in front. Cost: Spotify can show for a moment.
enum SpotifyFocusGuard {
    /// What was true just before the command.
    struct Before: Equatable {
        /// The app in front (its process id), nil when none.
        let front: pid_t?
        /// Spotify itself was in front: nothing to give back.
        let spotifyWasFront: Bool
        /// Spotify was hidden (Cmd-H): hide it again rather than leave its window on screen.
        let spotifyWasHidden: Bool
    }

    enum Repair: Equatable { case none, hideSpotify, activate(pid_t) }

    /// How long after the command a Spotify activation still counts as caused by it.
    static let window: TimeInterval = 2

    /// The repair for an app that just came to the front.
    static func repair(_ before: Before, activatedIsSpotify: Bool) -> Repair {
        guard activatedIsSpotify, !before.spotifyWasFront else { return .none }
        if before.spotifyWasHidden { return .hideSpotify }
        if let front = before.front { return .activate(front) }
        return .none
    }
}

/// Watches one command's focus (a fake in the tests: nothing here touches a real app there).
protocol SpotifyFocusKeeping: AnyObject {
    /// Called on the main thread just before `play track` is sent.
    func keepFocus()
}

/// The live guard: one `NSWorkspace` activation observer for `SpotifyFocusGuard.window` seconds after each song.
final class LiveSpotifyFocus: SpotifyFocusKeeping {
    /// One line per repair (`/usr/bin/log show --predicate 'subsystem == "com.kien.merlin" && category == "spotify"'`).
    static let logger = Logger(subsystem: "com.kien.merlin", category: "spotify")
    private var observer: NSObjectProtocol?
    private var token = 0

    func keepFocus() {
        let ws = NSWorkspace.shared
        let spotify = NSRunningApplication.runningApplications(withBundleIdentifier: LiveSpotifyBackend.bundleID).first
        let front = ws.frontmostApplication
        let before = SpotifyFocusGuard.Before(front: front?.processIdentifier,
                                              spotifyWasFront: front?.bundleIdentifier == LiveSpotifyBackend.bundleID,
                                              spotifyWasHidden: spotify?.isHidden ?? false)
        if let observer { ws.notificationCenter.removeObserver(observer) }
        token += 1
        let mine = token
        observer = ws.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil,
                                                     queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let repair = SpotifyFocusGuard.repair(before, activatedIsSpotify: app?.bundleIdentifier == LiveSpotifyBackend.bundleID)
            guard repair != .none else { return }
            Self.logger.notice("spotify focus: Spotify came to the front after play track; repair \(String(describing: repair), privacy: .public)")
            Self.apply(repair)
            self?.stop(mine)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + SpotifyFocusGuard.window) { [weak self] in self?.stop(mine) }
    }

    private func stop(_ mine: Int) {
        guard mine == token, let observer else { return }
        NSWorkspace.shared.notificationCenter.removeObserver(observer)
        self.observer = nil
    }

    private static func apply(_ repair: SpotifyFocusGuard.Repair) {
        switch repair {
        case .none: break
        case .hideSpotify:
            NSRunningApplication.runningApplications(withBundleIdentifier: LiveSpotifyBackend.bundleID).first?.hide()
        case .activate(let pid):
            NSRunningApplication(processIdentifier: pid)?.activate()
        }
    }
}

// MARK: - Cover loading

protocol DockImageLoader { func load(_ url: URL, completion: @escaping (NSImage?) -> Void) }

struct LiveDockImageLoader: DockImageLoader {
    static func isAllowed(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return ["scdn.co", "spotifycdn.com"].contains { host == $0 || host.hasSuffix("." + $0) }
    }

    func load(_ url: URL, completion: @escaping (NSImage?) -> Void) {
        guard Self.isAllowed(url) else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            let image = data.flatMap { NSImage(data: $0) }
            DispatchQueue.main.async { completion(image) }
        }.resume()
    }
}

// MARK: - Palette

struct DockPalette: Equatable {
    var base: NSColor
    var rim: NSColor
    var accent: NSColor
    var accent2: NSColor
    var ink: NSColor

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: 1)
    }

    // Pure colour helpers for the glass drawing (no state).
    /// The base lifted toward white (the disc's lit top-left).
    var baseLight: NSColor { (base.usingColorSpace(.sRGB) ?? base).blended(withFraction: 0.22, of: .white) ?? base }
    /// The base pushed toward black (item wells, card glass, shadows).
    var baseDark: NSColor { (base.usingColorSpace(.sRGB) ?? base).blended(withFraction: 0.55, of: .black) ?? base }
    /// A light tint of the rim (rim lights and hairlines).
    var rimTint: NSColor { (rim.usingColorSpace(.sRGB) ?? rim).blended(withFraction: 0.6, of: .white) ?? rim }
    /// Text on an accent fill: black or white, whichever contrasts more with `accent` (always at least about 4.58:1).
    var onAccent: NSColor { Self.onFill(accent) }

    static func onFill(_ fill: NSColor) -> NSColor {
        let black = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1), white = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        return contrast(black, fill) >= contrast(white, fill) ? black : white
    }

    /// The default (no song; 2026-11-26): 60 % light grey (`rim`: the rims, the ring's light and the glass lines),
    /// 30 % dark charcoal (`base`: the wells and fills), 10 % electric cyan #00E5FF (`accent`: the ring line, the strings,
    /// the play button, an open item). `accent2` is a mid grey (the stop button, the breathing dot). No orange.
    static let standard = DockPalette(base: rgb(0x232529), rim: rgb(0xC9CED4), accent: rgb(0x00E5FF),
                                      accent2: rgb(0x8C939B), ink: rgb(0xF4F5F2))
    /// The electric cyan: the default accent everywhere in Merlin.
    static let cyan = rgb(0x00E5FF)

    // WCAG relative luminance and contrast ratio.
    private static func luminance(_ c: NSColor) -> CGFloat {
        let s = c.usingColorSpace(.sRGB) ?? c
        func lin(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(s.redComponent) + 0.7152 * lin(s.greenComponent) + 0.0722 * lin(s.blueComponent)
    }

    static func contrast(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    private static func hsb(_ h: CGFloat, _ s: CGFloat, _ b: CGFloat) -> NSColor {
        var x = h.truncatingRemainder(dividingBy: 1)
        if x < 0 { x += 1 }
        return NSColor(hue: x, saturation: s, brightness: b, alpha: 1)
    }

    // MARK: Guards (pure; the tests read the same numbers)

    /// Two accents count as different when their hues are at least this far apart (0...0.5 of the circle, 0.08 = 29 degrees)...
    static let minHueGap: CGFloat = 0.08
    /// ...or, when either is nearly grey, when their contrast ratio is at least this.
    static let minToneContrast: CGFloat = 1.6
    /// The ink on the flat path's solid base, and the text on an accent fill, keep at least this. (On the glass the system
    /// picks the text colour; that is checked only on a real screen.)
    static let minInkContrast: CGFloat = 4.5

    /// The hue distance of two colours on the circle (0 same, 0.5 opposite).
    static func hueGap(_ a: NSColor, _ b: NSColor) -> CGFloat {
        var ha: CGFloat = 0, hb: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, al: CGFloat = 0
        (a.usingColorSpace(.sRGB) ?? a).getHue(&ha, saturation: &s, brightness: &v, alpha: &al)
        (b.usingColorSpace(.sRGB) ?? b).getHue(&hb, saturation: &s, brightness: &v, alpha: &al)
        let d = abs(ha - hb)
        return min(d, 1 - d)
    }

    private static func saturation(_ c: NSColor) -> CGFloat {
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, al: CGFloat = 0
        (c.usingColorSpace(.sRGB) ?? c).getHue(&h, saturation: &s, brightness: &v, alpha: &al)
        return s
    }

    /// Whether accent and accent2 look different: a clear hue gap between two coloured accents, else a clear tone gap.
    static func accentsDiffer(_ a: NSColor, _ b: NSColor) -> Bool {
        if saturation(a) >= 0.25 && saturation(b) >= 0.25 && hueGap(a, b) >= minHueGap { return true }
        return contrast(a, b) >= minToneContrast
    }

    /// The second accent: `wanted`, moved around the hue circle (then in tone) until it differs from `accent`.
    private static func distinct(_ wanted: NSColor, from accent: NSColor, on base: NSColor, hue: CGFloat, sat: CGFloat) -> NSColor {
        if accentsDiffer(accent, wanted) { return wanted }
        for step: CGFloat in [0.12, -0.12, 0.18, -0.18, 0.25, -0.25] {
            let c = ensure(hsb(hue + step, max(0.55, sat), 0.9), on: base, ratio: 3)
            if accentsDiffer(accent, c) { return c }
        }
        for c in [ensure(hsb(hue, max(0.5, sat), 0.55), on: base, ratio: 3), hsb(hue, 0.1, 0.98)] where accentsDiffer(accent, c) {
            return c
        }
        return wanted
    }

    /// Lightens a colour until it reaches `ratio` against `base`.
    private static func ensure(_ c: NSColor, on base: NSColor, ratio: CGFloat) -> NSColor {
        var color = (c.usingColorSpace(.sRGB) ?? c)
        var n = 0
        while contrast(color, base) < ratio && n < 40 {
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            color = NSColor(hue: h, saturation: max(0, s - 0.02), brightness: min(1, b + 0.03), alpha: 1)
            n += 1
        }
        return color
    }

    static func from(image: NSImage) -> DockPalette {
        let side = 24
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = ctx.data else { return .standard }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        let px = data.bindMemory(to: UInt8.self, capacity: side * side * 4)

        let buckets = 12
        var weight = [CGFloat](repeating: 0, count: buckets)
        var sx = [CGFloat](repeating: 0, count: buckets), sy = sx
        var satSum = [CGFloat](repeating: 0, count: buckets)
        for i in 0..<(side * side) {
            let a = CGFloat(px[i * 4 + 3]) / 255
            guard a > 0.5 else { continue }
            let c = NSColor(srgbRed: CGFloat(px[i * 4]) / 255 / a, green: CGFloat(px[i * 4 + 1]) / 255 / a,
                            blue: CGFloat(px[i * 4 + 2]) / 255 / a, alpha: 1)
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, al: CGFloat = 0
            c.getHue(&h, saturation: &s, brightness: &b, alpha: &al)
            guard s > 0.25, b > 0.2 else { continue }
            let k = min(buckets - 1, Int(h * CGFloat(buckets)))
            let w = s * b
            weight[k] += w
            sx[k] += cos(h * 2 * .pi) * w; sy[k] += sin(h * 2 * .pi) * w
            satSum[k] += s * w
        }
        func hue(_ k: Int) -> CGFloat {
            var h = atan2(sy[k], sx[k]) / (2 * .pi)
            if h < 0 { h += 1 }
            return h
        }
        guard let top = weight.indices.max(by: { weight[$0] < weight[$1] }), weight[top] > 0.5 else {
            // Grey cover: neutral dark palette.
            let ink = hsb(0, 0, 0.97)
            let base = hsb(0, 0, 0.15)
            let accent = ensure(hsb(0, 0, 0.82), on: base, ratio: 3)
            let accent2 = distinct(ensure(hsb(0, 0, 0.55), on: base, ratio: 3), from: accent, on: base, hue: 0, sat: 0)
            return DockPalette(base: base, rim: hsb(0, 0, 0.6), accent: accent, accent2: accent2, ink: ink)
        }
        let h1 = hue(top)
        let s1 = min(1, max(0.55, satSum[top] / weight[top]))
        // Second hue: at least two buckets (60 degrees) away and reasonably present.
        var second: Int?
        for k in weight.indices {
            let d = min(abs(k - top), buckets - abs(k - top))
            if d >= 2 && weight[k] > weight[top] * 0.15 && (second == nil || weight[k] > weight[second!]) { second = k }
        }
        let h2 = second.map(hue) ?? (h1 + 0.12)

        // The same 60-30-10 as `standard`, from the cover: a light grey with a touch of the cover's hue (60 %), a
        // charcoal with a little more of it (30 %), and the cover's dominant colour as the accent (10 %).
        let ink = hsb(h1, 0.04, 0.98)
        let base = hsb(h1, min(0.35, s1 * 0.4), 0.17)
        let rim = ensure(hsb(h1, 0.14, 0.86), on: base, ratio: 3)
        // The accent is light enough to read on the dark base (4.5:1, so a deep crimson cover still gives a visible line).
        let accent = ensure(hsb(h1, s1, 0.9), on: base, ratio: 4.5)
        // One accent per cover: the second colour is a neutral grey with a touch of the same hue (no second hue).
        _ = h2
        // Tone only, never another hue: the darkest near-grey that still reads on the base (3:1) and stays 1.6:1 from
        // the accent; lighter if the accent is dark.
        var accent2 = hsb(h1, 0.06, 0.6)
        for b in stride(from: 0.62, through: 0.98, by: 0.02) {
            let g = hsb(h1, 0.06, CGFloat(b))
            if contrast(g, base) >= 3 { accent2 = g; break }
        }
        if contrast(accent, accent2) < minToneContrast {
            for b in stride(from: 0.98, through: 0.6, by: -0.02) {
                let g = hsb(h1, 0.06, CGFloat(b))
                if contrast(g, base) >= 3 && contrast(accent, g) >= minToneContrast { accent2 = g; break }
            }
        }
        return DockPalette(base: base, rim: rim, accent: accent, accent2: accent2, ink: ink)
    }
}

// MARK: - Service

final class SpotifyService: ObservableObject {
    static let shared = SpotifyService(focus: LiveSpotifyFocus())
    static let notificationName = Notification.Name("com.spotify.client.PlaybackStateChanged")

    @Published private(set) var state: SpotifyState = .notRunning
    @Published private(set) var cover: NSImage?
    @Published private(set) var palette: DockPalette = .standard

    private let backend: SpotifyBackend
    private let loader: DockImageLoader
    /// Gives the front back after a song starts (nil: no guard; only the shared live service has one).
    private let focus: SpotifyFocusKeeping?
    private let queue = DispatchQueue(label: "merlin.spotify", qos: .userInitiated)
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    private var coverURL: URL?
    private var coverPalette: DockPalette?
    /// The beat behind the strings round the record (one for the disc and the mini window).
    let beat: SpotifyBeat
    /// The dock shows (between `start` and `stop`).
    private(set) var shown = false
    private var motionObserver: NSObjectProtocol?

    init(backend: SpotifyBackend = LiveSpotifyBackend(), loader: DockImageLoader = LiveDockImageLoader(),
         beat: SpotifyBeat = SpotifyBeat(), focus: SpotifyFocusKeeping? = nil) {
        self.backend = backend
        self.loader = loader
        self.focus = focus
        self.beat = beat
    }

    func start() {
        shown = true
        updateBeat()
        if motionObserver == nil {
            motionObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.updateBeat() // Reduce Motion on: the tap stops; off: it may start
            }
        }
        refresh()
        if observer == nil {
            observer = DistributedNotificationCenter.default().addObserver(
                forName: Self.notificationName, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
        }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
        observer = nil
        if let motionObserver { NSWorkspace.shared.notificationCenter.removeObserver(motionObserver) }
        motionObserver = nil
        shown = false
        updateBeat()
    }

    /// The beat listens only while the dock shows, Spotify runs and a song plays (and motion is on).
    private func updateBeat() {
        var playing = false, paused = false, song: String?
        if case .track(let t) = state {
            playing = t.isPlaying
            paused = !t.isPlaying
            song = t.uri ?? (t.title + "\u{1F}" + t.artist)
        }
        beat.update(shown: shown, running: state != .notRunning, playing: playing, paused: paused, song: song)
    }

    func refresh() {
        let backend = backend
        queue.async { [weak self] in
            let s = backend.isRunning() ? backend.fetch() : .notRunning
            DispatchQueue.main.async { self?.apply(s) }
        }
    }

    func send(_ command: SpotifyCommand) {
        let backend = backend
        // Spotify brings itself to the front on `play track` (the mini player's songs and the assistant's "play X"):
        // `focus` gives the front back (`SpotifyFocusGuard`). The other commands leave the front alone.
        if case .playTrack = command, let focus {
            if Thread.isMainThread { focus.keepFocus() } else { DispatchQueue.main.sync { focus.keepFocus() } }
        }
        queue.async { [weak self] in
            if backend.isRunning() { backend.send(command) }
            let s = backend.isRunning() ? backend.fetch() : .notRunning
            DispatchQueue.main.async { self?.apply(s) }
        }
    }

    /// Plays one saved song (`play track`), only while Spotify runs (never launches it). A URI that is not a valid
    /// `spotify:track:` URI sends nothing.
    func play(_ uri: String) {
        guard SpotifyTrackURI.isValid(uri) else { return }
        send(.playTrack(uri))
    }

    private func apply(_ new: SpotifyState) {
        if state != new { state = new }
        updateBeat()
        var url: URL?
        if case .track(let t) = new { url = t.artworkURL }
        if url != coverURL {
            coverURL = url
            cover = nil
            coverPalette = nil // `updatePalette` keeps the shown palette until the new cover has one
            if let url {
                loader.load(url) { [weak self] image in
                    guard let self, self.coverURL == url, let image else { return } // a failed load changes nothing
                    self.cover = image
                    self.coverPalette = DockPalette.from(image: image)
                    self.updatePalette()
                }
            }
        }
        updatePalette()
    }

    /// The default (off-white, charcoal, cyan) unless a song is loaded. With a song, playing OR paused, the cover's palette
    /// once it exists; until then (or if the cover never loads) the palette already shown stays, so two songs never pass
    /// through the default. Spotify closed, or open with no song: the default.
    private func updatePalette() {
        var target = DockPalette.standard
        if case .track = state { target = coverPalette ?? palette }
        if target != palette { palette = target }
        // The theme follows the music in the lens glass and in the rest of Merlin (its accent).
        EdgeLensRenderer.shared.setTint(palette.accent)
        ThemeStore.shared.setMusicAccent(palette == .standard ? nil : palette.accent)
    }
}
