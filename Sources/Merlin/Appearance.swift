import AppKit
import SwiftUI

/// Light, dark, or whatever the Mac is set to.
enum AppearanceMode: String, CaseIterable {
    case system, light, dark

    var title: String { rawValue.capitalized }
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// Merlin's one accent colour, anywhere on the colour wheel. `nil` is Merlin's own lime. `followsMusic`: electric cyan
/// with no song, the playing song's cover colour with one (the default since 2026-11-26). `exact`: that resolved colour.
struct AccentTheme: Equatable {
    var hue: Double?
    var followsMusic = false
    var exact: NSColor? = nil

    static let lime = AccentTheme(hue: nil)
    /// The default: cyan #00E5FF, or the playing song's cover colour.
    static let music = AccentTheme(hue: nil, followsMusic: true)
    static let cyan = rgb(0x00E5FF)
    /// The lime's own position on the wheel (for the slider).
    static let limeHue = 0.2155
    static let presets: [(name: String, theme: AccentTheme)] = [
        ("Music", .music), ("Lime", .lime), ("Mint", .init(hue: 0.40)), ("Aqua", .init(hue: 0.50)), ("Sky", .init(hue: 0.58)),
        ("Blue", .init(hue: 0.65)), ("Violet", .init(hue: 0.75)), ("Pink", .init(hue: 0.90)),
        ("Coral", .init(hue: 0.015)), ("Amber", .init(hue: 0.11)),
    ]

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
    }

