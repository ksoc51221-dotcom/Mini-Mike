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

/// Margin's one accent colour, anywhere on the colour wheel. `nil` is Margin's own lime.
struct AccentTheme: Equatable {
    var hue: Double?

    static let lime = AccentTheme(hue: nil)
    /// The lime's own position on the wheel (for the slider).
    static let limeHue = 0.2155
    static let presets: [(name: String, theme: AccentTheme)] = [
        ("Lime", .lime), ("Mint", .init(hue: 0.40)), ("Aqua", .init(hue: 0.50)), ("Sky", .init(hue: 0.58)),
        ("Blue", .init(hue: 0.65)), ("Violet", .init(hue: 0.75)), ("Pink", .init(hue: 0.90)),
        ("Coral", .init(hue: 0.015)), ("Amber", .init(hue: 0.11)),
    ]

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
    }

    /// Fills and marks: the send button, the focus line, the live dot.
    var fill: NSColor {
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
        guard let hue else { return dark ? Self.rgb(0xC6FF3D) : Self.rgb(0x4A6B00) }
        let canvas = dark ? Theme.canvas.dark : Theme.canvas.light
        var color = fill
        if dark {
            var step = 0.0
            while Self.contrast(color, canvas) < 4.5, step < 1 { step += 0.08; color = fill.mixed(with: .white, by: step) }
        } else {
            var b = 0.7
            color = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1).hsb(hue, 0.95, b)
            while Self.contrast(color, canvas) < 4.5, b > 0.1 { b -= 0.04; color = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1).hsb(hue, 0.95, b) }
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
        ? UserDefaults(suiteName: "margin.theme.unittest.\(UUID().uuidString)")! : .standard,
        appliesToApp: !CommandLine.arguments.contains("--unittest"))

    /// Bumps when the accent changes, so windows can redraw in the new colour.
    @Published private(set) var revision = 0

    private let defaults: UserDefaults
    private let appliesToApp: Bool
    private let lock = NSLock()
    private var _accent: AccentTheme
    private var _mode: AppearanceMode
    private static let hueKey = "accentHue", modeKey = "appearanceMode"

    init(defaults: UserDefaults, appliesToApp: Bool = true) {
        self.defaults = defaults
        self.appliesToApp = appliesToApp
        _accent = defaults.object(forKey: Self.hueKey) == nil ? .lime : AccentTheme(hue: defaults.double(forKey: Self.hueKey))
        _mode = AppearanceMode(rawValue: defaults.string(forKey: Self.modeKey) ?? "") ?? .system
    }

    var accent: AccentTheme { lock.lock(); defer { lock.unlock() }; return _accent }
    var mode: AppearanceMode { lock.lock(); defer { lock.unlock() }; return _mode }

    func setAccent(_ theme: AccentTheme) {
        lock.lock(); _accent = theme; lock.unlock()
        if let hue = theme.hue { defaults.set(hue, forKey: Self.hueKey) } else { defaults.removeObject(forKey: Self.hueKey) }
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
