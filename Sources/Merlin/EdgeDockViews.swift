import AppKit
import SwiftUI

// The edge panel's dock: a clear glass half-disc at the screen edge, a thin halo ring outside it with the round items on it
// (Chats, Notes, the pinned apps), the Spotify cover inside the disc and a small "+". Its colours come from
// `SpotifyService.palette` (emerald, or the playing song's cover). The cards beside it keep the normal Merlin look.

extension DockPalette {
    var baseColor: Color { Color(nsColor: base) }
    var rimColor: Color { Color(nsColor: rim) }
    var accentColor: Color { Color(nsColor: accent) }
    var accent2Color: Color { Color(nsColor: accent2) }
    var inkColor: Color { Color(nsColor: ink) }
    var baseLightColor: Color { Color(nsColor: baseLight) }
    var baseDarkColor: Color { Color(nsColor: baseDark) }
    var rimTintColor: Color { Color(nsColor: rimTint) }
    /// Text on an accent fill (play-pause, Done, Add).
    var onAccentColor: Color { Color(nsColor: onAccent) }

    // The neutral white lines and fills of the glass, as the palette's own light (the rim tint), so no surface keeps a fixed colour.
    /// Dividers and quiet hairlines.
    var hairlineColor: Color { rimTintColor.opacity(0.14) }
    /// A card's or button's outline.
    var edgeLineColor: Color { rimTintColor.opacity(0.30) }
    /// A row or well at rest, under the pointer, and selected.
    var restFill: Color { rimTintColor.opacity(0.07) }
    var hoverFill: Color { rimTintColor.opacity(0.13) }
    var selectedFill: Color { rimTintColor.opacity(0.20) }
}

private struct EdgePaletteKey: EnvironmentKey { static let defaultValue = DockPalette.standard }

extension EnvironmentValues {
    /// The dock's current palette, for the card rows that don't take it as a parameter.
    var edgePalette: DockPalette {
        get { self[EdgePaletteKey.self] }
        set { self[EdgePaletteKey.self] = newValue }
    }
}

/// Where the dock's drawn parts sit (dock coordinates, y down), beyond `EdgePanelLayout`'s numbers.
enum EdgeDockArt {
    /// The frame the three beat strings are drawn in, around the record (their band is `BeatStrings.Place.disc`, clear of
    /// the disc buttons' column, 14 pt in from the rim).
    static let orbRadius: CGFloat = 120
    /// The ring line's width (2026-11-26: more prominent than the 1 pt hairline).
    static let ringLineWidth: CGFloat = 3
    /// The black under the mini player's record title (on the cover art), so the ink keeps 4.5:1 on a white cover.
    static let titleBand: CGFloat = 0.66
    /// CSS 155°: from the top (a little left) to the bottom (a little right).
    static let from155 = UnitPoint(x: 0.29, y: 0.05)
    static let to155 = UnitPoint(x: 0.71, y: 0.95)
    /// The safety switch for the real Liquid Glass: false draws the flat path everywhere (no `glassEffect`, no
    /// `GlassEffectContainer`). Launch with `MERLIN_EDGE_NO_GLASS=1` to force it off without a rebuild.
    nonisolated(unsafe) static var glassEnabled = ProcessInfo.processInfo.environment["MERLIN_EDGE_NO_GLASS"] == nil
    /// The one `GlassEffectContainer` around the disc, the items and the card (near glass shapes blend). Launch with
    /// `MERLIN_EDGE_NO_GLASS_CONTAINER=1` to draw each glass surface on its own, for a real-screen comparison.
    nonisolated(unsafe) static var glassContainer = ProcessInfo.processInfo.environment["MERLIN_EDGE_NO_GLASS_CONTAINER"] == nil
    /// Blur behind the glass only when it can be drawn and the user wants it.
    static var flat: Bool {
        !glassEnabled || Motion.still || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }
    /// Which of the three glass looks the dock draws (the user picks from real-screen pictures). Read once at launch from
    /// `MERLIN_EDGE_GLASS=clear|tinted|regular|lens`; `lens` when unset. The capture tool changes it in code.
    nonisolated(unsafe) static var glassStyle = EdgeGlassStyle.from(ProcessInfo.processInfo.environment["MERLIN_EDGE_GLASS"])
}

/// The three glass looks behind one switch (`EdgeDockArt.glassStyle`). `regular`: `Glass.regular` with a faint palette
/// tint (the look until now). `clear`: `Glass.clear`, no tint, a 1 pt rim with a faint rainbow fringe at the top and
/// bottom, a soft darker band inside the left edge, no glow, white text on soft local scrims. `clearTinted`: the same
/// with a faint palette tint in the glass. `lens`: Merlin's own refractive glass (`EdgeLensView.swift`): the backdrop
/// stays sharp and bends at the edge; falls back to `clearTinted` when it cannot run (`EdgeLensPolicy`).
enum EdgeGlassStyle: String, CaseIterable, Equatable {
    case regular, clearTinted, clear, lens

    /// `clear`, `tinted` (or `cleartinted`), `lens`, `regular`; anything else: `regular`.
    static func from(_ value: String?) -> EdgeGlassStyle {
        switch value?.lowercased() {
        case "clear": return .clear
        case "tinted", "cleartinted", "clear-tinted": return .clearTinted
        case "regular": return .regular
        default: return .lens // the user's choice (2026-11-26); it falls back to clearTinted when it cannot run
        }
    }

    var isClear: Bool { self != .regular }
    /// The sheet's label: A, B, C, D.
    var letter: String {
        switch self {
        case .regular: return "A"
        case .clearTinted: return "B"
        case .clear: return "C"
        case .lens: return "D"
        }
    }
}

/// The lens only through `EdgePanelView` (which gates it on `EdgeLensCapture.live`): a dock view hosted anywhere else
/// gets its fallback.
private struct EdgeGlassStyleKey: EnvironmentKey {
    static let defaultValue = EdgeDockArt.glassStyle == .lens ? .clearTinted : EdgeDockArt.glassStyle
}

extension EnvironmentValues {
    var edgeGlassStyle: EdgeGlassStyle {
        get { self[EdgeGlassStyleKey.self] }
        set { self[EdgeGlassStyleKey.self] = newValue }
    }
}

// MARK: - Glass parts

/// The glass recipe: clear, see-through macOS 26 Liquid Glass (`Glass.regular`, which per Apple's guidance switches its
/// content between light and dark with what is behind it; `Glass.clear` is meant for media and wants a dim layer. Not
/// yet confirmed on a real screen; the variant is one line in `glass(_:)`), with only a hint
/// of the palette's colour through `Glass.tint`. No dim and no drawn base: text and glyphs on the glass use the
/// hierarchical styles (`.primary`, `.secondary`, `.tertiary`), so the system picks their colour. Their contrast is the
/// system's job and can only be checked on a real screen (`--edgeglasscheck`). Only the flat path draws a solid surface.
enum EdgeGlass {
    /// The palette hint on every glass surface (the saturated rim colour at this opacity, never a panel).
    static let tint: CGFloat = 0.14

    /// The palette hint in the `clearTinted` glass (fainter than `tint`).
    static let clearTint: CGFloat = 0.07
    /// The dim under text and small glyphs on the clear styles (soft-edged, only behind them).
    static let scrim: CGFloat = 0.32
    /// The lens's text shadow (no box): black at `near` with radius 1 and at `far` with radius 4, no offset, following
    /// the glyphs, over the body's dim (`EdgeLensProfile.bodyDim` / `controlDim`).
    static let lensGlyphShadow = (near: 0.55, far: 0.35)

    /// The glass of every surface: the disc, Chats and Notes, and the cards.
    static func glass(_ palette: DockPalette, style: EdgeGlassStyle = .regular) -> Glass {
        switch style {
        case .regular: return .regular.tint(palette.rimColor.opacity(tint))
        case .clearTinted: return .clear.tint(palette.rimColor.opacity(clearTint))
        case .clear, .lens: return .clear // the lens draws no system glass (`EdgeGlassSurface`)
        }
    }

    /// `top` at `alpha` over `back`, in sRGB components.
    static func over(_ top: NSColor, _ alpha: CGFloat, _ back: NSColor) -> NSColor {
        let b = back.usingColorSpace(.sRGB) ?? back, t = top.usingColorSpace(.sRGB) ?? top
        func mix(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x * (1 - alpha) + y * alpha }
        return NSColor(srgbRed: mix(b.redComponent, t.redComponent), green: mix(b.greenComponent, t.greenComponent),
                       blue: mix(b.blueComponent, t.blueComponent), alpha: 1)
    }

    /// The tint of Chats' and Notes' glyph wells at their strongest (pointer on); 0.15 at rest.
    static let wellTint: CGFloat = 0.18
}

extension View {
    /// The glass under this view's OWN content: clear Liquid Glass (`glassEffect(EdgeGlass.glass(_:))`; pass built-in
    /// shapes only, see `EdgeDockDisc`), or the flat colour in the pictures, under `Motion.still` and Reduce
    /// Transparency. Everything drawn on a glass surface must be inside the view this modifies: the glass draws its
    /// material behind that content, while a glass view placed as a sibling or a `.background` is lifted above
    /// non-glass content and hides it (the dark-blob fault the real-screen pictures showed).
    /// `lens`: on the lens, the surface that picks its own ink from its backdrop (`EdgeLensInk`).
    func edgeGlass<S: InsettableShape>(_ shape: S, palette: DockPalette, flat: Color, lens: EdgeLensRegion? = nil) -> some View {
        modifier(EdgeGlassSurface(shape: shape, palette: palette, flat: flat, region: lens))
    }

    /// The clear styles' soft dim behind a text block or a small glyph (its own shape, blurred at the edge); nothing on
    /// `regular` and on the flat path.
    /// `lensOnly`: a scrim on the lens only (text that has none in the other styles).
    func edgeScrim(_ padding: CGFloat = 3, lensOnly: Bool = false) -> some View {
        modifier(EdgeScrim(padding: padding, lensOnly: lensOnly))
    }

