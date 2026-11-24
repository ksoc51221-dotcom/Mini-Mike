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

private struct EdgePaletteKey: EnvironmentKey { static let defaultValue = DockPalette.emerald }

extension EnvironmentValues {
    /// The dock's current palette, for the card rows that don't take it as a parameter.
    var edgePalette: DockPalette {
        get { self[EdgePaletteKey.self] }
        set { self[EdgePaletteKey.self] = newValue }
    }
}

/// Where the dock's drawn parts sit (dock coordinates, y down), beyond `EdgePanelLayout`'s numbers.
enum EdgeDockArt {
    /// The orb the three wave rings are drawn in (at 0.84, 0.74 and 0.64 of it), around the record.
    /// 66 keeps the outer wave clear of the disc buttons' column, now 14 pt in from the rim.
    static let orbRadius: CGFloat = 66
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

    /// The glass of every surface: the disc, Chats and Notes, and the cards.
    static func glass(_ palette: DockPalette) -> Glass {
        .regular.tint(palette.rimColor.opacity(tint))
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
    @ViewBuilder func edgeGlass<S: Shape>(_ shape: S, palette: DockPalette, flat: Color) -> some View {
        if EdgeDockArt.flat {
            background(shape.fill(flat).allowsHitTesting(false))
        } else {
            glassEffect(EdgeGlass.glass(palette), in: shape)
                .glassEffectTransition(.identity) // no system glass motion: the existing `Motion.edge*` fades only
        }
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
        }
    }

    /// The dark scheme on the flat path only (a solid dark surface with light text). On the glass path the scheme is left
    /// alone, so the glass and the hierarchical styles pick light or dark content.
    func edgeFlatScheme() -> some View { modifier(EdgeFlatScheme()) }
}

private struct EdgeFlatScheme: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content.environment(\.colorScheme, EdgeDockArt.flat ? .dark : scheme)
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
            EdgeHalo(palette: p)
                .frame(width: s.width, height: s.height)
            EdgeDockDisc(model: model)
                .frame(width: s.width, height: s.height)
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

/// The ring the items sit on: one accent hairline, concentric with the disc (no glow).
private struct EdgeHalo: View {
    let palette: DockPalette

    var body: some View {
        EdgeHalfDisc(radius: EdgePanelLayout.ringRadius)
            .stroke(palette.accentColor.opacity(0.35), lineWidth: 1)
            .allowsHitTesting(false)
    }
}

/// What lies under the disc's content (drawn in a frame one radius wide, two high): its shadow and, on the flat path, the
/// painted disc and its lines. On the glass path the shadow only: the glass and the lines are part of the content view.
private struct EdgeDiscGlass: View {
    let palette: DockPalette

