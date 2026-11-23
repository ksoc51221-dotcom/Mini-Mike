import AppKit
import SwiftUI

// The edge panel's dock: a dark glass half-disc at the screen edge, a thin halo ring outside it with the round items on it
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
}

/// Where the dock's drawn parts sit (dock coordinates, y down), beyond `EdgePanelLayout`'s numbers.
enum EdgeDockArt {
    /// The orb the three wave rings are drawn in (at 0.84, 0.74 and 0.64 of it), around the record.
    static let orbRadius: CGFloat = 76
    /// CSS 155°: from the top (a little left) to the bottom (a little right).
    static let from155 = UnitPoint(x: 0.29, y: 0.05)
    static let to155 = UnitPoint(x: 0.71, y: 0.95)
    /// Blur behind the glass only when it can be drawn and the user wants it.
    static var flat: Bool { Motion.still || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency }
}

// MARK: - Glass parts

/// Behind-window blur in a shape. Kept active while Merlin is not the active app (like `popoverBackdrop`), and masked with
/// an image (SwiftUI clips are unreliable on behind-window blur).
struct EdgeBlur<S: Shape>: NSViewRepresentable {
    let shape: S

    final class Blur: NSVisualEffectView {
        var makePath: ((CGRect) -> CGPath)?
        private var maskedSize: CGSize = .zero
        override func layout() {
            super.layout()
            guard let makePath, bounds.width > 0, bounds.height > 0, bounds.size != maskedSize else { return }
            maskedSize = bounds.size
            let path = makePath(bounds)
            maskImage = NSImage(size: bounds.size, flipped: true) { _ in
                guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
                ctx.addPath(path)
                ctx.setFillColor(NSColor.black.cgColor)
                ctx.fillPath()
                return true
            }
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> Blur {
        let v = Blur()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ v: Blur, context: Context) {
        let shape = shape
        v.makePath = { shape.path(in: $0).cgPath }
        v.needsLayout = true
    }
}

/// The glass under a surface: blur with the tint on top, or the flat colour in the pictures and under Reduce Transparency.
struct EdgeGlassFill<S: Shape>: View {
    let shape: S
    let tint: Color
    let tintOpacity: Double
    let flat: Color

    var body: some View {
        Group {
            if EdgeDockArt.flat {
                shape.fill(flat)
            } else {
                ZStack {
                    EdgeBlur(shape: shape)
                    shape.fill(tint.opacity(tintOpacity))
                }
            }
        }
        .allowsHitTesting(false)
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

/// The cards' chrome: dark glass, a 155° sheen, a white hairline, a lit top edge and a deep soft shadow.
private struct EdgeCardChrome: ViewModifier {
    let palette: DockPalette
    let radius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(
                ZStack {
                    EdgeGlassFill(shape: shape, tint: palette.baseDarkColor, tintOpacity: 0.8, flat: palette.baseDarkColor)
                    shape.fill(LinearGradient(stops: [
                        .init(color: .white.opacity(0.10), location: 0),
                        .init(color: .white.opacity(0.02), location: 0.4),
                        .init(color: .black.opacity(0.35), location: 1),
                    ], startPoint: EdgeDockArt.from155, endPoint: EdgeDockArt.to155))
                }
                .allowsHitTesting(false)
            )
            .clipShape(shape)
            .overlay(shape.edgeInnerLight(.white.opacity(0.22), x: 0, y: 1, blur: 0))
            .overlay(shape.strokeBorder(Color.white.opacity(0.15), lineWidth: 1).allowsHitTesting(false))
            // Mock: y 24, blur 56. Clamped to radius 22, 16 pt down so it stays inside `EdgePanelLayout.slack`.
            .background(EdgeOuterShadow(shape: shape, color: .black.opacity(0.65), radius: 22, y: 16))
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
        // Dark glass in light and dark mode alike.
        .environment(\.colorScheme, .dark)
        .animation(Motion.still ? nil : Motion.edgePalette, value: p)
    }
}

/// The halo ring the items sit on: an accent hairline, a soft accent glow outside it and a faint light line inside.
private struct EdgeHalo: View {
    let palette: DockPalette