    /// A search field's well. On the glass: a light palette tint and an inner light over the surface's own clear glass
    /// (no glass on glass, which would also lift the field above its text). Flat: the dark capsule and its shadow.
    @ViewBuilder func edgeFieldWell(_ p: DockPalette, shadow: Bool = true) -> some View {
        if EdgeDockArt.flat {
            background(Capsule().fill(p.baseDarkColor.opacity(0.85)))
                .background(Capsule().fill(p.rimTintColor.opacity(0.10)))
                .overlay(Capsule().edgeInnerLight(p.rimTintColor.opacity(0.3), x: 0, y: 1, blur: 1))
                .shadow(color: .black.opacity(shadow ? 0.35 : 0), radius: 5, x: 0, y: 3)
        } else {
            background(Capsule().fill(p.rimTintColor.opacity(0.12)))
                .overlay(Capsule().edgeInnerLight(p.rimTintColor.opacity(0.3), x: 0, y: 1, blur: 1))
                .edgeLensOnly(Capsule()) // the lens: the field is its own small lens
        }
    }

    /// The dark scheme on the flat path only (a solid dark surface with light text). On the glass path the scheme is left
    /// alone, so the glass and the hierarchical styles pick light or dark content.
    func edgeFlatScheme() -> some View { modifier(EdgeFlatScheme()) }
}

private struct EdgeFlatScheme: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.edgeGlassStyle) private var style
    @Environment(\.edgeLensInked) private var inked
    func body(content: Content) -> some View {
        // The clear styles: white text (on its local scrim), so the dark scheme too. Inside a lens surface the scheme
        // is its ink's (`EdgeLensGlass`).
        content.environment(\.colorScheme, inked && !EdgeDockArt.flat ? scheme : (EdgeDockArt.flat || style.isClear ? .dark : scheme))
    }
}

/// One glass surface (see `edgeGlass`): the flat colour, or the style's glass with the content drawn on it. The clear
/// styles add their rim (white at low opacity, a faint blue-to-pink fringe at the top and bottom) and a soft darker band
/// inside the left edge, both as the glass view's own content.
private struct EdgeGlassSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    let palette: DockPalette
    let flat: Color
    var region: EdgeLensRegion?
    @Environment(\.edgeGlassStyle) private var style

    func body(content: Content) -> some View {
        if EdgeDockArt.flat {
            content.background(shape.fill(flat).allowsHitTesting(false))
        } else if style == .lens {
            // Merlin's own lens (no system glass, no SwiftUI rim or band: the shader draws both).
            content.modifier(EdgeLensGlass(shape: shape, region: region))
        } else if style.isClear {
            content
                .background(band.allowsHitTesting(false))
                .overlay(rim.allowsHitTesting(false))
                .glassEffect(EdgeGlass.glass(palette, style: style), in: shape)
                .glassEffectTransition(.identity)
        } else {
            content
                .glassEffect(EdgeGlass.glass(palette, style: style), in: shape)
                .glassEffectTransition(.identity) // no system glass motion: the existing `Motion.edge*` fades only
        }
    }

    /// Angular stops (0 = right, 0.25 = bottom, 0.5 = left, 0.75 = top): white at low opacity, the fringe at the top
    /// and bottom.
    private var rim: some View {
        let w = Color.white
        let blue = Color(red: 0.45, green: 0.7, blue: 1), pink = Color(red: 1, green: 0.55, blue: 0.85)
        return shape.strokeBorder(AngularGradient(stops: [
            .init(color: w.opacity(0.22), location: 0),
            .init(color: blue.opacity(0.45), location: 0.2),
            .init(color: w.opacity(0.5), location: 0.25),
            .init(color: pink.opacity(0.45), location: 0.3),
            .init(color: w.opacity(0.22), location: 0.5),
            .init(color: blue.opacity(0.45), location: 0.7),
            .init(color: w.opacity(0.55), location: 0.75),
            .init(color: pink.opacity(0.45), location: 0.8),
            .init(color: w.opacity(0.22), location: 1),
        ], center: .center), lineWidth: 1)
    }

    /// A soft darker band just inside the left edge (fades out by a third of the width).
    private var band: some View {
        shape.stroke(Color.black.opacity(0.22), lineWidth: 14)
            .offset(x: 6)
            .blur(radius: 5)
            .mask(shape)
            .mask(LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: UnitPoint(x: 0.35, y: 0.5)))
    }
}

private struct EdgeScrim: ViewModifier {
    let padding: CGFloat
    var lensOnly = false
    @Environment(\.edgeGlassStyle) private var style
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        if style == .lens && !EdgeDockArt.flat {
            // No box: a tight soft shadow that follows the glyphs (two stacked, no offset), over the lens body's dim.
            // Padding 0 (the accent-filled play button): none.
            // Dark ink (the light scheme, `EdgeLensGlass`): the same two as a soft white halo.
            if padding > 0 {
                let c: Color = scheme == .light ? .white : .black
                content
                    .shadow(color: c.opacity(EdgeGlass.lensGlyphShadow.near), radius: 1)
                    .shadow(color: c.opacity(EdgeGlass.lensGlyphShadow.far), radius: 4)
            } else {
                content
            }
        } else if style.isClear && !EdgeDockArt.flat && !lensOnly {
            content.background(
                Capsule().fill(Color.black.opacity(EdgeGlass.scrim))
                    .padding(-padding)
                    .blur(radius: padding + 1)
                    .allowsHitTesting(false)
            )
        } else {
            content
        }
    }
}

/// A shadow only outside the shape (a filled shape behind would make the glass opaque).
struct EdgeOuterShadow<S: Shape>: View {
    let shape: S
    let color: Color
    let radius: CGFloat
    var x: CGFloat = 0
    var y: CGFloat = 0

    var body: some View {
        ZStack {
            shape.fill(Color.black).shadow(color: color, radius: radius, x: x, y: y)
            shape.fill(Color.black).blendMode(.destinationOut)
        }
        .compositingGroup()
        .allowsHitTesting(false)
    }
}

extension Shape {
    /// An inset light (CSS `inset x y blur`): the edge stroked, moved by (x, y), softened and kept inside the shape.
    func edgeInnerLight(_ color: Color, x: CGFloat, y: CGFloat, blur: CGFloat, width: CGFloat = 2) -> some View {
        stroke(color, lineWidth: width)
            .offset(x: x, y: y)
            .blur(radius: blur / 2)
            .mask(self)
            .allowsHitTesting(false)
    }
}

