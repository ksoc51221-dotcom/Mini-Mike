import AppKit
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

    static let emerald = DockPalette(base: rgb(0x0B2B22), rim: rgb(0x10B981), accent: rgb(0xFF6B4A),
                                     accent2: rgb(0xF0509A), ink: rgb(0xF5FFFA))

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
              let data = ctx.data else { return .emerald }
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

        let ink = hsb(h1, 0.04, 0.98)
        let base = hsb(h1, min(0.6, max(0.4, s1 * 0.7)), 0.16)
        let rim = ensure(hsb(h1, s1, 0.85), on: base, ratio: 3)
        let accent = ensure(hsb(h1, s1, 0.9), on: base, ratio: 3)
        let accent2 = distinct(ensure(hsb(h2, max(0.55, s1), 0.9), on: base, ratio: 3), from: accent, on: base, hue: h1, sat: s1)
        return DockPalette(base: base, rim: rim, accent: accent, accent2: accent2, ink: ink)
    }
}

// MARK: - Service

final class SpotifyService: ObservableObject {
    static let shared = SpotifyService()
    static let notificationName = Notification.Name("com.spotify.client.PlaybackStateChanged")

    @Published private(set) var state: SpotifyState = .notRunning
    @Published private(set) var cover: NSImage?
    @Published private(set) var palette: DockPalette = .emerald

    private let backend: SpotifyBackend
    private let loader: DockImageLoader
    private let queue = DispatchQueue(label: "merlin.spotify", qos: .userInitiated)
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    private var coverURL: URL?
    private var coverPalette: DockPalette?

    init(backend: SpotifyBackend = LiveSpotifyBackend(), loader: DockImageLoader = LiveDockImageLoader()) {
        self.backend = backend
        self.loader = loader
    }

    func start() {
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

    /// Emerald unless a song plays. While one plays, the cover's palette once it exists; until then (or if the cover never
    /// loads) the palette already shown stays, so two songs never pass through emerald.
    private func updatePalette() {
        var target = DockPalette.emerald
        if case .track(let t) = state, t.isPlaying { target = coverPalette ?? palette }
        if target != palette { palette = target }
    }
}