    var body: some View {
        let p = palette
        let disc = EdgeHalfDisc()
        let track = EdgeHalfDisc(radius: EdgePanelLayout.discRadius * 0.89)
        ZStack {
            // One soft ambient shadow below the disc (outside the disc only, so it never covers the glass).
            EdgeOuterShadow(shape: disc, color: .black.opacity(0.3), radius: 16, y: 6)
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
                .edgeGlass(Circle(), palette: p, flat: p.baseColor)
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
                buttons(p).transition(fade)
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

    /// "+", search and collapse: one column, same size and style.
    @ViewBuilder private func buttons(_ p: DockPalette) -> some View {
        let plus = EdgePanelLayout.plusCentre, find = EdgePanelLayout.searchCentre, collapse = EdgePanelLayout.collapseCentre
        EdgeSmallButton(symbol: "plus", help: "Add or remove apps", active: model.section == .apps, palette: p) {
            model.tapManageApps()
        }
        .position(x: plus.x, y: plus.y)
        EdgeSmallButton(symbol: "magnifyingglass", help: "Search apps", active: false, palette: p) {
            model.openSearch()
        }
        .position(x: find.x, y: find.y)
        EdgeSmallButton(symbol: "chevron.right", help: "Hide the dock", active: false, palette: p) {
            model.tapCollapse()
        }
        .position(x: collapse.x, y: collapse.y)
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
                .position(x: EdgePanelLayout.noMatchCentre.x, y: EdgePanelLayout.noMatchCentre.y)
                .transition(.opacity)
                .accessibilityLabel("No app matches")
        }
    }

    @ViewBuilder private func music(_ p: DockPalette) -> some View {
        switch model.spotify.state {
        case .track(let t):
            let c = EdgePanelLayout.coverCentre
            EdgeWaves(palette: p)
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

/// One round item on the ring: Chats, Notes or a pinned app. Fades in from 0.95 with the stagger; grows a little under the
/// pointer and while its card is open.
private struct EdgeRingItem: View {
    @ObservedObject var model: EdgePanelModel
    let item: EdgePanelModel.Item
    let index: Int
    var onHover: (Bool) -> Void = { _ in }
    @State private var hovering = false

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
                        .edgeGlass(Circle(), palette: p, flat: p.baseDarkColor.opacity(0.95))
                        .contentShape(Circle())
                }
            }
        }
        .buttonStyle(EdgePressStyle(scale: isApp ? 0.96 : Motion.pressScale))
        .scaleEffect(lifted ? EdgePanelLayout.liftScale : 1)
        .offset(y: hovering && !Motion.reduceMotion ? -EdgePanelLayout.liftRise : 0)
        .animation(Motion.still ? nil : (isApp ? Motion.edgeRise : Motion.edgeState), value: lifted)
        .animation(Motion.still ? nil : (isApp ? Motion.edgeRise : Motion.edgeState), value: hovering)
        // The name, in a dark glass pill to the left (outside the layout, never takes the pointer).
        .overlay(alignment: .leading) {
            EdgeNameLabel(text: title, palette: p)
                .fixedSize()
                .alignmentGuide(.leading) { d in d[.trailing] + 10 }
                .opacity(hovering ? 1 : 0)
                .animation(Motion.still ? nil : .easeOut(duration: 0.12), value: hovering)
                .allowsHitTesting(false)
        }
        .edgeHover { h in
            hovering = h
            onHover(h)
            if let section { model.hoverChoice(section, h) } // only Chats and Notes open on hover
        }
        // The entrance: a fade and a scale from 0.95, one item after another.
        .opacity(model.shown ? 1 : 0)
        .scaleEffect(model.shown || Motion.reduceMotion ? 1 : 0.95)
        .animation(Motion.still ? nil : Motion.animation(model.shown ? Motion.edgeIn : Motion.edgeOut)
            .delay(model.shown ? Motion.edgeStagger(index) : 0), value: model.shown)
        .help(title)
        .accessibilityLabel(title)
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
            if on {
                since = Date()
            } else {
                angle = current(at: Date())
                since = nil
            }
        }
        .accessibilityLabel("Now playing: \(title)")
    }

    @ViewBuilder private var turning: some View {
        if Motion.still || Motion.reduceMotion {
            record
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !spinning)) { ctx in
                record.rotationEffect(.degrees(current(at: ctx.date)))
            }
        }
    }

    private func current(at date: Date) -> Double {
        guard let since else { return angle }
        return angle + date.timeIntervalSince(since) * 360 / Motion.edgeSpinPeriod
    }

    /// The cover as a vinyl record: grooves, a soft specular light, a dark label with the title around the spindle.
    private var record: some View {
        let k = size / EdgePanelLayout.coverSize
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

/// Three thin rings with a gentle wobble around the record. Static in the dock; in the mini player they drift (each its own
/// way, one turn of the wobble per `Motion.edgeSpinPeriod`) while `moving`, and stay still under `Motion.still` and
/// Reduce Motion.
private struct EdgeWaves: View {
    let palette: DockPalette
    var orbRadius: CGFloat = EdgeDockArt.orbRadius
    /// How much deeper the wobble is than the dock's.
    var wobble: CGFloat = 1
    var moving = false

    var body: some View {
        if Motion.still || Motion.reduceMotion || !moving {
            rings(0)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !moving)) { ctx in
                rings(ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Motion.edgeSpinPeriod)
                      / Motion.edgeSpinPeriod * 2 * .pi)
            }
        }
    }

    private func rings(_ t: Double) -> some View {
        let o = orbRadius
        return ZStack {
            EdgeWave(radius: o * 0.84, amplitude: 1.6 * wobble, lobes: 7, phase: t)
                .stroke(palette.accentColor.opacity(0.85), lineWidth: 1.5)
            EdgeWave(radius: o * 0.74, amplitude: 1.4 * wobble, lobes: 9, phase: 1.3 - t)
                .stroke(palette.rimTintColor.opacity(0.8), lineWidth: 1.25)
            EdgeWave(radius: o * 0.64, amplitude: 1.2 * wobble, lobes: 11, phase: 2.6 + 2 * t)
                .stroke(palette.accentColor.opacity(0.55), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

/// A circle whose radius swells and dips `lobes` times around.
private struct EdgeWave: Shape {
    let radius: CGFloat
    let amplitude: CGFloat
    let lobes: Int
    let phase: Double

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let n = 180
        for i in 0...n {
            let t = Double(i) / Double(n) * 2 * .pi
            let r = radius + amplitude * CGFloat(sin(Double(lobes) * t + phase))
            let pt = CGPoint(x: c.x + r * CGFloat(cos(t)), y: c.y + r * CGFloat(sin(t)))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
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
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let size = EdgePanelLayout.plusSize
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .regular))
                .imageScale(.small)
                .foregroundStyle(active || hovering ? HierarchicalShapeStyle.primary : .secondary)
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
        }
        .buttonStyle(EdgePressStyle())
        .animation(Motion.still ? nil : Motion.edgeState, value: hovering)
        .edgeHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
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
                    Text(Self.clock(left))
                        .font(.geistMono(11, .medium))
                        .monospacedDigit()
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 8)
                .frame(height: 22)
                // The flat stand-in keeps its dark chip; on the glass a light palette well (the disc's clear glass shows).
                .background(Capsule().fill(EdgeDockArt.flat ? Color.black.opacity(0.32) : palette.rimTintColor.opacity(0.14)))
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
            if let notice = model.songsNotice {
                Text(notice).font(.geist(11, .medium)).foregroundStyle(.primary).lineLimit(1)
                    .frame(maxWidth: .infinity).frame(height: 16)
            }
            if model.songs.songs.isEmpty && !model.songsSearchRowShown {
                EdgeQuietLine(text: "Play a song in Spotify. It shows here.")
                Spacer(minLength: 0)
            } else {
                let content = VStack(spacing: 4) {
                    if model.songs.songs.isEmpty {
                        EdgeQuietLine(text: "Play a song in Spotify. It shows here.")
                    } else if rows.isEmpty {
                        // One short line, above the Spotify search row.
                        Text("No song found").font(.geist(12)).foregroundStyle(.secondary)
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

    private typealias L = EdgePanelLayout

    var body: some View {
        let p = model.palette
        let t = model.track
        let enabled = model.transportEnabled
        VStack(spacing: L.spotifySpacing) {
            searchRow(p)
            if model.songsListShown {
                // The saved songs in the record's place (the same height, so the card keeps its size).
                EdgeSongsList(model: model, palette: p)
                    .frame(height: L.spotifyOrbRadius * 2)
            } else {
                record(t, p)
            }
            text(t)
            HStack(spacing: 14) {
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
            .frame(height: L.spotifyButtonsHeight)
            EdgeOpenSpotifyButton { model.tapOpenSpotify() }
                .frame(height: L.spotifyOpenHeight)
        }
        .padding(L.spotifyPad)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// The songs field (it filters "my songs") and the star filter (starred songs only; accent while on).
    private func searchRow(_ p: DockPalette) -> some View {
        HStack(spacing: 8) {
            EdgeSongsSearchField(model: model, palette: p)
            EdgeMusicButton(symbol: model.songsStarredOnly ? "star.fill" : "star",
                            help: model.songsStarredOnly ? "Show all songs" : "Starred songs",
                            tint: model.songsStarredOnly ? p.accentColor : nil,
                            side: L.spotifySearchHeight) { model.tapSongsStarFilter() }
        }
        .frame(height: L.spotifySearchHeight)
    }

    /// The song's record with its title on the bottom arc, in the waves; a plain record without a song.
    private func record(_ t: SpotifyTrack?, _ p: DockPalette) -> some View {
        let orb = L.spotifyOrbRadius * 2
        return ZStack {
            if let t {
                EdgeWaves(palette: p, orbRadius: L.spotifyOrbRadius, wobble: 2.5, moving: t.isPlaying && model.shown)
                    .frame(width: orb, height: orb)
            }
            EdgeCoverDisc(image: t == nil ? nil : model.spotify.cover, spinning: t?.isPlaying == true && model.shown,
                          palette: p, title: t?.title ?? "", size: L.spotifyRecord, titleOnBottom: true)
                .accessibilityHidden(t == nil)
        }
        .frame(width: orb, height: orb)
    }

    /// The title and artist, or what is wrong, centred.
    @ViewBuilder private func text(_ t: SpotifyTrack?) -> some View {
        Group {
            if let t {
                VStack(spacing: 3) {
                    Text(t.title).font(.geist(14, .semibold)).foregroundStyle(.primary).lineLimit(1)
                    Text(t.artist).font(.geist(12)).foregroundStyle(.secondary).lineLimit(1)
                }
            } else {
                Text(status).font(.geist(12)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).lineLimit(3).minimumScaleFactor(0.85)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: L.spotifyTextHeight)
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
        let size: CGFloat = side ?? (prominent == nil ? 34 : 44)
        let lit = hovering && enabled
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: prominent == nil ? 12 : 16, weight: .semibold))
                // Play-pause: black or white, whichever contrasts more with its accent fill (at least 4.5:1). The rest sit
                // on the glass: hierarchical, so the system picks light or dark.
                .foregroundStyle(prominent.map { AnyShapeStyle($0.onAccentColor) }
                                 ?? AnyShapeStyle(lit || tint != nil ? HierarchicalShapeStyle.primary : .secondary))
                .frame(width: size, height: size)
                // Round glass: the palette's light at 10% with a 30% edge; play-pause filled with the accent; a tint fills its own well.
                .background(Circle().fill(prominent.map { $0.accentColor }
                                          ?? tint.map { $0.opacity(lit ? 0.32 : 0.24) }
                                          ?? pal.rimTintColor.opacity(lit ? 0.18 : 0.11)))
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

/// "Open Spotify": a small text button under the mini player's controls.
private struct EdgeOpenSpotifyButton: View {
    let action: () -> Void
    @Environment(\.edgePalette) private var pal
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text("Open Spotify")
                Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
            }
            .font(.geist(12, .medium))
            .foregroundStyle(hovering ? HierarchicalShapeStyle.primary : .secondary)
            .padding(.horizontal, 8)
            .frame(maxHeight: .infinity)
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
