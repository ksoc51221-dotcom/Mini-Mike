import AppKit
import SwiftUI

/// Instrument: near-black and off-white, hairline structure, one electric accent used rarely (design-refs/REDESIGN-3-INSTRUMENT.md).
/// Every colour in the UI comes from here.
///
/// Each token is a light/dark pair, exposed as a dynamic `NSColor` (`.ns`), a SwiftUI `Color` (`.color`) and the two fixed
/// values (`.light`, `.dark`) for surfaces that are always dark (the sidebar).
///
/// Contrast, measured (WCAG relative luminance; solid token surfaces):
///
///   dark (primary)                          on surface #131315   on raised #1B1B1E   on selected #242428
///     ink #F2F2EE                              17.5 (on canvas)
///     inkSecondary #A3A3A8                      7.4
///     inkTertiary #838389                       4.9                  4.6                 4.1 (use inkSecondary there)
///     accentText #C6FF3D                       15.7
///     alert #FF5A4E                             6.0
///     onAccent #0B0B0C on accent #C6FF3D       16.7
///
///   light (exact inversion)                 on surface #FFFFFF   on raised #EDEDE9
///     ink #0B0B0C                              18.2 (on canvas)
///     inkSecondary #52525A                      7.7
///     inkTertiary #6A6A71                       5.0                  4.6                 (not on selected rows)
///     accentText #4A6B00                        6.2
///     alert #C8321F                             5.3
///     accent #C6FF3D is fills/marks only in light.
///
/// Large text and icons need 3:1; every text pair above clears 4.5:1 on its stated surface.
enum Theme {
    struct Token {
        private let lightProvider: () -> NSColor
        private let darkProvider: () -> NSColor
        /// Read when asked (not stored), so the accent can follow Settings → Appearance.
        var light: NSColor { lightProvider() }
        var dark: NSColor { darkProvider() }

        /// Adapts to the appearance it is drawn in. (Built once, so the same token is always the same colour value.)
        let ns: NSColor
        let color: Color

        init(light: NSColor, dark: NSColor) { self.init(light: { light }, dark: { dark }) }

        init(light: @escaping () -> NSColor, dark: @escaping () -> NSColor) {
            lightProvider = light
            darkProvider = dark
            let dynamic = NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark() : light()
            }
            ns = dynamic
            color = Color(nsColor: dynamic)
        }
        func resolved(dark isDark: Bool) -> NSColor { isDark ? dark : light }
    }

    private static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: alpha)
    }
    private static func token(_ light: UInt32, _ dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Token {
        Token(light: rgb(light, lightAlpha), dark: rgb(dark, darkAlpha))
    }

    // Surfaces
    /// Panel tint over the blur.
    static let surfaceTint = token(0xF6F6F3, 0x0B0B0C, lightAlpha: 0.80, darkAlpha: 0.82)
    /// Solid canvas: for windows that are not frosted (the library).
    static let canvas = token(0xF6F6F3, 0x0B0B0C)
    /// Sidebars, cards.
    static let surface = token(0xFFFFFF, 0x131315)
    /// Input field, hover.
    static let surfaceRaised = token(0xEDEDE9, 0x1B1B1E)
    /// A selected row (inkTertiary falls to 4.1 on it: use inkSecondary for meta).
    static let surfaceSelected = token(0xE3E3DE, 0x242428)
    /// Dividers.
    static let hairline = Token(light: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.09), dark: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.08))
    /// Focused / active borders, grid ticks.
    static let hairlineStrong = Token(light: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.18), dark: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.16))

    // Text
    static let ink = token(0x0B0B0C, 0xF2F2EE)
    static let inkSecondary = token(0x52525A, 0xA3A3A8)
    static let inkTertiary = token(0x6A6A71, 0x838389)

    // The accent: used rarely (focus ring, the live indicator, one primary button). Fills/marks only in light.
    // All four follow the colour chosen in Settings → Appearance (lime unless changed).
    static let accent = Token(light: { ThemeStore.shared.accent.fill }, dark: { ThemeStore.shared.accent.fill })
    static let onAccent = Token(light: { ThemeStore.shared.accent.onFill }, dark: { ThemeStore.shared.accent.onFill })
    /// Accent as text / links.
    static let accentText = Token(light: { ThemeStore.shared.accent.text(dark: false) }, dark: { ThemeStore.shared.accent.text(dark: true) })
    /// Drop targets, focus glow only.
    static let accentWash = Token(light: { ThemeStore.shared.accent.wash(dark: false) }, dark: { ThemeStore.shared.accent.wash(dark: true) })

    // Status
    static let done = accentText
    static let alert = token(0xC8321F, 0xFF5A4E)

    // Compatibility aliases (Marginalia names, repointed). The restyle passes delete their call sites; the integrator removes these.
    static let highlighter = accent
    static let onHighlighter = onAccent
    static let sky = ink
    static let teal = ink
    static let sectorHues: [Token] = Array(repeating: ink, count: 8)
    static let sectorHueNames = ["Highlighter", "Sage", "Sky", "Plum", "Clay", "Teal", "Rose", "Slate"]

    /// The only three corner radii: chips and tags 6, controls (buttons, fields, rows) 10, containers (panels, cards) 16.
    /// Borders are 1 px in `hairline`.
    enum Radius {
        static let chip: CGFloat = 6
        static let control: CGFloat = 10
        static let container: CGFloat = 16
    }

    /// A count as text: no zero padding, nothing at 0 (so a section with nothing in it shows no number).
    static func count(_ n: Int) -> String? { n > 0 ? String(n) : nil }

    /// Stretchable rounded-rect mask for NSVisualEffectView (clips the blur, not just the content).
    static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// The type scale (Geist + Geist Mono, see Fonts.swift). Prose is Geist, numbers / times / counts are Geist Mono.