/// The cards' chrome: clear glass (flat: a dark surface with a 155° sheen), a palette hairline, a lit top edge and a deep
/// soft shadow.
private struct EdgeCardChrome: ViewModifier {
    let palette: DockPalette
    let radius: CGFloat
    @Environment(\.edgeGlassStyle) private var style

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        // Mock: y 24, blur 56. Clamped to radius 22, 16 pt down so it stays inside `EdgePanelLayout.slack`.
        let shadow = EdgeOuterShadow(shape: shape, color: .black.opacity(0.65), radius: 22, y: 16)
        if EdgeDockArt.flat {
            content
                .background(
                    ZStack {
                        shape.fill(palette.baseDarkColor)
                        // The painted sheen belongs to the flat surface; the real glass brings its own light.
                        shape.fill(LinearGradient(stops: [
                            .init(color: palette.rimTintColor.opacity(0.10), location: 0),
                            .init(color: palette.rimTintColor.opacity(0.02), location: 0.4),
                            .init(color: .black.opacity(0.35), location: 1),
                        ], startPoint: EdgeDockArt.from155, endPoint: EdgeDockArt.to155))
                    }
                    .allowsHitTesting(false)
                )
                .clipShape(shape)
                .overlay(lights(shape))
                .background(shadow)
        } else if style.isClear {
            // Clear: the style's own rim and band (in `edgeGlass`), no palette hairline and no shadow or glow.
            content
                .clipShape(shape)
                .edgeGlass(shape, palette: palette, flat: palette.baseDarkColor, lens: .card)
        } else {
            // The rows, the inner light and the hairline are the glass view's own content, so all draw above the material.
            content
                .clipShape(shape)
                .overlay(lights(shape))
                .edgeGlass(shape, palette: palette, flat: palette.baseDarkColor)
                .background(shadow)
        }
    }

    private func lights(_ shape: RoundedRectangle) -> some View {
        ZStack {
            shape.edgeInnerLight(palette.rimTintColor.opacity(0.32), x: 0, y: 1, blur: 0)
            shape.strokeBorder(palette.rimTintColor.opacity(0.22), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

extension View {
    func edgeCardChrome(_ palette: DockPalette, radius: CGFloat) -> some View {
        modifier(EdgeCardChrome(palette: palette, radius: radius))
    }
}

/// Stage one: the dock. Every position comes from `EdgePanelLayout`, so the tests check what is drawn.
struct EdgeDockView: View {
    @ObservedObject var model: EdgePanelModel
    @State private var hovered: String?

    var body: some View {
        let s = EdgePanelLayout.dockSize
        let p = model.palette
        let items = model.ringItems
        let centres = EdgePanelLayout.itemCentres(count: items.count)
        let calm = Motion.still || Motion.reduceMotion
        ZStack(alignment: .topLeading) {
            EdgeHalo(palette: p, moving: model.shown && !calm)
                .frame(width: s.width, height: s.height)
            EdgeDockDisc(model: model)
                .frame(width: s.width, height: s.height)
            // "+", search and collapse straddle the disc's rim, so each is its own small glass surface (outside the
            // disc's glass circle), like the ring items.
            if !model.searchOpen {
                EdgeDiscButtons(model: model)
                    .frame(width: s.width, height: s.height)
                    .transition(.opacity)
            }
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                EdgeRingItem(model: model, item: item, index: i) { h in
                    if h { hovered = item.id } else if hovered == item.id { hovered = nil }
                }
                .position(x: centres[i].x, y: centres[i].y)
                .zIndex(hovered == item.id ? 1 : 0) // its name label over the neighbours
                // Search: the other items fade out (and back) from 0.95; the match slides to the ring's middle.
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .animation(calm ? nil : Motion.edgeIn, value: items.map(\.id))
        .frame(width: s.width, height: s.height)
        // Flat path: dark in light and dark mode alike. Glass path: the system picks light or dark content.
        .edgeFlatScheme()
        .environment(\.edgePalette, p)
        .animation(Motion.edgePaletteAnimation, value: p)
    }
}

/// The ring the items sit on: a row of tiny accent dots, each on a soft dark casing (so it reads on a white page too),
/// on the SAME circle as the items' centres (`EdgePanelLayout.ringCentre`), out to the screen edge. While the dock shows
/// (and motion is allowed) the dots drift slowly along the orbit, and a soft bright "comet" sweeps down the arc
/// (motion.dev "Motion along a path", animate-ui "Shine"). Still: even dots, a whole number round the circle, one on the
/// centre line.
private struct EdgeHalo: View {
    let palette: DockPalette
    var moving = false

    /// Dots round the whole circle (even, so one sits on the centre line on each side): about 9 pt apart.
    static let dots = 152
    /// The dot and its casing.
    static let dot: CGFloat = 3.2
    static let casing: CGFloat = 1.4
    /// One dot spacing every this many seconds (the drift); the comet's trip down the visible arc.
    static let driftPeriod = 1.6
    static let cometPeriod = 5.5

    var body: some View {
        if moving {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in
                dots(time: ctx.date.timeIntervalSinceReferenceDate)
            }
            .allowsHitTesting(false)
        } else {
            dots(time: nil).allowsHitTesting(false)
        }
    }

    private func dots(time: Double?) -> some View {
        let accent = palette.accentColor
        return Canvas { gc, size in
            let c = EdgePanelLayout.ringCentre, r = EdgePanelLayout.ringLineRadius
            let step = 2 * Double.pi / Double(Self.dots)
            let drift = time.map { ($0 / Self.driftPeriod).truncatingRemainder(dividingBy: 1) * step } ?? 0
            // The visible arc runs from the top of the frame to the bottom: angles (from the left axis) within ±span.
            let span = asin(min(1, Double(size.height / 2) / Double(r)))
            let comet: Double? = time.map {
                let f = ($0 / Self.cometPeriod).truncatingRemainder(dividingBy: 1)
                return -span * 1.3 + f * span * 2.6 // enters above the top, leaves below the bottom
            }
            for i in 0..<Self.dots {
                // Angle 0 is the leftmost point of the circle (on the centre line); positive goes down.
                var a = Double(i) * step + drift
                if a > .pi { a -= 2 * .pi }
                guard abs(a) <= span + step else { continue }
                let p = CGPoint(x: c.x - r * CGFloat(cos(a)), y: c.y + r * CGFloat(sin(a)))
                guard p.x < size.width + Self.dot else { continue }
                var glow = 0.0
                if let comet { let d = (a - comet) / 0.11; glow = exp(-d * d) }
                let d = Self.dot * CGFloat(1 + 0.6 * glow)
                let back = CGRect(x: p.x - d / 2 - Self.casing / 2, y: p.y - d / 2 - Self.casing / 2,
                                  width: d + Self.casing, height: d + Self.casing)
                gc.fill(Path(ellipseIn: back), with: .color(.black.opacity(0.18)))
                gc.fill(Path(ellipseIn: CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d)),
                        with: .color(accent.opacity(0.7 + 0.3 * glow)))
                if glow > 0.05 {
                    let g = d * 2.6
                    gc.fill(Path(ellipseIn: CGRect(x: p.x - g / 2, y: p.y - g / 2, width: g, height: g)),
                            with: .color(accent.opacity(0.22 * glow)))
                }
            }
        }
    }
}

/// What lies under the disc's content (drawn in a frame one radius wide, two high): its shadow and, on the flat path, the
/// painted disc and its lines. On the glass path the shadow only: the glass and the lines are part of the content view.
private struct EdgeDiscGlass: View {
    let palette: DockPalette
    @Environment(\.edgeGlassStyle) private var style

    var body: some View {
        let p = palette
        let disc = EdgeHalfDisc()
        let track = EdgeHalfDisc(radius: EdgePanelLayout.discRadius * 0.89)
        ZStack {
            // One soft ambient shadow below the disc (outside the disc only, so it never covers the glass); none on the
            // clear styles (no glow, as the cards).
            if EdgeDockArt.flat || !style.isClear {
                EdgeOuterShadow(shape: disc, color: .black.opacity(0.3), radius: 16, y: 6)
            }
            if EdgeDockArt.flat {
                disc.fill(p.baseColor)
                // The flat stand-in keeps its painted depth (the real glass brings its own).
                disc.fill(LinearGradient(stops: [
                    .init(color: p.baseLightColor.opacity(0.62), location: 0),
                    .init(color: p.baseColor.opacity(0.72), location: 0.55),
                    .init(color: p.accentColor.opacity(0.22), location: 1),
                ], startPoint: EdgeDockArt.from155, endPoint: EdgeDockArt.to155))
                track.fill(p.baseLightColor.opacity(0.3))
                EdgeDiscLines(palette: p)
            }
        }
        .allowsHitTesting(false)
    }
}

/// The inner track's hairline and the 1 pt inner rim light (in a frame one radius wide, two high).
private struct EdgeDiscLines: View {
    let palette: DockPalette

    var body: some View {
        ZStack {
            EdgeHalfDisc(radius: EdgePanelLayout.discRadius * 0.89).stroke(palette.rimTintColor.opacity(0.2), lineWidth: 1)
            EdgeHalfDisc(radius: EdgePanelLayout.discRadius - 0.5).stroke(palette.rimTintColor.opacity(0.35), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

/// The glass half-disc with the record (or the Spotify glyph), "+" and collapse.
private struct EdgeDockDisc: View {
    @ObservedObject var model: EdgePanelModel
    @ObservedObject private var timers = TimerStore.shared

    var body: some View {
        let p = model.palette
        let r = EdgePanelLayout.discRadius
        let s = EdgePanelLayout.dockSize
        ZStack(alignment: .topLeading) {
            EdgeDiscGlass(palette: p)
                .frame(width: r, height: r * 2)
                .position(x: s.width - r / 2, y: s.height / 2)
            if EdgeDockArt.flat {
                content(p)
            } else {
                // The content IS the glass view, so the material draws behind it. Glass takes built-in shapes only (a
                // custom path shape is the likely trigger of the SwiftUI SDF crash): a full circle centred on the flat
                // edge, whose right half lies outside the window (the screen edge). The content keeps its dock
                // coordinates: it is moved so the dock point (s.width, s.height / 2) is the circle's centre.
                ZStack(alignment: .topLeading) {
                    EdgeDiscLines(palette: p)
                        .frame(width: r, height: r * 2)
                        .position(x: s.width - r / 2, y: s.height / 2)
                    content(p)
                }
                .frame(width: s.width, height: s.height, alignment: .topLeading)
                .offset(x: r - s.width, y: r - s.height / 2)
                .frame(width: r * 2, height: r * 2, alignment: .topLeading)
                .edgeGlass(Circle(), palette: p, flat: p.baseColor, lens: .disc)
                .position(x: s.width, y: s.height / 2)
            }
        }
    }

    /// The record (or the Spotify glyph) and the button column, or the search field.
    @ViewBuilder private func content(_ p: DockPalette) -> some View {
        let r = EdgePanelLayout.discRadius
        ZStack(alignment: .topLeading) {
            if !model.searchOpen {
                ZStack(alignment: .topLeading) {
                    music(p)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipShape(EdgeHalfDisc(radius: r)) // the record's right half is behind the screen edge
                .transition(fade)
            } else {
                search(p).transition(fade)
            }
            EdgeTimerChip(timers: TimerStore.shared, palette: p)
                .position(x: EdgePanelLayout.timerChipCentre.x, y: EdgePanelLayout.timerChipCentre.y)
        }
    }

    /// Fades with a scale from 0.95 at most (none under Reduce Motion).
    private var fade: AnyTransition {
        Motion.reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.95))
    }

    /// The search field in the search button's row, and "No app" under it when nothing matches.
    @ViewBuilder private func search(_ p: DockPalette) -> some View {
        let f = EdgePanelLayout.searchFieldFrame
        EdgeSearchField(model: model, palette: p)
            .frame(width: f.width, height: f.height)
            .position(x: f.midX, y: f.midY)
        if model.isFiltering && model.searchMatch == nil {
            Text("No app")
                .font(.geist(11, .medium))
                .foregroundStyle(.primary) // on the glass: the system picks light or dark
                .edgeScrim(3)
                .position(x: EdgePanelLayout.noMatchCentre.x, y: EdgePanelLayout.noMatchCentre.y)
                .transition(.opacity)
                .accessibilityLabel("No app matches")
        }
    }

    /// The record at rest; nothing while the Spotify card is open (the record is in the card: one beat, one timeline).
    @ViewBuilder private func music(_ p: DockPalette) -> some View {
        switch model.spotify.state {
        case .track where model.section == .spotify:
            EmptyView()
        case .track(let t):
            let c = EdgePanelLayout.coverCentre
            // While a timer shows, the beat room also stops short of its chip.
            EdgeWaves(palette: p, place: timers.next == nil ? .disc : .discWithChip, beat: model.spotify.beat, moving: (t.isPlaying || SpotifyBeat.pausedPulse) && model.shown)
                .frame(width: EdgeDockArt.orbRadius * 2, height: EdgeDockArt.orbRadius * 2)
                .position(x: c.x, y: c.y)
            EdgeCoverDisc(image: model.spotify.cover, spinning: t.isPlaying && model.shown && !Motion.still && !Motion.reduceMotion,
                          palette: p, title: t.title) { model.tapSpotify() }
                .position(x: c.x, y: c.y)
        case .denied:
            EdgeSmallButton(symbol: "music.note", help: "Spotify", active: model.section == .spotify, palette: p) { model.tapSpotify() }
                .position(x: EdgePanelLayout.glyphCentre.x, y: EdgePanelLayout.glyphCentre.y)
        case .notRunning, .stopped:
            EmptyView()
        }
    }
}

/// "+", search and collapse on their circle about the disc's centre (`EdgePanelLayout.discButtonCentre`), each its own
/// small glass circle.
private struct EdgeDiscButtons: View {
    @ObservedObject var model: EdgePanelModel

    var body: some View {
        let p = model.palette
        let plus = EdgePanelLayout.plusCentre, find = EdgePanelLayout.searchCentre, collapse = EdgePanelLayout.collapseCentre
        ZStack(alignment: .topLeading) {
            EdgeSmallButton(symbol: "plus", help: "Add or remove apps", active: model.section == .apps, palette: p,
                            ownGlass: true) {
                model.tapManageApps()
            }
            .position(x: plus.x, y: plus.y)
            EdgeSmallButton(symbol: "magnifyingglass", help: "Search apps", active: false, palette: p, ownGlass: true) {
                model.openSearch()
            }
            .position(x: find.x, y: find.y)
            EdgeSmallButton(symbol: "chevron.right", help: "Hide the dock", active: false, palette: p, ownGlass: true) {
                model.tapCollapse()
            }
            .position(x: collapse.x, y: collapse.y)
        }
    }
}

/// One round item on the ring: Chats, Notes or a pinned app. Fades in from 0.95 with the stagger; grows a little under the
/// pointer and while its card is open.
private struct EdgeRingItem: View {
    @ObservedObject var model: EdgePanelModel
    let item: EdgePanelModel.Item
    let index: Int
    var onHover: (Bool) -> Void = { _ in }
    @State private var hovering = false
    /// The pointer's pull (apps only: motion.dev / animate-ui "Magnetic"), at most `EdgeRingItem.pull` points.
    @State private var magnet: CGSize = .zero
    /// Counts hover entries: each one plays the bobble (motion.dev "Bobble hover").
    @State private var bobbles = 0

    /// The magnetic pull's reach (well under `EdgePanelLayout.minItemGap`, so neighbours never touch).
    static let pull: CGFloat = 3

    private var section: EdgePanelModel.Section? {
        switch item {
        case .chats: return .chats
        case .notes: return .notes
        case .app: return nil
        }
    }

    private var title: String {
        switch item {
        case .chats: return "Chats"
        case .notes: return "Notes"
        case .app(let a): return a.name
        }
    }

    var body: some View {
        let p = model.palette
        let active = section != nil && model.section == section
        // Only the pointer lifts an item. An open card marks its item with the accent rim, not a bigger size, so every
        // item at rest keeps the same outer size and the gaps between neighbours stay equal.
        let lifted = hovering && !Motion.reduceMotion
        let size = EdgePanelLayout.itemSize
        let isApp: Bool = { if case .app = item { return true } else { return false } }()
        Button(action: tap) {
            if isApp {
                // A pinned app: the real icon on its own, no circle, light or border; one soft shadow.
                content(p, on: active || hovering)
                    .shadow(color: .black.opacity(0.28), radius: 3, x: 0, y: 1.5)
                    .frame(width: size, height: size)
                    .contentShape(Rectangle())
            } else {
                // Chats or Notes: a round piece of the same glass as the disc, no shadow of its own. The glyph, the rim
                // and the mark are the glass view's own content (on the flat path the fill sits behind the glyph only,
                // as before).
                let rim = Circle().strokeBorder(active ? p.accentColor : p.rimTintColor.opacity(hovering ? 0.7 : 0.4),
                                                lineWidth: active ? 1.5 : 1)
                if EdgeDockArt.flat {
                    content(p, on: active || hovering)
                        .frame(width: size, height: size)
                        .edgeGlass(Circle(), palette: p, flat: p.baseDarkColor.opacity(0.95))
                        .overlay(rim)
                        .overlay(alignment: .topTrailing) { mark(p) }
                        .contentShape(Circle())
                } else {
                    content(p, on: active || hovering)
                        .frame(width: size, height: size)
                        .overlay(rim)
                        .overlay(alignment: .topTrailing) { mark(p) }
                        .edgeGlass(Circle(), palette: p, flat: p.baseDarkColor.opacity(0.95), lens: .item(index))
                        .contentShape(Circle())
                }
            }
        }
        .buttonStyle(EdgePressStyle(scale: isApp ? 0.96 : Motion.pressScale))
        // The bobble: a short springy wobble each time the pointer arrives.
        .keyframeAnimator(initialValue: 0.0, trigger: bobbles) { view, turn in
            view.rotationEffect(.degrees(turn))
        } keyframes: { _ in
            KeyframeTrack {
                SpringKeyframe(-9, duration: 0.12, spring: .snappy)
                SpringKeyframe(6, duration: 0.14, spring: .snappy)
                SpringKeyframe(-3, duration: 0.12, spring: .snappy)
                SpringKeyframe(0, duration: 0.3, spring: .bouncy)
            }
        }
        .offset(magnet)
        .animation(Motion.still ? nil : .spring(duration: 0.35, bounce: 0.35), value: magnet)
        .scaleEffect(lifted ? EdgePanelLayout.liftScale : 1)
        .offset(y: hovering && !Motion.reduceMotion ? -EdgePanelLayout.liftRise : 0)
        .animation(Motion.still ? nil : (isApp ? Motion.edgeRise : Motion.edgeState), value: lifted)
        .animation(Motion.still ? nil : (isApp ? Motion.edgeRise : Motion.edgeState), value: hovering)
        // The name, in a dark glass pill to the left (outside the layout, never takes the pointer).
        .overlay(alignment: .leading) {
            // The name slides in from the item with a blur that clears (animate-ui "Blur" + "Slide").
            EdgeNameLabel(text: title, palette: p)
                .fixedSize()
                .alignmentGuide(.leading) { d in d[.trailing] + 10 }
                .opacity(hovering ? 1 : 0)
                .offset(x: hovering || Motion.reduceMotion ? 0 : 8)
                .blur(radius: hovering || Motion.reduceMotion ? 0 : 3)
                .animation(Motion.still ? nil : (Motion.reduceMotion ? .easeOut(duration: 0.12)
                                                 : .spring(duration: 0.3, bounce: 0.25)), value: hovering)
                .allowsHitTesting(false)
        }
        .edgeHover({ h in
            hovering = h
            onHover(h)
            if h, !Motion.still, !Motion.reduceMotion { bobbles += 1 }
            if !h { magnet = .zero }
            if let section { model.hoverChoice(section, h) } // only Chats and Notes open on hover
        }, moved: { at in
            // Apps only (Chats and Notes are glass surfaces that keep their place).
            guard isApp, !Motion.reduceMotion else { return }
            magnet = CGSize(width: at.x * Self.pull, height: at.y * Self.pull)
        })
        // The entrance (motion.dev "Radial menu" + "Physical stagger"): each item springs out of the disc's centre along
        // its own spoke, one after another; Chats and Notes (glass) pop in place with the same spring.
        .opacity(model.shown ? 1 : 0)
        .scaleEffect(model.shown || Motion.reduceMotion ? 1 : (isApp ? 0.5 : 0.8))
        .offset(model.shown || Motion.reduceMotion || !isApp ? .zero : Self.spoke(index: index, count: model.ringItems.count))
        .animation(Motion.still ? nil : Motion.animation(model.shown ? Motion.edgePop : Motion.edgeOut)
            .delay(model.shown ? Motion.edgeStagger(index) : 0), value: model.shown)
        .help(title)
        .accessibilityLabel(title)
    }

    /// Where a hidden item waits: 45 % of the way from its place back to the disc's centre.
    static func spoke(index: Int, count: Int) -> CGSize {
        let c = EdgePanelLayout.itemCentres(count: count)
        guard c.indices.contains(index) else { return .zero }
        let o = EdgePanelLayout.coverCentre
        return CGSize(width: (o.x - c[index].x) * 0.45, height: (o.y - c[index].y) * 0.45)
    }

    private func tap() {
        switch item {
        case .chats: model.choose(.chats)
        case .notes: model.choose(.notes)
        case .app(let a): model.tapApp(a)
        }
    }

    /// The inner circle (76% of the item): a tinted well with the glyph, or the app's icon filling it.
    @ViewBuilder private func content(_ p: DockPalette, on: Bool) -> some View {
        let inner = (EdgePanelLayout.itemSize * 0.76).rounded()
        switch item {
        case .chats: symbol("bubble.left.and.bubble.right", tint: p.accentColor, on: on, inner)
        case .notes: symbol("tablecells", tint: p.rimTintColor, on: on, inner)
        case .app(let a):
            if let icon = model.apps.icon(for: a) {
                // The real app icon, whole and untinted, in its own rounded-square shape. A 36 pt image holds a ~29 pt
                // rounded square (macOS icons keep a transparent margin), whose corners stay ~4 pt inside the 44 pt well.
                Image(nsImage: icon).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .frame(width: EdgePanelLayout.appIconSize, height: EdgePanelLayout.appIconSize)
            } else {
                symbol("app", tint: p.rimTintColor, on: on, inner)
            }
        }
    }

    private func symbol(_ name: String, tint: Color, on: Bool, _ inner: CGFloat) -> some View {
        // On the see-through glass the glyph is a template symbol in `.primary` (the system picks light or dark; the accent
        // fails 3:1 over a bright window); the well keeps the tint.
        Image(systemName: name)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(EdgeDockArt.flat ? AnyShapeStyle(tint.opacity(on ? 1 : 0.9)) : AnyShapeStyle(.primary))
            .edgeScrim(2, lensOnly: true)
            .frame(width: inner, height: inner)
            .background(Circle().fill(tint.opacity(on ? EdgeGlass.wellTint : 0.15)))
            .overlay(Circle().strokeBorder(tint.opacity(0.25), lineWidth: 0.5))
    }

    /// What the chats are doing (on Chats only): a breathing accent dot while one works, a solid dot when an answer waits.
    @ViewBuilder private func mark(_ p: DockPalette) -> some View {
        let m: EdgeDotState = item == .chats ? EdgeDotState.from(model.chats.map { (phase: $0.phase, isOpen: $0.isOpen) }) : .absent
        if m != .absent {
            Group {
                if m == .breathing {
                    EdgeBreathing { Circle().fill(p.accent2Color) }
                } else {
                    Circle().fill(p.inkColor)
                }
            }
            .frame(width: 7, height: 7)
            .padding(1.5)
            .background(Circle().fill(p.baseColor))
            .offset(x: 1, y: -1)
        }
    }
}

/// The song's cover as a record, half behind the screen edge. It turns once in `Motion.edgeSpinPeriod` seconds while the
/// song plays and the panel shows; it stops where it is when paused.
private struct EdgeCoverDisc: View {
    let image: NSImage?
    let spinning: Bool
    let palette: DockPalette
    let title: String
    /// The dock's record by default; the mini player draws a bigger one with the title on its bottom arc.
    var size: CGFloat = EdgePanelLayout.coverSize
    var titleOnBottom = false
    /// nil: a picture only (the mini player's record takes no clicks).
    var action: (() -> Void)?
    @State private var angle: Double = 0
    @State private var since: Date?
    /// When the record began to slow down (it coasts to a stop over `ramp` seconds; motion.dev "Spin blur").
    @State private var stopping: Date?
    /// The spin-up and the spin-down: the speed ramps over this many seconds, like a turntable.
    static let ramp: Double = 0.9

    var body: some View {
        Group {
            if let action {
                Button(action: action) { turning.contentShape(Circle()) }
                    .buttonStyle(EdgePressStyle())
                    .help(title)
            } else {
                turning
            }
        }
        .onAppear { if spinning { since = Date() } }
        .onChange(of: spinning) { _, on in
            let now = Date()
            angle = current(at: now)
            if on {
                stopping = nil
                since = now
            } else {
                since = nil
                stopping = now
                // Only this coast may end itself (a later pause starts its own).
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.ramp + 0.05) {
                    guard stopping == now else { return }
                    angle = current(at: now.addingTimeInterval(Self.ramp))
                    stopping = nil
                }
            }
        }
        .accessibilityLabel("Now playing: \(title)")
    }

    @ViewBuilder private var turning: some View {
        if Motion.still || Motion.reduceMotion {
            record
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !spinning && stopping == nil)) { ctx in
                record.rotationEffect(.degrees(current(at: ctx.date)))
            }
        }
    }

    /// The angle now: from `angle`, speeding up from rest over `ramp` after `since`, or coasting down after `stopping`.
    private func current(at date: Date) -> Double {
        let speed = 360 / Motion.edgeSpinPeriod, t = Self.ramp
        if let since {
            let x = max(0, date.timeIntervalSince(since))
            return angle + speed * (x < t ? x * x / (2 * t) : x - t / 2)
        }
        if let stopping {
            let x = min(t, max(0, date.timeIntervalSince(stopping)))
            return angle + speed * (x - x * x / (2 * t))
        }
        return angle
    }

    /// The cover as a vinyl record: grooves, a soft specular light, a dark label with the title around the spindle.
    private var record: some View {
        let k = size / EdgePanelLayout.recordArtBase
        return ZStack {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else {
                palette.baseColor
                Image(systemName: "music.note").font(.system(size: 18 * k)).foregroundStyle(palette.inkColor.opacity(0.7))
                    .offset(x: titleOnBottom ? 0 : -size * 0.3, y: titleOnBottom ? -size * 0.3 : 0)
            }
            EdgeGrooves(from: size * 0.23 + 2, to: size / 2 - 2, every: 3.5)
            RadialGradient(colors: [.white.opacity(0.16), .white.opacity(0)], center: UnitPoint(x: 0.3, y: 0.25),
                           startRadius: 0, endRadius: size * 0.45)
            // The label, the title around the spindle, the spindle and its dot.
            Circle().fill(palette.baseDarkColor.opacity(0.82)).frame(width: size * 0.46, height: size * 0.46)
                .overlay(Circle().strokeBorder(Color.black.opacity(0.4), lineWidth: 0.5))
            // On the bottom arc the title runs on the cover just outside the label, so it spans less than half the record.
            EdgeRecordTitle(text: title, radius: size * (titleOnBottom ? 0.315 : 0.165), ink: palette.inkColor, scale: k,
                            bottom: titleOnBottom)
            Circle().fill(palette.baseDarkColor).frame(width: size * 0.22, height: size * 0.22)
                .overlay(Circle().strokeBorder(palette.rimTintColor.opacity(0.45), lineWidth: 1))
            Circle().fill(palette.accentColor).frame(width: size * 0.07, height: size * 0.07)
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(palette.rimTintColor.opacity(0.8), lineWidth: 2))
        .background(Circle().fill(Color.black).shadow(color: .black.opacity(0.5), radius: 8).allowsHitTesting(false))
    }
}

/// The record's grooves: thin dark rings every `every` points.
private struct EdgeGrooves: View {
    let from: CGFloat
    let to: CGFloat
    let every: CGFloat

    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            var r = from
            while r <= to {
                let ring = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
                ctx.stroke(ring, with: .color(.black.opacity(0.42)), lineWidth: 0.6)
                r += every
            }
        }
        .allowsHitTesting(false)
    }
}