    var body: some View {
        let r = EdgePanelLayout.ringRadius
        ZStack {
            // Mock: accent .16; raised so the glow reads on a bright desktop too.
            EdgeOuterShadow(shape: EdgeHalfDisc(radius: r), color: palette.accentColor.opacity(0.24), radius: 14, x: -8)
            EdgeHalfDisc(radius: r).stroke(palette.accentColor.opacity(0.35), lineWidth: 1)
            EdgeHalfDisc(radius: r - 1.5).stroke(palette.rimTintColor.opacity(0.22), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

/// The glass half-disc itself (drawn in a frame one radius wide, two high).
private struct EdgeDiscGlass: View {
    let palette: DockPalette

    var body: some View {
        let p = palette
        let disc = EdgeHalfDisc()
        let track = EdgeHalfDisc(radius: EdgePanelLayout.discRadius * 0.89)
        ZStack {
            EdgeOuterShadow(shape: disc, color: p.baseDarkColor.opacity(0.68), radius: 24, x: -18)
            EdgeGlassFill(shape: disc, tint: p.baseColor, tintOpacity: 0.65, flat: p.baseColor)
            disc.fill(LinearGradient(stops: [
                .init(color: p.baseLightColor.opacity(0.62), location: 0),
                .init(color: p.baseColor.opacity(0.72), location: 0.55),
                .init(color: p.accentColor.opacity(0.22), location: 1),
            ], startPoint: EdgeDockArt.from155, endPoint: EdgeDockArt.to155))
            // The inner track.
            track.fill(p.baseLightColor.opacity(0.3))
            track.stroke(p.rimTintColor.opacity(0.2), lineWidth: 1)
            // Rim light at the top left, the accent at the bottom, then the accent edge.
            disc.edgeInnerLight(p.rimTintColor.opacity(0.4), x: 1.5, y: 1.5, blur: 2, width: 3)
            disc.edgeInnerLight(p.accentColor.opacity(0.22), x: 0, y: -1, blur: 2)
            disc.stroke(p.accentColor.opacity(0.4), lineWidth: 1)
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
                .foregroundStyle(p.inkColor.opacity(0.7))
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
        Button(action: tap) {
            content(p, on: active || hovering)
                .frame(width: size, height: size)
                .background(Circle().fill(p.baseDarkColor.opacity(0.95)))
                .overlay(Circle().edgeInnerLight(.white.opacity(0.18), x: 0, y: 1, blur: 1))
                .overlay(Circle().strokeBorder(active ? p.accentColor : Color.white.opacity(hovering ? 0.5 : 0.25),
                                               lineWidth: active ? 1.5 : 1))
                .overlay(alignment: .topTrailing) { mark(p) }
                .contentShape(Circle())
                .background(Circle().fill(Color.black).shadow(color: .black.opacity(0.45), radius: 10, x: 0, y: 8)
                    .allowsHitTesting(false))
        }
        .buttonStyle(EdgePressStyle())
        .scaleEffect(lifted ? 1.08 : 1)
        .offset(y: hovering && !Motion.reduceMotion ? -2 : 0)
        .animation(Motion.still ? nil : Motion.edgeState, value: lifted)
        .animation(Motion.still ? nil : Motion.edgeState, value: hovering)
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
        Image(systemName: name)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(tint.opacity(on ? 1 : 0.9))
            .frame(width: inner, height: inner)
            .background(Circle().fill(tint.opacity(on ? 0.22 : 0.15)))
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
    let action: () -> Void
    @State private var angle: Double = 0
    @State private var since: Date?

    var body: some View {
        Button(action: action) {
            Group {
                if Motion.still || Motion.reduceMotion {
                    record
                } else {
                    TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !spinning)) { ctx in
                        record.rotationEffect(.degrees(current(at: ctx.date)))
                    }
                }
            }
            .contentShape(Circle())
        }
        .buttonStyle(EdgePressStyle())
        .onAppear { if spinning { since = Date() } }
        .onChange(of: spinning) { _, on in
            if on {
                since = Date()
            } else {
                angle = current(at: Date())
                since = nil
            }
        }
        .help(title)
        .accessibilityLabel("Now playing: \(title)")
    }

    private func current(at date: Date) -> Double {
        guard let since else { return angle }
        return angle + date.timeIntervalSince(since) * 360 / Motion.edgeSpinPeriod
    }

    /// The cover as a vinyl record: grooves, a soft specular light, a dark label with the title around the spindle.
    private var record: some View {
        let size = EdgePanelLayout.coverSize
        return ZStack {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else {
                palette.baseColor
                Image(systemName: "music.note").font(.system(size: 18)).foregroundStyle(palette.inkColor.opacity(0.7))
                    .offset(x: -size * 0.3)
            }
            EdgeGrooves(from: size * 0.23 + 2, to: size / 2 - 2, every: 3.5)
            RadialGradient(colors: [.white.opacity(0.16), .white.opacity(0)], center: UnitPoint(x: 0.3, y: 0.25),
                           startRadius: 0, endRadius: size * 0.45)
            // The label, the title around the spindle, the spindle and its dot.
            Circle().fill(palette.baseDarkColor.opacity(0.82)).frame(width: size * 0.46, height: size * 0.46)
                .overlay(Circle().strokeBorder(Color.black.opacity(0.4), lineWidth: 0.5))
            EdgeRecordTitle(text: title, radius: size * 0.165, ink: palette.inkColor)
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

/// The song title in capitals around the spindle, one letter at a time, centred on the record's left (the visible half).
private struct EdgeRecordTitle: View {
    let text: String
    let radius: CGFloat
    let ink: Color
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
            let step = Double(Self.advance / radius)
            let start = Double.pi - step * Double(letters.count - 1) / 2
            for (i, ch) in letters.enumerated() {
                let phi = start + step * Double(i)
                var g = ctx
                g.translateBy(x: c.x + radius * cos(phi), y: c.y + radius * sin(phi))
                g.rotate(by: .radians(phi + .pi / 2))
                g.draw(Text(String(ch)).font(.geistMono(6, .medium)).foregroundColor(ink.opacity(0.9)),
                       at: .zero, anchor: .center)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Three thin rings with a gentle wobble around the record (static).
private struct EdgeWaves: View {
    let palette: DockPalette

    var body: some View {
        let o = EdgeDockArt.orbRadius
        ZStack {
            EdgeWave(radius: o * 0.84, amplitude: 1.6, lobes: 7, phase: 0)
                .stroke(palette.accentColor.opacity(0.85), lineWidth: 1.5)
            EdgeWave(radius: o * 0.74, amplitude: 1.4, lobes: 9, phase: 1.3)
                .stroke(palette.rimTintColor.opacity(0.8), lineWidth: 1.25)
            EdgeWave(radius: o * 0.64, amplitude: 1.2, lobes: 11, phase: 2.6)
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
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
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
                .foregroundStyle(palette.inkColor.opacity(active || hovering ? 1 : 0.85))
                .frame(width: size, height: size)
                .background(Circle().fill(Color.white.opacity(hovering ? 0.22 : 0.15)))
                .overlay(Circle().edgeInnerLight(.white.opacity(0.2), x: 0, y: 1, blur: 1))
                .overlay(Circle().strokeBorder(active ? palette.accentColor : Color.white.opacity(0.25), lineWidth: active ? 1.5 : 1))
                .background(Circle().fill(Color.black.opacity(0.3)).shadow(color: .black.opacity(0.35), radius: 5, x: 0, y: 3)
                    .allowsHitTesting(false))
                .contentShape(Circle())
        }
        .buttonStyle(EdgePressStyle())
        .animation(Motion.still ? nil : Motion.edgeState, value: hovering)
        .edgeHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
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
                .foregroundStyle(palette.inkColor.opacity(0.6))
            if Motion.still {
                // The pictures: a live text field can't be drawn headlessly, so the query as text.
                Text(model.query.isEmpty ? "Search apps" : model.query)
                    .foregroundStyle(palette.inkColor.opacity(model.query.isEmpty ? 0.45 : 1))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField("", text: $model.query, prompt: Text("Search apps").foregroundColor(palette.inkColor.opacity(0.45)))
                    .textFieldStyle(.plain)
                    .foregroundStyle(palette.inkColor)
                    .focused($focused)
                    .onSubmit { model.submitSearch() }
                    .accessibilityLabel("Search apps")
            }
        }
        .font(.geist(11, .medium))
        .lineLimit(1)
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity, maxHeight: .infinity) // the capsule fills the field's frame
        .background(Capsule().fill(palette.baseDarkColor.opacity(0.85)))
        .background(Capsule().fill(Color.white.opacity(0.08)))
        .overlay(Capsule().edgeInnerLight(.white.opacity(0.2), x: 0, y: 1, blur: 1))
        .overlay(Capsule().strokeBorder(palette.accentColor.opacity(0.6), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 5, x: 0, y: 3)
        // After the panel has become key (the controller does that as search opens).
        .onAppear { DispatchQueue.main.async { focused = true } }
    }
}

// MARK: - Cards

/// The Spotify card: the song with previous / play-pause / next, or one plain line.
struct EdgeSpotifyCard: View {
    @ObservedObject var model: EdgePanelModel

    var body: some View {
        switch model.spotify.state {
        case .track(let t): track(t)
        case .denied: line("Allow Merlin to control Spotify in System Settings › Privacy & Security › Automation.")
        case .notRunning: line("Spotify is not open.")
        case .stopped: line("Nothing is playing.")
        }
    }

    private func track(_ t: SpotifyTrack) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Group {
                    if let cover = model.spotify.cover {
                        Image(nsImage: cover).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                    } else {
                        Theme.surfaceRaised.color
                            .overlay(Image(systemName: "music.note").foregroundStyle(Theme.inkTertiary.color))
                    }
                }
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.title).font(.geist(13, .semibold)).foregroundStyle(Theme.ink.color).lineLimit(1)
                    Text(t.artist).font(.geist(12)).foregroundStyle(Theme.inkSecondary.color).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 20) {
                EdgeMusicButton(symbol: "backward.fill", help: "Previous") { model.tapSpotifyCommand(.previous) }
                EdgeMusicButton(symbol: t.isPlaying ? "pause.fill" : "play.fill", help: t.isPlaying ? "Pause" : "Play",
                                prominent: model.palette) { model.tapSpotifyCommand(.playPause) }
                EdgeMusicButton(symbol: "forward.fill", help: "Next") { model.tapSpotifyCommand(.next) }
            }
            .frame(height: 36)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func line(_ text: String) -> some View {
        Text(text).font(.geist(13)).foregroundStyle(Theme.inkSecondary.color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
    }
}

/// A round music button. The play-pause one is filled with the dock's accent.
private struct EdgeMusicButton: View {
    let symbol: String
    let help: String
    var prominent: DockPalette?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let size: CGFloat = prominent == nil ? 32 : 36
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: prominent == nil ? 12 : 14, weight: .semibold))
                .foregroundStyle(prominent.map { $0.baseDarkColor } ?? (hovering ? Theme.ink.color : Theme.inkSecondary.color))
                .frame(width: size, height: size)
                // Round glass: white 10% with a white 20% edge; play-pause filled with the accent.
                .background(Circle().fill(prominent.map { $0.accentColor } ?? Color.white.opacity(hovering ? 0.16 : 0.10)))
                .overlay(Circle().strokeBorder(Color.white.opacity(prominent == nil ? 0.20 : 0.28), lineWidth: 1))
                .overlay(Circle().edgeInnerLight(.white.opacity(0.22), x: 0, y: 1, blur: 1))
                .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)
                .contentShape(Circle())
        }
        .buttonStyle(EdgePressStyle(scale: 0.92))
        .edgeHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The add/remove card: the pinned apps first, then every other installed app, each with Add or Remove. No text field (the
/// panel takes the keyboard only for the disc's search).
struct EdgeAppsCard: View {
    @ObservedObject var model: EdgePanelModel
    /// View state only (nothing is saved).
    @State private var filter: Filter = .all

    enum Filter: CaseIterable { case all, inRotation, available
        var title: String {
            switch self {
            case .all: return "All"
            case .inRotation: return "In Rotation"
            case .available: return "Available"
            }
        }
    }

    private static let titleHeight: CGFloat = 40
    private static let filterHeight: CGFloat = 42
    private static let footerHeight: CGFloat = 40
    /// What is left of the fixed card for the list.
    private static var listHeight: CGFloat {
        EdgePanelLayout.appsSize.height - titleHeight - 1 - filterHeight - 1 - footerHeight
    }

    var body: some View {
        let p = model.palette
        VStack(spacing: 0) {
            titleBar(p)
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
            filterBar
            list(p)
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
            footer(p)
        }
    }

    private func close() { model.toggle(.apps) }

    private func titleBar(_ p: DockPalette) -> some View {
        ZStack {
            Text("App Customization").font(.geist(13, .semibold)).foregroundStyle(Theme.ink.color)
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

    private var filterBar: some View {
        HStack(spacing: 2) {
            ForEach(Filter.allCases, id: \.self) { f in
                Button { filter = f } label: {
                    Text(f.title)
                        .font(.geist(11, .medium))
                        .foregroundStyle(filter == f ? Theme.ink.color : Theme.inkSecondary.color)
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                        .background(Capsule().fill(filter == f ? Color.white.opacity(0.12) : .clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(EdgePressStyle())
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.05)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        .padding(.horizontal, 10)
        .frame(height: Self.filterHeight)
    }

    private var available: [DockApp] { model.manageRows.filter { !model.apps.isPinned($0.bundleID) } }

    @ViewBuilder private func list(_ p: DockPalette) -> some View {
        let content = VStack(spacing: 4) {
            if filter != .available {
                header("In rotation", model.apps.pinned.count)
                ForEach(model.apps.pinned) { row($0, p) }
            }
            if filter != .inRotation {
                header("Available to add", available.count)
                if model.apps.installed.isEmpty {
                    EdgeQuietLine(text: "Looking for apps…")
                } else {
                    ForEach(available) { row($0, p) }
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
        .foregroundStyle(Theme.inkTertiary.color)
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
            Text("\(model.apps.pinned.count) in rotation").font(.geistMono(11)).foregroundStyle(Theme.inkSecondary.color)
            Spacer()
            Button(action: close) {
                Text("Done")
                    .font(.geist(12, .semibold))
                    .foregroundStyle(p.baseDarkColor)
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
                    Image(systemName: "app").font(.system(size: 12)).foregroundStyle(palette.rimTintColor)
                }
            }
            .frame(width: 32, height: 32)
            .background(Circle().fill(palette.rimColor.opacity(0.18)))
            .overlay(Circle().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
            Text(app.name).font(.geist(12, .medium)).foregroundStyle(Theme.ink.color).lineLimit(1)
            Spacer(minLength: 8)
            Button(action: action) {
                Text(pinned ? "Remove" : "Add")
                    .font(.geist(11, .semibold))
                    .foregroundStyle(pinned ? Color(red: 1, green: 0.48, blue: 0.46) : palette.baseDarkColor)
                    .padding(.horizontal, 10)
                    .frame(height: 22)
                    .background(Capsule().fill(pinned ? Color(red: 0.6, green: 0.12, blue: 0.12).opacity(0.4) : palette.accentColor))
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
        .background(shape.fill(Color.white.opacity(hovering ? 0.09 : 0.05)))
        .overlay(shape.strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
        .edgeHover { h in withAnimation(Motion.still ? nil : Motion.animation(Motion.small)) { hovering = h } }
    }
}
