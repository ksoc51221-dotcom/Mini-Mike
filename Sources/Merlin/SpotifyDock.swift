import AppKit
import Combine

// MARK: - Model

struct SpotifyTrack: Equatable {
    var title: String
    var artist: String
    var artworkURL: URL?
    var isPlaying: Bool
}

enum SpotifyState: Equatable {
    case notRunning, denied, stopped, track(SpotifyTrack)
}

enum SpotifyCommand { case playPause, next, previous }

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

    func fetch() -> SpotifyState {
        guard isRunning() else { return .notRunning }
        let source = """
        tell application id "\(Self.bundleID)"
            set st to player state as text
            if st is "stopped" then return st
            set tr to current track
            set d to (ASCII character 31)
            return st & d & (name of tr) & d & (artist of tr) & d & (artwork url of tr)
        end tell
        """
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue
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
        return .track(SpotifyTrack(title: parts[1], artist: parts[2], artworkURL: art,
                                   isPlaying: parts[0].lowercased().contains("playing")))
    }

    func send(_ command: SpotifyCommand) {
        guard isRunning() else { return }
        let verb: String
        switch command {
        case .playPause: verb = "playpause"
        case .next: verb = "next track"
        case .previous: verb = "previous track"
        }
        var error: NSDictionary?
        _ = NSAppleScript(source: "tell application id \"\(Self.bundleID)\" to \(verb)")?.executeAndReturnError(&error)
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
        NSColor(hue: h.truncatingRemainder(dividingBy: 1), saturation: s, brightness: b, alpha: 1)
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
            let base = hsb(0, 0, 0.15)
            return DockPalette(base: base, rim: hsb(0, 0, 0.6), accent: ensure(hsb(0, 0, 0.8), on: base, ratio: 3),
                               accent2: ensure(hsb(0, 0, 0.65), on: base, ratio: 3), ink: hsb(0, 0, 0.97))
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

        let base = hsb(h1, min(0.6, max(0.4, s1 * 0.7)), 0.16)
        let rim = ensure(hsb(h1, s1, 0.85), on: base, ratio: 3)
        let accent = ensure(hsb(h1, s1, 0.9), on: base, ratio: 3)
        let accent2 = ensure(hsb(h2, max(0.55, s1), 0.9), on: base, ratio: 3)
        let ink = hsb(h1, 0.04, 0.98)
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

    private func apply(_ new: SpotifyState) {
        if state != new { state = new }
        var url: URL?
        if case .track(let t) = new { url = t.artworkURL }
        if url != coverURL {
            coverURL = url
            cover = nil
            coverPalette = nil
            if let url {
                loader.load(url) { [weak self] image in
                    guard let self, self.coverURL == url, let image else { return }
                    self.cover = image
                    self.coverPalette = DockPalette.from(image: image)
                    self.updatePalette()
                }
            }
        }
        updatePalette()
    }

    private func updatePalette() {
        var target = DockPalette.emerald
        if case .track(let t) = state, t.isPlaying, cover != nil, let p = coverPalette { target = p }
        if target != palette { palette = target }
    }
}