/// The song title in capitals around the spindle, one letter at a time, centred on the record's left (the visible half),
/// or, with `bottom`, on its bottom arc and read left to right with the letters' tops to the spindle.
private struct EdgeRecordTitle: View {
    let text: String
    let radius: CGFloat
    let ink: Color
    var scale: CGFloat = 1
    var bottom = false
    static let maxLetters = 16
    static let advance: CGFloat = 4.6

    static func letters(_ title: String) -> [Character] {
        let t = Array(title.uppercased())
        return t.count <= maxLetters ? t : Array(t.prefix(maxLetters - 1)) + ["…"]
    }

    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let letters = Self.letters(text)
            let step = Double(Self.advance * scale / radius)
            // Left: the letters run up the arc (tops out). Bottom: they run right, so the angle falls (tops in).
            let centre = bottom ? Double.pi / 2 : Double.pi
            let dir: Double = bottom ? -1 : 1
            let start = centre - dir * step * Double(letters.count - 1) / 2
            if bottom, !letters.isEmpty {
                // On the cover art: a dark band under the letters keeps the ink at 4.5:1 on any cover, white included.
                let half = step * Double(letters.count) / 2
                var band = Path()
                band.addArc(center: c, radius: radius, startAngle: .radians(centre - half), endAngle: .radians(centre + half),
                            clockwise: false)
                ctx.stroke(band, with: .color(.black.opacity(EdgeDockArt.titleBand)),
                           style: StrokeStyle(lineWidth: 9 * scale, lineCap: .round))
            }
            for (i, ch) in letters.enumerated() {
                let phi = start + dir * step * Double(i)
                var g = ctx
                g.translateBy(x: c.x + radius * cos(phi), y: c.y + radius * sin(phi))
                g.rotate(by: .radians(bottom ? phi - .pi / 2 : phi + .pi / 2))
                g.draw(Text(String(ch)).font(.geistMono(6 * scale, .medium)).foregroundColor(ink.opacity(0.9)),
                       at: .zero, anchor: .center)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Three thin strings round the record that move to the beat (`SpotifyBeat`): they swell with the bass, jump on a kick
/// and wander so the outline never repeats. One 60 fps `TimelineView` runs only while `moving` (a song plays and the dock
/// shows) and for the short settle after it; then the strings rest in their calm shape. Static under `Motion.still` and
/// Reduce Motion; a pinned sample (the pictures) draws one fixed frame.
private struct EdgeWaves: View {
    let palette: DockPalette
    var place: BeatStrings.Place = .disc
    var beat: SpotifyBeat?
    var moving = false
    @State private var motion = BeatStringsMotion()
    @State private var settling = false
    @State private var settleToken = 0

    var body: some View {
        Group {
            if let pinned = beat?.pinned, moving {
                strings { motion.pin(pinned, place: place) }
            } else if beat?.pinned != nil || Motion.still || Motion.reduceMotion {
                // Paused (a pinned picture too), Motion.still, Reduce Motion: three still circles.
                strings { motion.rest(place: place) }
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !(moving || settling))) { ctx in
                    let now = ctx.date.timeIntervalSinceReferenceDate
                    strings {
                        let sample = moving ? (beat?.sample(now: now) ?? .zero) : .zero
                        motion.advance(to: now, sample: sample, moving: moving, place: place)
                    }
                }
            }
        }
        .onChange(of: moving) { _, on in
            settleToken += 1
            settling = !on
            guard !on else { return }
            let token = settleToken
            DispatchQueue.main.asyncAfter(deadline: .now() + Motion.edgeSettleDuration + 0.1) {
                if settleToken == token { settling = false }
            }
        }
        .allowsHitTesting(false)
    }