/// Tracking and case can't live in a `Font`: use `.mMetaStyle()`, `.mLabelStyle()`, `.mHeadingStyle()`, `.mDisplayStyle()`.
extension Font {
    /// Geist Mono 10.5 (+0.4): times, counts, kbd hints, footers. 14pt lines.
    static var mMeta: Font { .geistMono(10.5) }
    /// Geist 12 semibold, sentence case: section labels, meta lines, chips. (Mono is only for times, durations, code.)
    static var mLabel: Font { .geist(12, .semibold) }
    /// Geist 12 medium: form labels.
    static var mFieldLabel: Font { .geist(12, .medium) }
    /// Geist 13: UI text, rows. 18pt lines.
    static var mUI: Font { .geist(13) }
    /// Geist 14: answers. 22pt lines.
    static var mBody: Font { .geist(14) }
    /// Geist 18 semibold (-0.2): titles. 24pt lines.
    static var mHeading: Font { .geist(18, .semibold) }
    /// Geist 28 semibold (-0.6): Desk greeting, page titles. 32pt lines.
    static var mDisplay: Font { .geist(28, .semibold) }
    /// Geist Italic 14: the selected passage. 22pt lines.
    static var mQuote: Font { .geistItalic(14) }
    /// Geist Mono 13: code. 20pt lines.
    static var mCode: Font { .geistMono(13) }
    /// Geist Mono 12, monospaced digits: numbers that change.
    static var mNum: Font { .geistMono(12).monospacedDigit() }
}

extension View {
    func mMetaStyle() -> some View { font(.mMeta).tracking(0.4) }
    /// Sentence-case section label: Geist 12/600 in inkSecondary.
    func mLabelStyle() -> some View { font(.mLabel).foregroundStyle(Theme.inkSecondary.color) }
    /// Form label: Geist 12/500 in inkSecondary.
    func mFieldLabelStyle() -> some View { font(.mFieldLabel).foregroundStyle(Theme.inkSecondary.color) }
    func mHeadingStyle() -> some View { font(.mHeading).tracking(-0.2) }
    func mDisplayStyle() -> some View { font(.mDisplay).tracking(-0.6) }
}

extension NSFont {
    /// The same scale for AppKit views: Geist (SF if the fonts did not register).
    static func margin(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        MarginFonts.nsFont(.sans, size, weight) ?? .systemFont(ofSize: size, weight: weight)
    }
}

// MARK: - Offscreen drawing helpers

extension NSView {
    /// The view drawn into a bitmap, without it appearing on screen.
    func snapshotRep() -> NSBitmapImageRep? {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: rep)
        return rep
    }

    /// Lays the view out and spins the run loop `passes` times, so state-driven layout settles before a snapshot.
    func settleLayout(passes: Int, interval: TimeInterval) {
        for _ in 0..<passes {
            layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(interval))
        }
    }
}

extension NSVisualEffectView {
    /// The frosted popover material behind a floating window's content, clipped to rounded corners.
    static func popoverBackdrop(radius: CGFloat) -> NSVisualEffectView {
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.maskImage = Theme.roundedMask(radius: radius)
        return effect
    }
}

extension NSBitmapImageRep {
    /// An empty 8-bit RGBA bitmap in device RGB, to draw into.
    static func rgba(pixelsWide: Int, pixelsHigh: Int) -> NSBitmapImageRep? {
        NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    }
}

/// A view that reacts to the click that brings its (non-key) window forward, so floating panels need no focus click first.
class FirstMouseView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