    /// Fills and marks: the send button, the focus line, the live dot.
    var fill: NSColor {
        if let exact { return exact }
        if followsMusic { return Self.cyan }
        guard let hue else { return Self.rgb(0xC6FF3D) }
        return NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1).hsb(hue, 0.76, 1)
    }

    /// Ink on a fill: near-black or white, whichever reads better.
    var onFill: NSColor {
        let f = fill
        let dark = Self.rgb(0x0B0B0C), light = Self.rgb(0xFFFFFF)
        return Self.contrast(f, dark) >= Self.contrast(f, light) ? dark : light
    }

    /// The accent as text or a link on the canvas, nudged until it reads (4.5:1) in that appearance.
    func text(dark: Bool) -> NSColor {
        if !followsMusic && exact == nil && hue == nil { return dark ? Self.rgb(0xC6FF3D) : Self.rgb(0x4A6B00) }
        // A colour (cyan or a cover's): its own hue and saturation, darkened (light) or lightened (dark) until it reads.
        var h: CGFloat = 0, sat: CGFloat = 0, v: CGFloat = 0, al: CGFloat = 0
        (fill.usingColorSpace(.sRGB) ?? fill).getHue(&h, saturation: &sat, brightness: &v, alpha: &al)
        let hue = self.hue ?? Double(h), s = exact != nil || followsMusic ? max(Double(sat), 0) : 0.95
        let canvas = dark ? Theme.canvas.dark : Theme.canvas.light
        var color = fill
        if dark {
            var step = 0.0
            while Self.contrast(color, canvas) < 4.5, step < 1 { step += 0.08; color = fill.mixed(with: .white, by: step) }
        } else {
            var b = 0.7
            color = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1).hsb(hue, s, b)
            while Self.contrast(color, canvas) < 4.5, b > 0.1 { b -= 0.04; color = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1).hsb(hue, s, b) }
        }
        return color
    }

    func wash(dark: Bool) -> NSColor { fill.withAlphaComponent(dark ? 0.10 : 0.28) }

    // MARK: Contrast (WCAG)

    static func luminance(_ c: NSColor) -> Double {
        let s = c.usingColorSpace(.sRGB) ?? c
        func lin(_ v: CGFloat) -> Double { let x = Double(v); return x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(s.redComponent) + 0.7152 * lin(s.greenComponent) + 0.0722 * lin(s.blueComponent)
    }

    static func contrast(_ a: NSColor, _ b: NSColor) -> Double {
        let x = luminance(a), y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
}

private extension NSColor {
    func hsb(_ h: Double, _ s: Double, _ b: Double) -> NSColor {
        NSColor(hue: CGFloat(h), saturation: CGFloat(s), brightness: CGFloat(b), alpha: 1).usingColorSpace(.sRGB) ?? self
    }
    func mixed(with other: NSColor, by t: Double) -> NSColor {
        let a = usingColorSpace(.sRGB) ?? self, b = other.usingColorSpace(.sRGB) ?? other
        let k = CGFloat(t)
        return NSColor(srgbRed: a.redComponent + (b.redComponent - a.redComponent) * k, green: a.greenComponent + (b.greenComponent - a.greenComponent) * k,
                       blue: a.blueComponent + (b.blueComponent - a.blueComponent) * k, alpha: 1)
    }
}

/// Where the mode and accent live. The accent is read while views draw (from any thread), so reads are locked.
final class ThemeStore: ObservableObject {
    static let shared = ThemeStore(defaults: CommandLine.arguments.contains("--unittest")
        ? UserDefaults(suiteName: "merlin.theme.unittest.\(UUID().uuidString)")! : .standard,
        appliesToApp: !CommandLine.arguments.contains("--unittest"))

    /// Bumps when the accent changes, so windows can redraw in the new colour.
    @Published private(set) var revision = 0

    private let defaults: UserDefaults
    private let appliesToApp: Bool
    private let lock = NSLock()
    private var _accent: AccentTheme
    private var _mode: AppearanceMode
    private static let hueKey = "accentHue", modeKey = "appearanceMode"
    /// "music" (the default when unset) or "hue" (the saved `accentHue`, or lime). A saved hue from before 2026-11-26
    /// stays in the defaults but is not used until a colour is picked again in Settings.
    private static let choiceKey = "accentChoice"
    /// The playing song's cover colour (nil: no song, so cyan). Never set in test or picture runs.
    private var _music: NSColor?
    private var pendingMusic = false
    private var resignObserver: NSObjectProtocol?

    init(defaults: UserDefaults, appliesToApp: Bool = true) {
        self.defaults = defaults
        self.appliesToApp = appliesToApp
        if defaults.string(forKey: Self.choiceKey) != "hue" {
            _accent = .music
        } else {
            _accent = defaults.object(forKey: Self.hueKey) == nil ? .lime : AccentTheme(hue: defaults.double(forKey: Self.hueKey))
        }
        _mode = AppearanceMode(rawValue: defaults.string(forKey: Self.modeKey) ?? "") ?? .system
    }

    /// The accent to draw with: the choice, with "music" resolved to cyan or the cover's colour.
    var accent: AccentTheme {
        lock.lock(); defer { lock.unlock() }
        guard _accent.followsMusic else { return _accent }
        return AccentTheme(hue: nil, followsMusic: true, exact: _music)
    }
    /// What Settings shows as picked (".music" while the accent follows the music).
    var choice: AccentTheme { lock.lock(); defer { lock.unlock() }; return _accent }

    /// The cover's colour (nil: no song). The windows redraw at once while Merlin is in the background; while it is in
    /// front the change waits until it is not, so a song change never rebuilds a window you are typing in.
    func setMusicAccent(_ color: NSColor?) {
        guard appliesToApp, !CommandLine.arguments.contains("--uishots") else { return }
        lock.lock()
        let changed = _music != color
        _music = color
        let follows = _accent.followsMusic
        lock.unlock()
        guard changed, follows else { return }
        if NSApplication.shared.isActive {
            guard !pendingMusic else { return }
            pendingMusic = true
            resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                                                    object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.pendingMusic = false
                if let o = self.resignObserver { NotificationCenter.default.removeObserver(o) }
                self.resignObserver = nil
                self.revision += 1
            }
        } else {
            DispatchQueue.main.async { self.revision += 1 }
        }
    }
    var mode: AppearanceMode { lock.lock(); defer { lock.unlock() }; return _mode }

    func setAccent(_ theme: AccentTheme) {
        var theme = theme
        theme.exact = nil
        lock.lock(); _accent = theme; lock.unlock()
        defaults.set(theme.followsMusic ? "music" : "hue", forKey: Self.choiceKey)
        if !theme.followsMusic {
            if let hue = theme.hue { defaults.set(hue, forKey: Self.hueKey) } else { defaults.removeObject(forKey: Self.hueKey) }
        }
        DispatchQueue.main.async { self.revision += 1 }
    }

    func setMode(_ mode: AppearanceMode) {
        lock.lock(); _mode = mode; lock.unlock()
        defaults.set(mode.rawValue, forKey: Self.modeKey)
        applyMode()
        DispatchQueue.main.async { self.revision += 1 }
    }

    /// Light or dark for the whole app (nil follows the Mac).
    func applyMode() {
        guard appliesToApp else { return }
        NSApplication.shared.appearance = mode.nsAppearance
    }
}

/// Wraps a window's root view so it redraws (and re-reads the accent) whenever the accent changes.
struct ThemedRoot<Content: View>: View {
    @ObservedObject private var store = ThemeStore.shared
    private let content: Content
    init(@ViewBuilder _ content: () -> Content) { self.content = content() }
    var body: some View { content.id(store.revision) }
}