    /// The three strokes, outer to inner, in the palette's colours (`prepare` moves the strings to this frame first).
    private func strings(_ prepare: @escaping () -> Void) -> some View {
        let p = palette, m = motion
        return Canvas { gc, size in
            prepare()
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            // One line weight for all three (`BeatStrings.Place.lineWidth`), so the calm rings are equal.
            let colors: [Color] = [p.accentColor.opacity(0.55), p.rimTintColor.opacity(0.8), p.accentColor.opacity(0.85)]
            for i in stride(from: BeatStrings.rings - 1, through: 0, by: -1) {
                gc.stroke(m.ring(i).path(center: c), with: .color(colors[i]), lineWidth: BeatStrings.Place.lineWidth)
            }
        }
    }
}

/// An item's name on hover: a small dark glass pill.
private struct EdgeNameLabel: View {
    let text: String
    let palette: DockPalette

    var body: some View {
        Text(text)
            .font(.geist(11, .medium))
            .foregroundStyle(palette.inkColor)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(Capsule().fill(palette.baseDarkColor.opacity(0.92)))
            .overlay(Capsule().strokeBorder(palette.rimTintColor.opacity(0.3), lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 6, x: 0, y: 3)
    }
}

/// A small round button inside the disc ("+", collapse, the Spotify glyph).
private struct EdgeSmallButton: View {
    let symbol: String
    let help: String
    let active: Bool
    let palette: DockPalette
    /// Its own glass circle (the disc's rim buttons); else it sits on the disc's glass (the Spotify glyph).
    var ownGlass = false
    let action: () -> Void
    @State private var hovering = false
    /// Counts clicks: each one sends a ripple out of the button (animate-ui "Ripple Button").
    @State private var ripples = 0
    @Environment(\.edgeGlassStyle) private var style

    var body: some View {
        let size = EdgePanelLayout.plusSize
        Button {
            if !Motion.still, !Motion.reduceMotion { ripples += 1 }
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .regular))
                .imageScale(.small)
                // The lens: white ink always (secondary ink cannot reach 4.5:1 on its scrim).
                .foregroundStyle(active || hovering || style == .lens ? HierarchicalShapeStyle.primary : .secondary)
                .edgeScrim(2)
                .frame(width: size, height: size)
                .background(Circle().fill(palette.rimTintColor.opacity(hovering ? 0.26 : 0.18)))
                .overlay(Circle().edgeInnerLight(palette.rimTintColor.opacity(0.3), x: 0, y: 1, blur: 1))
                .overlay(Circle().strokeBorder(active ? palette.accentColor : palette.rimTintColor.opacity(0.4), lineWidth: active ? 1.5 : 1))
                .background {
                    // The flat stand-in's dark well; on the glass the button is the disc's own clear glass.
                    if EdgeDockArt.flat {
                        Circle().fill(Color.black.opacity(0.3)).shadow(color: .black.opacity(0.35), radius: 5, x: 0, y: 3)
                            .allowsHitTesting(false)
                    }
                }
                .contentShape(Circle())
                .modifier(EdgeOwnGlass(on: ownGlass, palette: palette, symbol: symbol))
                .overlay {
                    // The ripple: an accent ring that grows to twice the button and fades (outside the glass).
                    Circle().strokeBorder(palette.accentColor, lineWidth: 2)
                        .keyframeAnimator(initialValue: EdgeRipple(), trigger: ripples) { ring, r in
                            ring.scaleEffect(r.scale).opacity(r.opacity)
                        } keyframes: { _ in
                            KeyframeTrack(\.scale) {
                                LinearKeyframe(1, duration: 0.01)
                                SpringKeyframe(2.1, duration: 0.55, spring: .smooth)
                            }
                            KeyframeTrack(\.opacity) {
                                LinearKeyframe(0.85, duration: 0.01)
                                CubicKeyframe(0, duration: 0.55)
                            }
                        }
                        .allowsHitTesting(false)
                }
        }
        .buttonStyle(EdgePressStyle())
        .animation(Motion.still ? nil : Motion.edgeState, value: hovering)
        .edgeHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// One frame of a button's ripple (at rest: invisible).
private struct EdgeRipple {
    var scale: CGFloat = 1
    var opacity: Double = 0
}

/// A small button's own glass circle (the flat path: the dark disc colour under it).
private struct EdgeOwnGlass: ViewModifier {
    let on: Bool
    let palette: DockPalette
    var symbol = ""
    func body(content: Content) -> some View {
        if on {
            content.edgeGlass(Circle(), palette: palette, flat: palette.baseDarkColor.opacity(0.95), lens: .button(symbol))
        } else {
            content
        }
    }
}

/// The time left on the soonest timer or reminder, low in the disc by the screen edge (nothing when none runs). It
/// changes once a second; no other motion.
private struct EdgeTimerChip: View {
    @ObservedObject var timers: TimerStore
    let palette: DockPalette

    var body: some View {
        if let t = timers.next {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let left = max(0, Int(t.end.timeIntervalSince(ctx.date).rounded(.up)))
                HStack(spacing: 4) {
                    Image(systemName: t.isReminder ? "bell.fill" : "timer")
                        .font(.system(size: 9, weight: .semibold))
                    // The digits roll down as they change (animate-ui "Sliding Number").
                    Text(Self.clock(left))
                        .font(.geistMono(11, .medium))
                        .monospacedDigit()
                        .contentTransition(.numericText(countsDown: true))
                        .animation(Motion.still || Motion.reduceMotion ? nil : .snappy(duration: 0.3), value: left)
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 8)
                .frame(height: 22)
                // The flat stand-in keeps its dark chip; on the glass a light palette well (the disc's clear glass shows).
                .edgeScrim(2)
                .background(Capsule().fill(EdgeDockArt.flat ? Color.black.opacity(0.32) : palette.rimTintColor.opacity(0.14)))
                .edgeLensOnly(Capsule(), region: .chip)
                .overlay(Capsule().strokeBorder(palette.rimTintColor.opacity(0.4), lineWidth: 1))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel((t.isReminder ? "Reminder in " : "Timer: ") + ActionCommand.duration(max(left, 1)) + " left")
                .help(t.label.isEmpty ? (t.isReminder ? "Reminder" : "Timer") : t.label)
            }
            .transition(.opacity)
        }
    }

    /// 24:59 under an hour, 1:05:00 from an hour.
    static func clock(_ s: Int) -> String {
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}

/// The small glass search field in the disc ("Search apps"). Return opens the match; Esc is handled by the controller.
private struct EdgeSearchField: View {
    @ObservedObject var model: EdgePanelModel
    let palette: DockPalette
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            if Motion.still {
                // The pictures: a live text field can't be drawn headlessly, so the query as text.
                Text(model.query.isEmpty ? "Search apps" : model.query)
                    .foregroundStyle(model.query.isEmpty ? HierarchicalShapeStyle.secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField("", text: $model.query, prompt: Text("Search apps").foregroundStyle(.secondary))
                    .textFieldStyle(.plain)
                    .foregroundStyle(.primary)
                    .focused($focused)
                    .onSubmit { model.submitSearch() }
                    .accessibilityLabel("Search apps")
            }
        }
        .font(.geist(11, .medium))
        .lineLimit(1)
        .edgeScrim(2, lensOnly: true)
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity, maxHeight: .infinity) // the capsule fills the field's frame
        .edgeFieldWell(palette)
        .overlay(Capsule().strokeBorder(palette.accentColor.opacity(0.6), lineWidth: 1))
        // After the panel has become key (the controller does that as search opens).
        .onAppear { DispatchQueue.main.async { focused = true } }
    }
}

/// The apps card's search field ("Search apps"), in the disc field's glass. It filters the card's rows; Return adds the first
/// result not yet in the dock; Esc is handled by the controller. After the keyboard went elsewhere a click takes it back.
private struct EdgeAppsSearchField: View {
    @ObservedObject var model: EdgePanelModel
    let palette: DockPalette
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            if Motion.still || !model.appsSearchActive {
                // The pictures (a live text field can't be drawn headlessly), or the field without the keyboard: the query as text.
                Text(model.appsQuery.isEmpty ? "Search apps" : model.appsQuery)
                    .foregroundStyle(model.appsQuery.isEmpty ? HierarchicalShapeStyle.secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField("", text: $model.appsQuery, prompt: Text("Search apps").foregroundStyle(.secondary))
                    .textFieldStyle(.plain)
                    .foregroundStyle(.primary)
                    .focused($focused)
                    .onSubmit { model.submitAppsSearch() }
                    .accessibilityLabel("Search apps")
                    .onAppear { DispatchQueue.main.async { focused = true } } // after the panel has become key
            }
        }
        .font(.geist(11, .medium))
        .lineLimit(1)
        .edgeScrim(2, lensOnly: true)
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .edgeFieldWell(palette)
        .overlay(Capsule().strokeBorder(palette.accentColor.opacity(model.appsSearchActive ? 0.6 : 0.3), lineWidth: 1))
        .overlay {
            // Only while the field is inactive, so the live text field keeps its own clicks.
            if !model.appsSearchActive && !Motion.still {
                Capsule().fill(Color.clear).contentShape(Capsule()).onTapGesture { model.activateAppsSearch() }
            }
        }
    }
}

/// The Spotify card's songs field ("Search songs or artists…"), in the apps field's glass. It takes the keyboard only on a
/// click (never as the card opens). Return plays the first result; Esc is handled by the controller.
private struct EdgeSongsSearchField: View {
    @ObservedObject var model: EdgePanelModel
    let palette: DockPalette
    @FocusState private var focused: Bool

    private static let prompt = "Search songs or artists…"

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            if Motion.still || !model.songsSearchActive {
                // The pictures, or the field without the keyboard: the query as text.
                Text(model.songsQuery.isEmpty ? Self.prompt : model.songsQuery)
                    .foregroundStyle(model.songsQuery.isEmpty ? HierarchicalShapeStyle.secondary : .primary)
                    .edgeScrim(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField("", text: $model.songsQuery, prompt: Text(Self.prompt).foregroundStyle(.secondary))
                    .textFieldStyle(.plain)
                    .foregroundStyle(.primary)
                    .focused($focused)
                    .onSubmit { model.submitSongsSearch() }
                    .accessibilityLabel("Search songs or artists")
                    .onAppear { DispatchQueue.main.async { focused = true } } // after the click made the panel key
            }
        }
        .font(.geist(12, .medium))
        .lineLimit(1)
        .padding(.horizontal, 11)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .edgeFieldWell(palette, shadow: false)
        .overlay(Capsule().strokeBorder(model.songsSearchActive ? palette.accentColor.opacity(0.6) : palette.rimTintColor.opacity(0.3),
                                        lineWidth: 1))
        .overlay {
            // Only while the field is inactive, so the live text field keeps its own clicks.
            if !model.songsSearchActive && !Motion.still {
                Capsule().fill(Color.clear).contentShape(Capsule()).onTapGesture { model.activateSongsSearch() }
                    .accessibilityElement()
                    .accessibilityLabel("Search songs or artists")
                    .accessibilityAddTraits(.isButton)
            }
        }
    }
}

/// "My songs" in the record's place: the rows for the query and the star filter, or one quiet line.
private struct EdgeSongsList: View {
    @ObservedObject var model: EdgePanelModel
    let palette: DockPalette

    var body: some View {
        let rows = model.songsVisible
        VStack(spacing: 6) {
            if let notice = model.songsNotice, !rows.isEmpty {
                Text(notice).font(.geist(11, .medium)).foregroundStyle(.primary).lineLimit(1)
                    .edgeScrim(2)
                    .frame(maxWidth: .infinity).frame(height: 16)
            }
            if model.songs.songs.isEmpty && !model.songsSearchRowShown {
                EdgeQuietLine(text: "Play a song in Spotify. It shows here.")
                Spacer(minLength: 0)
            } else {
                let content = VStack(spacing: 4) {
                    if model.songs.songs.isEmpty {
                        EdgeQuietLine(text: model.songsNotice ?? "Play a song in Spotify. It shows here.")
                    } else if rows.isEmpty {
                        // One short line, above the Spotify search row ("Not in your songs yet." after Return).
                        Text(model.songsNotice ?? "No song found").font(.geist(12)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .frame(height: 22)
                    }
                    ForEach(rows) { song in
                        EdgeSongRow(song: song, cover: cover(for: song), palette: palette) { model.tapSong(song) }
                    }
                    if model.songsSearchRowShown {
                        EdgeSpotifySearchRow(query: model.songsQuery.trimmingCharacters(in: .whitespacesAndNewlines),
                                             palette: palette) { model.searchSpotify() }
                    }
                }
                if Motion.still {
                    // The pictures: a scroll view can't be drawn headlessly, so the rows that would show.
                    content.frame(maxHeight: .infinity, alignment: .top).clipped()
                } else {
                    ScrollView(.vertical, showsIndicators: false) { content }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Only an image already loaded: the current song's cover. No new loads for rows.
    private func cover(for song: SpotifySong) -> NSImage? {
        guard let art = song.artworkURL, art == model.track?.artworkURL?.absoluteString else { return nil }
        return model.spotify.cover
    }
}

/// The last row while a query is typed: `Search Spotify for "<query>"`, which opens Spotify's own search.
private struct EdgeSpotifySearchRow: View {
    let query: String
    let palette: DockPalette
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(palette.rimTintColor.opacity(0.12)))
                Text("Search Spotify for \u{201C}\(query)\u{201D}").font(.geist(12, .medium)).foregroundStyle(.primary)
                    .lineLimit(1).truncationMode(.middle)
                    .edgeScrim(3)
                Spacer(minLength: 6)
                Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(.leading, 5)
            .padding(.trailing, 10)
            .frame(height: 38)
            .background(shape.fill(hovering ? palette.hoverFill : palette.restFill))
            .overlay(shape.strokeBorder(palette.hairlineColor, lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(EdgePressStyle(scale: 0.98))
        .animation(Motion.still ? nil : Motion.edgeState, value: hovering)
        .edgeHover { hovering = $0 }
        .help("Search Spotify for \u{201C}\(query)\u{201D}")
        .accessibilityLabel("Search Spotify for \(query)")
    }
}

private struct EdgeSongRow: View {
    let song: SpotifySong
    let cover: NSImage?
    let palette: DockPalette
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        Button(action: action) {
            HStack(spacing: 9) {
                Group {
                    if let cover {
                        Image(nsImage: cover).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "music.note").font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(palette.rimTintColor.opacity(0.12)))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(song.name).font(.geist(12, .medium)).foregroundStyle(.primary)
                    Text(song.artist).font(.geist(11)).foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .edgeScrim(3)
                Spacer(minLength: 6)
                Image(systemName: song.starred ? "star.fill" : "star")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(song.starred ? AnyShapeStyle(palette.accentColor) : AnyShapeStyle(.tertiary))
                    .accessibilityLabel(song.starred ? "Starred" : "Not starred")
            }
            .padding(.leading, 5)
            .padding(.trailing, 10)
            .frame(height: 38)
            .background(shape.fill(hovering ? palette.hoverFill : palette.restFill))
            .overlay(shape.strokeBorder(palette.hairlineColor, lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(EdgePressStyle(scale: 0.98))
        .animation(Motion.still ? nil : Motion.edgeState, value: hovering)
        .edgeHover { hovering = $0 }
        .help("Play \(song.name)")
        .accessibilityLabel("Play \(song.name) by \(song.artist)")
    }
}

// MARK: - Cards

/// The Spotify mini player, one layout in every state: a search row ("my songs" and the star filter; a query or the filter
/// shows the saved songs in the record's place), the song's record in three
/// waves (they move while it plays), the title and artist or a status line, previous / play-pause / next / stop / heart,
/// and "Open Spotify", which with the list's "Search Spotify for …" row is the only control that may bring up Spotify.
struct EdgeSpotifyCard: View {
    @ObservedObject var model: EdgePanelModel
    @Environment(\.edgeGlassStyle) private var glassStyle

    private typealias L = EdgePanelLayout

    var body: some View {
        let p = model.palette
        let t = model.track
        let enabled = model.transportEnabled
        // Top to bottom with the Stitch numbers (`EdgePanelLayout.spotify*`): every row has a fixed height, so the card
        // is 304 pt in every state.
        VStack(spacing: 0) {
            searchRow(p)
            if model.songsListShown {
                // The saved songs in the record's place (record, caption and gaps), so the card keeps its size.
                EdgeSongsList(model: model, palette: p)
                    .padding(.vertical, 8)
                    .frame(height: L.spotifyButtonsTop - L.spotifyPad - L.spotifySearchHeight)
            } else {
                Color.clear.frame(height: L.spotifyRecordGap)
                record(t, p)
                caption(t)
                    .padding(.bottom, L.spotifyCaptionToButtons)
                    .frame(height: L.spotifyRecordToButtons, alignment: .bottom)
            }
            HStack(spacing: L.spotifyButtonGap) {
                EdgeMusicButton(symbol: "backward.end.fill", help: "Previous") { model.tapSpotifyCommand(.previous) }
                EdgeMusicButton(symbol: t?.isPlaying == true ? "pause.fill" : "play.fill",
                                help: t?.isPlaying == true ? "Pause" : "Play", prominent: p) { model.tapSpotifyCommand(.playPause) }
                EdgeMusicButton(symbol: "forward.end.fill", help: "Next") { model.tapSpotifyCommand(.next) }
                EdgeMusicButton(symbol: "stop.fill", help: "Stop", tint: p.accent2Color) { model.tapSpotifyCommand(.stop) }
                    .disabled(t == nil) // nothing to stop
                EdgeMusicButton(symbol: model.currentStarred ? "heart.fill" : "heart",
                                help: model.currentStarred ? "Unstar this song" : "Star this song",
                                tint: p.accent2Color) { model.tapHeart() }
                    .disabled(!model.canStarCurrent) // no song (or one Merlin can't keep)
            }
            .disabled(!enabled)
            .frame(height: L.spotifyPlaySize)
        }
        .padding(.horizontal, L.spotifyPad)
        .padding(.vertical, L.spotifyPad)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// The songs field (it filters "my songs") and the round star filter (starred songs only; accent while on).
    private func searchRow(_ p: DockPalette) -> some View {
        HStack(spacing: L.spotifyStarGap) {
            EdgeSongsSearchField(model: model, palette: p)
                .frame(width: L.spotifySearchWidth)
            EdgeMusicButton(symbol: model.songsStarredOnly ? "star.fill" : "star",
                            help: model.songsStarredOnly ? "Show all songs" : "Starred songs",
                            tint: model.songsStarredOnly ? p.accentColor : nil,
                            side: L.spotifyStarSize) { model.tapSongsStarFilter() }
        }
        .frame(height: L.spotifySearchHeight)
    }

    /// One small line under the record: "Title — Artist" (truncating) and the arrow that opens Spotify; or what is
    /// wrong (up to two lines; no waves then, so it may rise into their place).
    @ViewBuilder private func caption(_ t: SpotifyTrack?) -> some View {
        if let t {
            HStack(spacing: 6) {
                Text(t.artist.isEmpty ? t.title : "\(t.title) \u{2014} \(t.artist)")
                    .font(.geist(11, .medium))
                    .foregroundStyle(glassStyle == .lens ? HierarchicalShapeStyle.primary : .secondary) // the lens: white ink
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .edgeScrim(3)
                Spacer(minLength: 0)
                EdgeOpenSpotifyButton { model.tapOpenSpotify() }
            }
            .frame(height: L.spotifyCaptionHeight)
        } else {
            HStack(alignment: .bottom, spacing: 6) {
                Text(status).font(.geist(11)).foregroundStyle(.secondary)
                    .lineLimit(2).minimumScaleFactor(0.85)
                    .edgeScrim(3)
                Spacer(minLength: 0)
                EdgeOpenSpotifyButton { model.tapOpenSpotify() }
                    .frame(height: L.spotifyCaptionHeight)
            }
        }
    }

    /// The song's record with its title on the bottom arc, in the waves; a plain record without a song.
    /// The record (laid out at its own size; the waves' orb overflows it without moving the rows).
    private func record(_ t: SpotifyTrack?, _ p: DockPalette) -> some View {
        let orb = (max(L.spotifyOrbRadius, BeatStrings.Place.card.limit) + 2) * 2 // room for a beat's jump
        return EdgeCoverDisc(image: t == nil ? nil : model.spotify.cover, spinning: t?.isPlaying == true && model.shown,
                             palette: p, title: t?.title ?? "", size: L.spotifyRecord, titleOnBottom: true)
            .accessibilityHidden(t == nil)
            .frame(width: L.spotifyRecord, height: L.spotifyRecord)
            .background {
                if let t {
                    EdgeWaves(palette: p, place: .card, beat: model.spotify.beat, moving: (t.isPlaying || SpotifyBeat.pausedPulse) && model.shown)
                        .frame(width: orb, height: orb)
                }
            }
    }

    private var status: String {
        switch model.spotify.state {
        case .denied: return "Allow Merlin to control Spotify in System Settings › Privacy & Security › Automation."
        case .notRunning: return "Spotify is not open."
        case .stopped, .track: return "Nothing is playing."
        }
    }
}

/// A round music button. The play-pause one is larger and filled with the dock's accent; `tint` gives a soft coloured well.
/// Disabled: dimmed, with no hover.
private struct EdgeMusicButton: View {
    let symbol: String
    let help: String
    var prominent: DockPalette?
    var tint: Color?
    var side: CGFloat?
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    @Environment(\.edgePalette) private var pal
    @State private var hovering = false

    var body: some View {
        let size: CGFloat = side ?? (prominent == nil ? EdgePanelLayout.spotifyButtonSize : EdgePanelLayout.spotifyPlaySize)
        let lit = hovering && enabled
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: prominent == nil ? 12 : 15, weight: .semibold))
                // Play-pause: black or white, whichever contrasts more with its accent fill (at least 4.5:1). The rest sit
                // on the glass: hierarchical, so the system picks light or dark.
                .foregroundStyle(prominent.map { AnyShapeStyle($0.onAccentColor) }
                                 ?? AnyShapeStyle(lit || tint != nil ? HierarchicalShapeStyle.primary : .secondary))
                .edgeScrim(prominent == nil ? 2 : 0) // the solid play button needs none
                .frame(width: size, height: size)
                // Round glass: the palette's light at 10% with a 30% edge; play-pause filled with the accent; a tint fills its own well.
                .background(Circle().fill(prominent.map { $0.accentColor }
                                          ?? tint.map { $0.opacity(lit ? 0.32 : 0.24) }
                                          ?? pal.rimTintColor.opacity(lit ? 0.18 : 0.11)))
                .edgeLensOnly(Circle(), on: prominent == nil) // the lens: its own small lens; the accent one keeps its fill
                .overlay(Circle().strokeBorder(tint.map { $0.opacity(0.45) } ?? pal.rimTintColor.opacity(prominent == nil ? 0.30 : 0.4),
                                               lineWidth: 1))
                .overlay(Circle().edgeInnerLight(pal.rimTintColor.opacity(0.3), x: 0, y: 1, blur: 1))
                // On the glass only the solid play-pause casts a shadow (a shadow under a see-through well shows as a dark blot).
                .shadow(color: .black.opacity(EdgeDockArt.flat ? 0.3 : (prominent == nil ? 0 : 0.2)), radius: 4, x: 0, y: 2)
                .contentShape(Circle())
                .opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(EdgePressStyle(scale: 0.92))
        .animation(Motion.still ? nil : Motion.edgeState, value: lit)
        .edgeHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// "Open Spotify": a small arrow glyph at the right end of the caption line (help text "Open Spotify").
private struct EdgeOpenSpotifyButton: View {
    let action: () -> Void
    @Environment(\.edgePalette) private var pal
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(hovering ? HierarchicalShapeStyle.primary : .secondary)
                .edgeScrim(2)
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(EdgePressStyle(scale: 0.96))
        .animation(Motion.still ? nil : Motion.edgeState, value: hovering)
        .edgeHover { hovering = $0 }
        .help("Open Spotify")
        .accessibilityLabel("Open Spotify")
    }
}

/// The add/remove card: a search field, the tabs, the pinned apps first, then every other installed app, each with Add or
/// Remove. The field takes the keyboard as the card opens (the panel may be key for it, as for the disc's search).
struct EdgeAppsCard: View {
    @ObservedObject var model: EdgePanelModel

    private static let titleHeight: CGFloat = 40
    private static let searchHeight: CGFloat = 36
    private static let filterHeight: CGFloat = 36
    private static let footerHeight: CGFloat = 40
    /// What is left of the fixed card for the list (the card keeps `appsSize`; the list gives up the field's height).
    private static var listHeight: CGFloat {
        EdgePanelLayout.appsSize.height - titleHeight - 1 - searchHeight - filterHeight - 1 - footerHeight
    }

    private var filter: EdgePanelModel.AppsFilter { model.appsFilter }

    var body: some View {
        let p = model.palette
        VStack(spacing: 0) {
            titleBar(p)
            Rectangle().fill(p.hairlineColor).frame(height: 1)
            EdgeAppsSearchField(model: model, palette: p)
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .frame(height: Self.searchHeight)
            filterBar(p)
            list(p)
            Rectangle().fill(p.hairlineColor).frame(height: 1)
            footer(p)
        }
    }

    private func close() { model.toggle(.apps) }

    private func titleBar(_ p: DockPalette) -> some View {
        ZStack {
            Text("App Customization").font(.geist(13, .semibold)).foregroundStyle(.primary)
            HStack {
                Button(action: close) {
                    Circle().fill(Color(red: 1, green: 0.37, blue: 0.34))
                        .overlay(Circle().strokeBorder(Color.black.opacity(0.2), lineWidth: 0.5))
                        .frame(width: 12, height: 12)
                        .padding(4)
                        .contentShape(Circle())
                }
                .buttonStyle(EdgePressStyle(scale: 0.9))
                .help("Close")
                .accessibilityLabel("Close")
                Spacer() // the count lives in the footer ("n in rotation"), so the title has the bar to itself
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Self.titleHeight)
    }

    private func filterBar(_ p: DockPalette) -> some View {
        HStack(spacing: 2) {
            ForEach(EdgePanelModel.AppsFilter.allCases, id: \.self) { f in
                Button { model.appsFilter = f } label: {
                    Text(f.title)
                        .font(.geist(11, .medium))
                        .foregroundStyle(filter == f ? HierarchicalShapeStyle.primary : .secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                        .background(Capsule().fill(filter == f ? p.selectedFill : .clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(EdgePressStyle())
            }
        }
        .padding(2)
        .background(Capsule().fill(p.restFill))
        .overlay(Capsule().strokeBorder(p.hairlineColor, lineWidth: 1))
        .padding(.horizontal, 10)
        .frame(height: Self.filterHeight)
    }

    @ViewBuilder private func list(_ p: DockPalette) -> some View {
        let visible = model.appsVisible
        let searching = !model.appsQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let inRotation = visible.filter { model.apps.isPinned($0.bundleID) }
        let available = visible.filter { !model.apps.isPinned($0.bundleID) }
        let content = VStack(spacing: 4) {
            if model.apps.installed.isEmpty && filter != .inRotation && searching {
                EdgeQuietLine(text: "Looking for apps…")
            } else if searching && visible.isEmpty {
                EdgeQuietLine(text: "No app found")
            } else {
                if filter != .available && !(searching && inRotation.isEmpty) { // no empty section while a query is typed
                    header("In rotation", inRotation.count)
                    ForEach(inRotation) { row($0, p) }
                }
                if filter != .inRotation && !(searching && available.isEmpty) {
                    header("Available to add", available.count)
                    if model.apps.installed.isEmpty {
                        EdgeQuietLine(text: "Looking for apps…")
                    } else {
                        ForEach(available) { row($0, p) }
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
        if Motion.still {
            // The pictures: a scroll view can't be drawn headlessly, so the rows that would show.
            content.frame(height: Self.listHeight, alignment: .top).clipped()
        } else {
            ScrollView(.vertical, showsIndicators: false) { content }
                .frame(height: Self.listHeight)
        }
    }

    private func header(_ title: String, _ count: Int) -> some View {
        HStack {
            Text(title.uppercased()).font(.geist(10, .semibold)).tracking(0.8)
            Spacer()
            Text("\(count)").font(.geistMono(10, .medium))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
        .frame(height: 22)
    }

    private func row(_ app: DockApp, _ p: DockPalette) -> some View {
        EdgeAppRow(app: app, icon: model.apps.icon(for: app), pinned: model.apps.isPinned(app.bundleID),
                   canAdd: model.apps.canPin, palette: p) {
            if model.apps.isPinned(app.bundleID) { model.tapUnpin(app) } else { model.tapPin(app) }
        }
    }

    private func footer(_ p: DockPalette) -> some View {
        HStack {
            if model.apps.canPin {
                Text("\(model.apps.pinned.count) in rotation").font(.geistMono(11)).foregroundStyle(.secondary)
            } else {
                // The dock is full: the Add buttons are dim and disabled, and this says why.
                Text("Remove an app to add another").font(.geist(11, .medium)).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button(action: close) {
                Text("Done")
                    .font(.geist(12, .semibold))
                    .foregroundStyle(p.onAccentColor)
                    .padding(.horizontal, 14)
                    .frame(height: 26)
                    .background(Capsule().fill(p.accentColor))
                    .contentShape(Capsule())
            }
            .buttonStyle(EdgePressStyle())
        }
        .padding(.horizontal, 12)
        .frame(height: Self.footerHeight)
    }
}

private struct EdgeAppRow: View {
    let app: DockApp
    let icon: NSImage?
    let pinned: Bool
    let canAdd: Bool
    let palette: DockPalette
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        HStack(spacing: 10) {
            Group {
                if let icon {
                    // The whole app icon in its own rounded-square shape (never cut to the circle).
                    Image(nsImage: icon).resizable().interpolation(.high).aspectRatio(contentMode: .fit).frame(width: 26, height: 26)
                } else {
                    Image(systemName: "app").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 32, height: 32)
            .background(Circle().fill(palette.rimColor.opacity(0.18)))
            .overlay(Circle().strokeBorder(palette.hairlineColor, lineWidth: 1))
            Text(app.name).font(.geist(12, .medium)).foregroundStyle(.primary).lineLimit(1)
                .edgeScrim(2, lensOnly: true)
            Spacer(minLength: 8)
            Button(action: action) {
                // Solid fills with their own contrast (white on dark red; black or white on the accent), never see-through.
                Text(pinned ? "Remove" : "Add")
                    .font(.geist(11, .semibold))
                    .foregroundStyle(pinned ? Color.white : palette.onAccentColor)
                    .padding(.horizontal, 10)
                    .frame(height: 22)
                    .background(Capsule().fill(pinned ? Color(red: 0.6, green: 0.12, blue: 0.12) : palette.accentColor))
                    .contentShape(Capsule())
            }
            .buttonStyle(EdgePressStyle())
            .disabled(!pinned && !canAdd)
            .opacity(!pinned && !canAdd ? 0.4 : 1)
            .help(pinned ? "Remove \(app.name) from the dock" : (canAdd ? "Add \(app.name) to the dock" : "The dock is full"))
        }
        .padding(.leading, 4)
        .padding(.trailing, 8)
        .frame(height: 40)
        .background(shape.fill(hovering ? palette.hoverFill : palette.restFill))
        .overlay(shape.strokeBorder(palette.hairlineColor, lineWidth: 1))
        .edgeHover { h in withAnimation(Motion.still ? nil : Motion.animation(Motion.small)) { hovering = h } }
    }
}
