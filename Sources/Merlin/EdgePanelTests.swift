import AppKit
import SwiftUI

/// A stand-in chat for the row wiring: it counts what the edge panel's star and × did to it.
private final class FakeRowTarget: EdgeRowTarget {
    var closedFromUser = 0
    var stars = 0
    func closeFromUser() { closedFromUser += 1 }
    func toggleStar() { stars += 1 }
}

extension FeatureTests {
    /// The hidden edge panel (R3): when it shows and hides, where its hot zone is, what it does when nothing may show it,
    /// the dot, the rows' wiring into the dock (the × must reach `closeFromUser`), and the Notes list order. The last part
    /// sends real mouse events to the real panel in a window that's ordered in invisible and click-through (skipped by
    /// MERLIN_HEADLESS_TESTS=1).
    @MainActor
    static func edgePanelChecks(_ check: (String, Bool) -> Void) {
        // When it shows.
        var r = EdgeReveal()
        check("edge: not shown before 120 ms in the zone", r.update(inZone: true, overPanel: false, blocked: false, now: 10) == .none
              && r.update(inZone: true, overPanel: false, blocked: false, now: 10.11) == .none && !r.visible)
        check("edge: shown after 120 ms in the zone", r.update(inZone: true, overPanel: false, blocked: false, now: 10.13) == .show && r.visible)

        r = EdgeReveal()
        _ = r.update(inZone: true, overPanel: false, blocked: false, now: 0)
        _ = r.update(inZone: false, overPanel: false, blocked: false, now: 0.05)
        _ = r.update(inZone: true, overPanel: false, blocked: false, now: 0.10)
        check("edge: leaving the zone before 120 ms cancels (the wait starts again)",
              r.update(inZone: true, overPanel: false, blocked: false, now: 0.17) == .none
              && r.update(inZone: true, overPanel: false, blocked: false, now: 0.23) == .show)

        // When it hides.
        check("edge: on the panel it stays", r.update(inZone: false, overPanel: true, blocked: false, now: 5) == .none && r.visible)
        _ = r.update(inZone: false, overPanel: false, blocked: false, now: 6)
        check("edge: not hidden before 400 ms away", r.update(inZone: false, overPanel: false, blocked: false, now: 6.39) == .none && r.visible)
        check("edge: hidden after 400 ms away", r.update(inZone: false, overPanel: false, blocked: false, now: 6.41) == .hide && !r.visible)
        _ = r.update(inZone: true, overPanel: false, blocked: false, now: 7)
        _ = r.update(inZone: true, overPanel: false, blocked: false, now: 7.2)
        _ = r.update(inZone: false, overPanel: false, blocked: false, now: 7.3)
        check("edge: coming back to the panel within 400 ms keeps it",
              r.update(inZone: false, overPanel: true, blocked: false, now: 7.6) == .none
              && r.update(inZone: false, overPanel: false, blocked: false, now: 7.65) == .none
              && r.update(inZone: false, overPanel: false, blocked: false, now: 7.9) == .none && r.visible)

        var pin = EdgeReveal()
        check("edge: the shortcut shows it at once, pinned", pin.showPinned() == .show && pin.visible && pin.pinned)
        _ = pin.update(inZone: false, overPanel: false, blocked: false, now: 1)
        check("edge: pinned, it stays with the pointer away", pin.update(inZone: false, overPanel: false, blocked: false, now: 30) == .none && pin.visible)
        check("edge: Esc hides it at once (pinned too)", pin.escape() == .hide && !pin.visible && !pin.pinned)
        check("edge: after Esc, resting in the zone doesn't bring it back...",
              pin.update(inZone: true, overPanel: false, blocked: false, now: 40) == .none
              && pin.update(inZone: true, overPanel: false, blocked: false, now: 41) == .none)
        _ = pin.update(inZone: false, overPanel: false, blocked: false, now: 42)
        _ = pin.update(inZone: true, overPanel: false, blocked: false, now: 43)
        check("edge: ...until the pointer leaves and comes back", pin.update(inZone: true, overPanel: false, blocked: false, now: 43.2) == .show)
        check("edge: a click outside hides it", pin.clickOutside() == .hide && !pin.visible)
        check("edge: after Esc with the pointer still in the zone, the pointer stays watched (so leaving is seen)", pin.isWatching)
        _ = pin.update(inZone: false, overPanel: false, blocked: false, now: 50)
        check("edge: ...and once it has left, nothing is watched", !pin.isWatching)

        var snip = EdgeReveal()
        _ = snip.showPinned()
        check("edge: a snip or point to ask starting while it shows hides it at once",
              snip.update(inZone: false, overPanel: true, blocked: false, interrupted: true, now: 1) == .hide && !snip.visible)
        check("edge: the shortcut can't show it during a snip or point to ask", snip.showPinned(interrupted: true) == .none && !snip.visible)
        var press = EdgeReveal()
        _ = press.showPinned()
        check("edge: a mouse button down on the panel (a row click) doesn't hide it",
              press.update(inZone: false, overPanel: true, blocked: true, now: 1) == .none && press.visible)

        var menu = EdgeReveal()
        _ = menu.update(inZone: true, overPanel: false, blocked: false, now: 0)
        _ = menu.update(inZone: true, overPanel: false, blocked: false, now: 0.2)
        menu.menuOpen = true
        _ = menu.update(inZone: false, overPanel: false, blocked: false, now: 1)
        check("edge: it stays while a row's menu is open", menu.update(inZone: false, overPanel: false, blocked: false, now: 5) == .none && menu.visible)
        menu.menuOpen = false
        _ = menu.update(inZone: false, overPanel: false, blocked: false, now: 6)
        check("edge: ...and leaves 400 ms after the menu closes", menu.update(inZone: false, overPanel: false, blocked: false, now: 6.5) == .hide)

        // Nothing shows it during a drag, a snip or point to ask. A full-screen front app no longer blocks (changed on purpose).
        for (name, b) in [("a drag (mouse button down)", EdgeBlock.blocked(mouseButtonsDown: 1, snipping: false, pointing: false)),
                          ("a snip", EdgeBlock.blocked(mouseButtonsDown: 0, snipping: true, pointing: false)),
                          ("point to ask", EdgeBlock.blocked(mouseButtonsDown: 0, snipping: false, pointing: true))] {
            var x = EdgeReveal()
            _ = x.update(inZone: true, overPanel: false, blocked: b, now: 0)
            let stays = x.update(inZone: true, overPanel: false, blocked: b, now: 2) == .none && !x.visible
            check("edge: no panel during \(name)", b && stays)
        }
        check("edge: nothing blocking, nothing blocks", !EdgeBlock.blocked(mouseButtonsDown: 0, snipping: false, pointing: false))
        var drag = EdgeReveal()
        _ = drag.update(inZone: true, overPanel: false, blocked: true, now: 0)
        _ = drag.update(inZone: true, overPanel: false, blocked: false, now: 0.5)
        check("edge: after the drag ends, the 120 ms wait starts then (no instant pop)",
              drag.update(inZone: true, overPanel: false, blocked: false, now: 0.55) == .none
              && drag.update(inZone: true, overPanel: false, blocked: false, now: 0.63) == .show)

        // Where the hot zone is.
        let laptop = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let z = EdgeGeometry.zone(for: NSPoint(x: 700, y: 450), screens: [laptop])
        check("edge zone: 6 pt wide at the right edge, 160 pt tall, centred", z == NSRect(x: 1434, y: 370, width: 6, height: 160))
        check("edge zone: the pointer at the edge's middle is in it; above it or 10 pt in is not",
              EdgeGeometry.inZone(NSPoint(x: 1439, y: 450), screens: [laptop]) && !EdgeGeometry.inZone(NSPoint(x: 1439, y: 600), screens: [laptop])
              && !EdgeGeometry.inZone(NSPoint(x: 1430, y: 450), screens: [laptop]))
        let external = NSRect(x: 1440, y: 0, width: 1920, height: 1080)
        let two = [laptop, external]
        check("edge zone (two screens): on the screen with the pointer",
              EdgeGeometry.zone(for: NSPoint(x: 2000, y: 300), screens: two) == NSRect(x: 3354, y: 460, width: 6, height: 160)
              && EdgeGeometry.inZone(NSPoint(x: 3359, y: 540), screens: two))
        check("edge zone (two screens): none on the seam where the pointer crosses to the other screen",
              EdgeGeometry.zone(for: NSPoint(x: 700, y: 450), screens: two) == nil && !EdgeGeometry.inZone(NSPoint(x: 1439, y: 450), screens: two))
        let above = NSRect(x: 0, y: 900, width: 1920, height: 1080)
        check("edge zone (a screen above): each has its own zone, centred on its own height",
              EdgeGeometry.zone(for: NSPoint(x: 100, y: 1500), screens: [laptop, above]) == NSRect(x: 1914, y: 1360, width: 6, height: 160)
              && EdgeGeometry.zone(for: NSPoint(x: 100, y: 100), screens: [laptop, above]) == NSRect(x: 1434, y: 370, width: 6, height: 160))
        check("edge zone: the event tap's copy is flipped to a top-left origin",
              EdgeGeometry.tapZones(screens: [laptop]) == [CGRect(x: 1434, y: 370, width: 6, height: 160)]
              && EdgeGeometry.tapZones(screens: [laptop, above]).contains(CGRect(x: 1914, y: -620, width: 6, height: 160)))
        let cache = EdgeZoneCache()
        cache.set(EdgeGeometry.tapZones(screens: [laptop]))
        check("edge zone: the tap tells the app once on entry, not on every move",
              cache.hit(CGPoint(x: 1438, y: 450)) && !cache.hit(CGPoint(x: 1438, y: 451)) && !cache.hit(CGPoint(x: 100, y: 100)))
        cache.rearm()
        check("edge zone: ...and again after the app is done watching", cache.hit(CGPoint(x: 1438, y: 450)))

        // The dot.
        check("edge dot: breathing while any chat works", EdgeDotState.from([(.done, false), (.working, true)]) == .breathing)
        check("edge dot: solid when an answer is ready and not read", EdgeDotState.from([(.done, false), (.idle, false)]) == .solid)
        check("edge dot: absent once the answer is open on screen, or with nothing going on",
              EdgeDotState.from([(.done, true)]) == .absent && EdgeDotState.from([(.idle, false), (.failed, false)]) == .absent
              && EdgeDotState.from([]) == .absent)
        check("edge dot: the setting is on by default", Settings(defaults: UserDefaults(suiteName: "merlin.edge.\(UUID().uuidString)")!).edgeDot)

        // The dock's system parts are fakes in every check below: no live Spotify, no real defaults, nothing launched.
        let (fixtureDefaults, fixtureName) = EdgeDockFixtures.defaults()
        defer { EdgeDockFixtures.forget(fixtureName) }
        let workspace = FixtureDockWorkspace()
        let store = EdgeDockFixtures.appStore(workspace, defaults: fixtureDefaults)
        let quiet = SpotifyService(backend: FixtureSpotifyBackend(.notRunning), loader: FixtureImageLoader(image: nil))

        // The rows' wiring: panel → dock → chat. No window, no real chat.
        let edge = EdgePanelController(apps: store, spotify: quiet)
        let dock = AgentDock(edge: edge)
        var routed: [(AgentDock.RowAction, ObjectIdentifier)] = []
        dock.debugRouted = { routed.append(($0, $1)) }
        let token = NSObject()
        let id = ObjectIdentifier(token)
        edge.sync([.init(id: id, title: "Supply shift effects", subtitle: "Done · click to read", phase: .done, isOpen: false, canStar: true)])
        edge.debugClickDelete(0)
        check("edge rows: the × on a row reaches the dock as a delete for that chat",
              routed.count == 1 && routed.first?.0 == .delete && routed.first?.1 == id)
        edge.debugClickStar(0)
        check("edge rows: the star reaches the dock as a star", routed.count == 2 && routed.last?.0 == .star)
        let fake = FakeRowTarget()
        AgentDock.route(.delete, to: fake)
        check("edge rows: the dock's delete is closeFromUser (so \"Delete chat when I close it\" applies)", fake.closedFromUser == 1 && fake.stars == 0)
        AgentDock.route(.star, to: fake)
        check("edge rows: the dock's star toggles the star and closes nothing", fake.stars == 1 && fake.closedFromUser == 1)
        check("edge rows: a row click is wired to open the chat", edge.onOpenChat != nil)
        check("edge rows: a done chat put away shows a solid dot", edge.debugDotState == .solid)
        check("edge: a new panel puts nothing on screen", !edge.debugWindowIsOrderedIn && edge.debugWindow == nil)
        withExtendedLifetime(token) {}

        // Sizes: the dock, then a card beside it.
        let m = EdgePanelModel(apps: store, spotify: quiet)
        check("edge sizes: stage one is the dock (disc, ring and items)", m.cardSize == EdgePanelLayout.boxSize
              && EdgePanelLayout.boxSize == EdgePanelLayout.dockSize)
        m.chats = (0..<3).map { _ in .init(id: ObjectIdentifier(token), title: "t", subtitle: "s", phase: .idle, isOpen: false) }
        m.choose(.chats)
        check("edge sizes: choosing Chats opens the list card", m.section == .chats && m.cardSize.width > EdgePanelLayout.boxSize.width
              && m.cardSize.height == EdgePanelLayout.listSize(rows: 3, newNoteRow: false).height)
        check("edge sizes: an empty list keeps room for its one quiet line; past 8 rows it scrolls",
              EdgePanelLayout.listSize(rows: 0, newNoteRow: false).height == EdgePanelLayout.headerHeight + EdgePanelLayout.pad * 2 + EdgePanelLayout.lineHeight
              && EdgePanelLayout.listSize(rows: 30, newNoteRow: false) == EdgePanelLayout.listSize(rows: EdgePanelLayout.maxRows, newNoteRow: false))
        check("edge motion: the row stagger is 30 ms and the last row starts within 0.12 s",
              abs(Motion.edgeStagger(1) - 0.03) < 0.0001 && Motion.edgeStagger(9) <= 0.12)

        // The Notes list: sheets, most recently changed first.
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("merlin-edge-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: dir) }
        let library = Library(directory: dir)
        let a = library.createSheet(named: "Microeconomics terms")
        let b = library.createSheet(named: "Physics forces")
        let c = library.createSheet(named: "Macro essay plan")
        if let a, let b {
            _ = library.appendToSheet(b.id, "| Force | Unit |\n|---|---|\n| Weight | N |", date: Date().addingTimeInterval(100))
            _ = library.appendToSheet(a.id, "A line.", date: Date().addingTimeInterval(200))
        }
        let rows = EdgePanelModel.noteRows(library.sheets, now: Date().addingTimeInterval(300))
        check("edge notes: the list shows sheets, most recently changed first",
              c != nil && rows.map(\.title) == ["Microeconomics terms", "Physics forces", "Macro essay plan"])
        edge.refreshNotes(library: library)
        check("edge notes: the panel takes that list", edge.model.notes.map(\.title) == rows.map(\.title))
        var opened: [UUID] = [], made = 0
        edge.openNote = { opened.append($0) }
        edge.newNote = { made += 1 }
        edge.model.tapNote(rows[0].id)
        edge.model.tapNewNote()
        check("edge notes: a sheet row opens that sheet; New note asks for a new one", opened == [rows[0].id] && made == 1)

        dockChecks(check, store: store, workspace: workspace)
        windowedEdgePanelChecks(check)
        windowedGlassStateChecks(check)
    }

    /// The dock (version 1): the ring's geometry, the cards' sizes, the app items, the Spotify card and the add/remove cap.
    /// Headless, on fakes only.
    @MainActor
    private static func dockChecks(_ check: (String, Bool) -> Void, store: DockAppStore, workspace: FixtureDockWorkspace) {
        typealias L = EdgePanelLayout
        // Geometry: the numbers.
        check("edge dock: a 110 pt disc, a 144 pt ring, 44 pt items 22° apart", L.discRadius == 110 && L.ringRadius == 144
              && L.itemSize == 44 && L.itemStep == 22 && L.maxItems == 8)
        check("edge dock: the ring is the disc + a 12 pt gap + half an item", L.ringGap == 12
              && L.ringRadius == L.discRadius + L.ringGap + L.itemSize / 2)
        check("edge dock: an app icon is 40 pt inside a 44 pt target", L.appIconSize == 40 && L.itemSize == 44)
        check("edge dock: the card sits beside the ring's items (ring + half an item + 8 pt)", L.listInset == 144 + 22 + 8)
        check("edge dock: the dock is the ring and its lifted items, flush right", L.dockSize == CGSize(width: 166, height: 334))
        check("edge dock: the window holds the card and the dock", L.windowSize == CGSize(width: 284 + 174 + 56, height: 481 + 112))
        // The angle step: wide enough for 8 pt between neighbours' edges, narrow enough that 8 items stay on screen.
        let chord = 2 * L.ringRadius * sin(L.itemStep / 2 * .pi / 180)
        let leastStep = 2 * asin((L.itemSize + L.minItemGap) / (2 * L.ringRadius)) * 180 / .pi
        check("edge dock: the step keeps at least 8 pt between neighbours' edges (least \(String(format: "%.1f", leastStep))°)",
              chord - L.itemSize >= L.minItemGap && L.itemStep >= leastStep)
        check("edge dock: the glass blends only below the least rest gap", L.glassBlend > 0 && L.glassBlend < L.minItemGap)
        // The card's shadow (radius 22, 16 pt down: about 60 pt below, 44 pt to the sides) stays inside the window.
        check("edge dock: the slack holds the card's shadow", L.slack == 56 && L.slack >= 16 + 22 * 1.8 && L.slack >= 22 * 2)

        // Item centres for 2 and 8 items: no overlap, inside the window, Chats first and on top, centred on the axis.
        let local = NSRect(origin: .zero, size: L.windowSize)
        let wide = NSRect(x: 0, y: 0, width: 1440, height: 875)
        let wideWindow = L.windowFrame(screen: wide)
        for n in 2...8 {
            let c = L.itemCentres(count: n)
            let r = L.itemSize / 2, lr = r * L.liftScale
            var apart = true
            for i in 0..<n { for j in (i + 1)..<n where hypot(c[i].x - c[j].x, c[i].y - c[j].y) < L.itemSize * L.liftScale + 2 { apart = false } }
            check("edge dock (\(n) items): no two items overlap, even lifted to 1.08", apart)
            // Lifted (1.08, 2 pt up), every item stays inside the dock: never cut by the window, nor by the screen edge
            // (the dock's right side) at the top or the bottom of the ring.
            let inDock = c.allSatisfy { $0.x - r >= 0 && $0.x + lr <= L.dockSize.width && $0.y - lr - L.liftRise >= 0 && $0.y + lr <= L.dockSize.height }
            let inWindow = (0..<n).allSatisfy { i in
                let p = L.itemCentre(i, of: n, window: local)
                return local.contains(NSRect(x: p.x - lr, y: p.y - lr, width: lr * 2, height: lr * 2 + L.liftRise))
            }
            check("edge dock (\(n) items): every item is inside the dock and the window, lifted too", inDock && inWindow)
            // The pointer's path from the screen edge to every item stays in the hover frame (with and without a card).
            let pathInside = [nil, L.listSize(rows: 3, newNoteRow: false)].allSatisfy { card -> Bool in
                let hover = L.hoverFrame(window: wideWindow, card: card)
                return (0..<n).allSatisfy { i in
                    let p = L.itemCentre(i, of: n, window: wideWindow)
                    let lifted = NSRect(x: p.x - lr, y: p.y - lr, width: lr * 2, height: lr * 2 + L.liftRise)
                    return hover.contains(lifted) && hover.contains(NSRect(x: p.x, y: p.y - 0.5, width: wide.maxX - p.x, height: 1))
                        && hover.maxX == wide.maxX
                }
            }
            check("edge dock (\(n) items): the path from the screen edge to every item stays in the hover frame", pathInside)
            let edgeGaps = (1..<n).map { hypot(c[$0].x - c[$0 - 1].x, c[$0].y - c[$0 - 1].y) - L.itemSize }
            check("edge dock (\(n) items): at least 8 pt between neighbours' edges", edgeGaps.allSatisfy { $0 >= L.minItemGap })
            let mid = CGPoint(x: L.dockSize.width, y: L.dockSize.height / 2)
            check("edge dock (\(n) items): 12 pt from the disc's rim to every item's edge",
                  c.allSatisfy { abs(hypot(mid.x - $0.x, mid.y - $0.y) - r - L.discRadius - L.ringGap) < 0.001 })
            let ys = c.map(\.y)
            check("edge dock (\(n) items): Chats is first and on top; the items go down in order", ys == ys.sorted() && ys[0] < L.dockSize.height / 2)
            check("edge dock (\(n) items): spread evenly around the horizontal axis on the ring",
                  abs((ys.first! + ys.last!) / 2 - L.dockSize.height / 2) < 0.01
                  && c.allSatisfy { abs(hypot(L.dockSize.width - $0.x, L.dockSize.height / 2 - $0.y) - L.ringRadius) < 0.01 })
            check("edge dock (\(n) items): every item is outside the disc",
                  c.allSatisfy { hypot(L.dockSize.width - $0.x, L.dockSize.height / 2 - $0.y) - r > L.discRadius })
        }
        let chats = L.itemCentre(.chats, window: local), notes = L.itemCentre(.notes, window: local)
        check("edge dock: in window coordinates (y up) Chats is above Notes", chats.y > notes.y && abs(chats.x - notes.x) < 0.01)
        let cover = L.coverCentre, mid = CGPoint(x: L.dockSize.width, y: L.dockSize.height / 2)
        // The disc's three buttons ("+", search, collapse): one column, equal gaps, centred on the disc's middle.
        let buttons = [L.plusCentre, L.searchCentre, L.collapseCentre]
        let waves = EdgeDockArt.orbRadius * 0.84 + 2
        let inDisc = buttons.allSatisfy { b in hypot(b.x - mid.x, b.y - mid.y) + L.plusSize / 2 <= L.discRadius - 8 }
        let clearOfWaves = buttons.allSatisfy { b in hypot(b.x - cover.x, b.y - cover.y) - L.plusSize / 2 > waves }
        check("edge dock: \"+\", search and collapse are inside the disc (8 pt margin), clear of the record and its waves",
              inDisc && clearOfWaves && EdgeDockArt.orbRadius * 0.64 > L.coverSize / 2)
        let sameX = buttons.allSatisfy { abs($0.x - buttons[0].x) < 0.001 }
        let gap1 = buttons[1].y - buttons[0].y, gap2 = buttons[2].y - buttons[1].y
        check("edge dock: the three buttons share one x, 12 pt between their edges, centred on the disc",
              sameX && abs(gap1 - L.plusSize - 12) < 0.001 && abs(gap1 - gap2) < 0.001 && abs(buttons[1].y - mid.y) < 0.001)
        let rimGaps = buttons.map { L.discRadius - hypot($0.x - mid.x, $0.y - mid.y) - L.plusSize / 2 }
        check("edge dock: 14 pt from the disc's rim to the nearest button edge",
              abs(rimGaps.min()! - 14) < 0.001 && L.discButtonRim == 14)
        let field = L.searchFieldFrame
        let fieldCorners = [CGPoint(x: field.minX, y: field.minY), CGPoint(x: field.minX, y: field.maxY)]
        check("edge dock: the search field sits in the search button's row, inside the disc",
              abs(field.midY - L.searchCentre.y) < 0.001 && field.maxX < L.dockSize.width
              && fieldCorners.allSatisfy { hypot($0.x - mid.x, $0.y - mid.y) <= L.discRadius - 4 })

        // Text on the glass is the system's job now (hierarchical styles on clear `Glass.regular`): no model can measure it,
        // only `--edgeglasscheck` on a real screen. What stays pure: the flat path's ink on its solid base, and the record
        // title on its band, for every base `DockPalette` makes (emerald, the grey cover's, every hue at 0.4 to 0.6).
        let white = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1), black = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        var palettes: [(base: NSColor, ink: NSColor)] = [(DockPalette.emerald.base, DockPalette.emerald.ink),
            (NSColor(hue: 0, saturation: 0, brightness: 0.15, alpha: 1), NSColor(hue: 0, saturation: 0, brightness: 0.97, alpha: 1))]
        for h in 0..<12 { for s in [0.4, 0.6] {
            let hue = CGFloat(h) / 12
            palettes.append((NSColor(hue: hue, saturation: CGFloat(s), brightness: 0.16, alpha: 1),
                             NSColor(hue: hue, saturation: 0.04, brightness: 0.98, alpha: 1)))
        } }
        // The flat path: the palette ink and the cards' light secondary ink on the solid base (dock) and its dark (cards).
        let flatWorst = palettes.map { DockPalette.contrast($0.ink, $0.base) }.min()!
        // `.secondary` on the flat path is the dark appearance's secondary label colour (white at part alpha) over the card.
        var secondary = NSColor.white, secondaryAlpha: CGFloat = 1
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            let c = NSColor.secondaryLabelColor.usingColorSpace(.sRGB) ?? .white
            secondary = NSColor(srgbRed: c.redComponent, green: c.greenComponent, blue: c.blueComponent, alpha: 1)
            secondaryAlpha = c.alphaComponent
        }
        let flatCardWorst = palettes.map { p in
            let card = (p.base.usingColorSpace(.sRGB) ?? p.base).blended(withFraction: 0.55, of: .black) ?? p.base
            return DockPalette.contrast(EdgeGlass.over(secondary, secondaryAlpha, card), card) }.min()!
        check("edge glass: only a light tint, no dim (the glass is clear)", EdgeGlass.tint <= 0.2)
        // The mini player's record title (ink at 0.9) on its dark band over the brightest cover (white).
        let bandWorst = palettes.map { p in
            DockPalette.contrast(EdgeGlass.over(p.ink, 0.9, EdgeGlass.over(black, EdgeDockArt.titleBand, white)),
                                 EdgeGlass.over(black, EdgeDockArt.titleBand, white)) }.min()!
        check("edge spotify: the record title keeps 4.5:1 on its band over a white cover (worst \(String(format: "%.2f", bandWorst)))",
              bandWorst >= 4.5)
        check("edge flat: the palette ink keeps 4.5:1 on the solid base (worst \(String(format: "%.2f", flatWorst)))",
              flatWorst >= DockPalette.minInkContrast)
        check("edge flat: the cards' .secondary text keeps 4.5:1 on the dark base (worst \(String(format: "%.2f", flatCardWorst)))",
              flatCardWorst >= DockPalette.minInkContrast)

        // The ring: the same distance between every two neighbours, for 2 to 9 items (the cap is 8; 9 checks the rule).
        for n in 2...9 {
            let c = L.itemCentres(count: n)
            let d = (1..<n).map { hypot(c[$0].x - c[$0 - 1].x, c[$0].y - c[$0 - 1].y) }
            check("edge dock (\(n) items): every two neighbours are the same distance apart",
                  d.allSatisfy { abs($0 - d[0]) < 0.001 } && abs((c.first!.y + c.last!.y) / 2 - L.dockSize.height / 2) < 0.001)
        }
        let middle = L.itemCentre(0, of: 1)
        check("edge dock: one item sits at the ring's middle-left point",
              abs(middle.x - (L.dockSize.width - L.ringRadius)) < 0.001 && abs(middle.y - L.dockSize.height / 2) < 0.001)
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 875)
        let w = L.windowFrame(screen: screen)
        let dock = L.dockFrame(window: w)
        check("edge dock: the dock frame holds the disc and the outermost item, lifted",
              dock.contains(L.discFrame(window: w)) && dock.minX == w.maxX - L.ringRadius - L.itemSize / 2)

        // Cards: the same slot for every section.
        let (d, name) = EdgeDockFixtures.defaults()
        defer { EdgeDockFixtures.forget(name) }
        let ws = FixtureDockWorkspace()
        let apps = EdgeDockFixtures.appStore(ws, defaults: d, extra: [FixtureDockWorkspace.sample[2]])
        let backend = FixtureSpotifyBackend(.track(EdgeDockFixtures.track))
        let music = EdgeDockFixtures.spotify(backend, cover: EdgeDockFixtures.coverImage())
        let m = EdgePanelModel(apps: apps, spotify: music)
        check("edge dock: the ring holds Chats, Notes, then the pinned apps",
              m.items == [.chats, .notes, .app(FixtureDockWorkspace.sample[0]), .app(FixtureDockWorkspace.sample[2])])
        m.tapSpotify()
        check("edge cards: the cover opens the Spotify mini player (284 × 382)", m.section == .spotify && m.cardSize == CGSize(width: 284, height: 382))
        m.tapSpotify()
        check("edge cards: ...and a second click closes it", m.section == nil)
        m.tapManageApps()
        check("edge cards: \"+\" opens the add/remove card (284 × 362)", m.section == .apps && m.cardSize == CGSize(width: 284, height: 44 + 6 + 7 * 44 + 6))
        check("edge cards: every card fits the window's card slot",
              [L.spotifySize, L.appsSize].allSatisfy { $0.width <= L.listWidth && $0.height <= L.maxCardHeight })
        check("edge cards: the mini player's rows add up to its height",
              L.spotifyPad * 2 + L.spotifySpacing * 4 + L.spotifySearchHeight + L.spotifyOrbRadius * 2 + L.spotifyTextHeight
                + L.spotifyButtonsHeight + L.spotifyOpenHeight == L.spotifySize.height
              && L.spotifyRecord < L.spotifyOrbRadius * 2 * 0.64 && L.spotifyOrbRadius * 2 <= L.listWidth - L.spotifyPad * 2)

        // The Spotify card's buttons reach the (fake) backend.
        m.tapSpotifyCommand(.previous)
        m.tapSpotifyCommand(.playPause)
        m.tapSpotifyCommand(.next)
        EdgeDockFixtures.waitUntil { backend.sent.count == 3 }
        check("edge spotify: previous, play-pause and next reach Spotify in order", backend.sent == [.previous, .playPause, .next])
        check("edge spotify: a playing song with a cover takes the cover's colours", music.palette != .emerald)
        m.tapSpotifyCommand(.stop)
        EdgeDockFixtures.waitUntil { backend.sent.count == 4 }
        let stopScript = "tell application id \"com.spotify.client\"\n    pause\n    set player position to 0\nend tell"
        check("edge spotify: stop sends the constant pause-and-rewind script", backend.sent.last == .stop && backend.scripts.last == stopScript)
        check("edge spotify: the transport works while a song plays", m.transportEnabled)
        let denied = EdgePanelModel(apps: apps, spotify: EdgeDockFixtures.spotify(FixtureSpotifyBackend(.denied)))
        denied.tapSpotify()
        check("edge spotify: without permission the glyph opens the mini player, transport off",
              denied.section == .spotify && denied.track == nil && denied.cardSize == L.spotifySize && !denied.transportEnabled)

        // The Spotify icon on the ring opens the mini player and never opens Spotify; "Open Spotify" alone may.
        let spotifyApp = DockApp(bundleID: LiveSpotifyBackend.bundleID, name: "Spotify")
        let (d2, name2) = EdgeDockFixtures.defaults()
        defer { EdgeDockFixtures.forget(name2) }
        let ws2 = FixtureDockWorkspace()
        let apps2 = EdgeDockFixtures.appStore(ws2, defaults: d2, extra: [spotifyApp])
        let closedBackend = FixtureSpotifyBackend(.notRunning)
        let closed = EdgePanelModel(apps: apps2, spotify: EdgeDockFixtures.spotify(closedBackend))
        var hidden: [DockApp] = []
        closed.onOpenApp = { hidden.append($0) }
        closed.tapApp(spotifyApp)
        check("edge spotify: the Spotify icon opens the mini player, not Spotify",
              closed.section == .spotify && ws2.opened.isEmpty && hidden.isEmpty)
        closed.tapApp(spotifyApp)
        check("edge spotify: a second click on the Spotify icon closes it", closed.section == nil && ws2.opened.isEmpty)
        closed.tapApp(FixtureDockWorkspace.sample[0])
        check("edge spotify: another pinned app still opens (and hides the panel)",
              ws2.opened == [URL(fileURLWithPath: "/fixture/\(DockAppStore.claudeBundleID).app")] && hidden == [FixtureDockWorkspace.sample[0]])
        closed.tapSpotifyCommand(.playPause)
        closed.tapSpotifyCommand(.stop)
        EdgeDockFixtures.waitUntil(0.2) { !closedBackend.sent.isEmpty }
        check("edge spotify: Spotify not open: the transport is off and sends nothing",
              !closed.transportEnabled && closedBackend.sent.isEmpty)
        closed.tapOpenSpotify()
        check("edge spotify: \"Open Spotify\" opens Spotify through the workspace exactly once",
              ws2.opened.count == 2 && ws2.opened.last == URL(fileURLWithPath: "/fixture/\(LiveSpotifyBackend.bundleID).app"))
        check("edge spotify: the service starts in emerald", SpotifyService(backend: FixtureSpotifyBackend(.notRunning)).palette == .emerald)

        // The add/remove card: installed apps load, pinned first, and the cap holds.
        EdgeDockFixtures.waitUntil { !apps.installed.isEmpty }
        check("edge apps: the card lists the pinned apps first, then the rest",
              Array(m.manageRows.prefix(2)) == apps.pinned && m.manageRows.count == FixtureDockWorkspace.sample.count)
        for app in FixtureDockWorkspace.sample where !apps.isPinned(app.bundleID) { m.tapPin(app) }
        check("edge apps: Add stops at 6", apps.pinned.count == DockAppStore.maxPinned && !apps.canPin && m.items.count == L.maxItems)
        m.tapUnpin(apps.pinned[1])
        check("edge apps: Remove frees a place", apps.pinned.count == DockAppStore.maxPinned - 1 && apps.canPin)

        // An app on the ring opens through the workspace and the panel hides (no window, nothing launched).
        let edge = EdgePanelController(apps: store, spotify: SpotifyService(backend: FixtureSpotifyBackend(.notRunning)))
        edge.debugRevealWithoutWindow()
        check("edge apps: (the panel counts as shown before the click)", edge.isVisible)
        let claude = store.pinned.first
        if let claude { edge.model.tapApp(claude) }
        check("edge apps: a click on an app opens it through the workspace",
              claude != nil && workspace.opened == [URL(fileURLWithPath: "/fixture/\(DockAppStore.claudeBundleID).app")])
        check("edge apps: ...and the panel hides", !edge.isVisible && edge.debugWindow == nil)
        edge.model.section = .apps
        let w0 = L.windowFrame(screen: .zero) // the screen the panel was last on (none yet)
        let hover = edge.debugHoverFrame
        check("edge: the hover and click-outside area covers the whole dock, the card and the strip between",
              hover.contains(L.dockFrame(window: w0)) && hover.contains(L.listFrame(window: w0, card: L.appsSize))
              && hover.contains(NSRect(x: L.listFrame(window: w0, card: L.appsSize).maxX, y: w0.midY, width: L.gap, height: 1)))
        edge.model.section = nil
        searchChecks(check)
    }

    /// The disc's search: the match rule, the ring while a query is typed, Return, the closes, and the key window.
    /// The query is set on the model (a real click on a text field would hang a windowed run).
    @MainActor
    private static func searchChecks(_ check: (String, Bool) -> Void) {
        typealias M = EdgePanelModel
        let mail = DockApp(bundleID: "t.mail", name: "Mail"), gmail = DockApp(bundleID: "t.gmail", name: "Gmail")
        let maps = DockApp(bundleID: "t.maps", name: "Maps"), music = DockApp(bundleID: "t.music", name: "Music")
        let ring = [gmail, mail, maps, music]
        check("edge search: a name that starts with the query beats one that only contains it",
              M.match("mail", in: ring) == mail && M.match("ma", in: ring) == mail)
        check("edge search: case does not matter", M.match("MuS", in: ring) == music && M.match("GMAIL", in: ring) == gmail)
        check("edge search: ties go to ring order", M.match("m", in: ring) == mail && M.match("m", in: [maps, mail]) == maps
              && M.match("ai", in: ring) == gmail)
        check("edge search: an empty query or no match names no app",
              M.match("", in: ring) == nil && M.match("  ", in: ring) == nil && M.match("zz", in: ring) == nil)

        let (d, name) = EdgeDockFixtures.defaults()
        defer { EdgeDockFixtures.forget(name) }
        let ws = FixtureDockWorkspace()
        let figma = FixtureDockWorkspace.sample[2], claude = FixtureDockWorkspace.sample[0]
        let store = EdgeDockFixtures.appStore(ws, defaults: d, extra: [figma])
        let edge = EdgePanelController(apps: store, spotify: SpotifyService(backend: FixtureSpotifyBackend(.notRunning)))
        let m = edge.model
        edge.debugRevealWithoutWindow()
        m.openSearch()
        check("edge search: the button opens the field; an empty query leaves the ring as it was",
              m.searchOpen && m.query.isEmpty && m.ringItems == m.items)
        m.query = "fig"
        check("edge search: a query shows only its match (Chats and Notes hide)", m.ringItems == [.app(figma)])
        m.query = "LA"
        check("edge search: ...a contained match counts too", m.ringItems == [.app(claude)])
        m.query = "nothing"
        check("edge search: no match shows no item (and the \"No app\" line)", m.ringItems.isEmpty && m.isFiltering && m.searchMatch == nil)
        m.submitSearch()
        check("edge search: Return with no match opens nothing and keeps search open", ws.opened.isEmpty && m.searchOpen)
        m.query = "fi"
        m.submitSearch()
        check("edge search: Return opens the match through the workspace (as a click would)",
              ws.opened == [URL(fileURLWithPath: "/fixture/\(figma.bundleID).app")])
        check("edge search: ...closes search, clears the query and hides the panel", !m.searchOpen && m.query.isEmpty && !edge.isVisible)
        edge.debugRevealWithoutWindow()
        m.openSearch()
        m.query = "cl"
        m.closeSearch()
        check("edge search: Esc (or a click outside, or loss of the keyboard) closes search and clears the query",
              !m.searchOpen && m.query.isEmpty && m.ringItems == m.items)
        m.openSearch()
        m.query = "cl"
        edge.hide(leaveZoneFirst: true)
        check("edge search: the dock hiding closes search too", !edge.isVisible && !m.searchOpen && m.query.isEmpty)

        // The window: never key unless the disc's search or the apps card's field is open (the front app stays active
        // otherwise). Made, never shown.
        let panel = EdgePanelWindow()
        let closed = !panel.canBecomeKey
        panel.searchOpen = true
        let open = panel.canBecomeKey
        panel.searchOpen = false
        panel.appsSearchOpen = true
        let appsOpen = panel.canBecomeKey
        panel.appsSearchOpen = false
        check("edge search: the panel is never key unless the disc's search or the card's field is open, and stays non-activating",
              closed && open && appsOpen && !panel.canBecomeKey && !panel.canBecomeMain && panel.styleMask.contains(.nonactivatingPanel))
        appsSearchChecks(check)
    }

    /// The apps card's search field: the match rule, Return, the full dock, Esc, the keyboard, and the two searches never
    /// open together. The query is set on the model (never a real click on the field).
    @MainActor
    private static func appsSearchChecks(_ check: (String, Bool) -> Void) {
        typealias M = EdgePanelModel
        func app(_ name: String) -> DockApp { DockApp(bundleID: "t." + name.lowercased(), name: name) }
        let notes = app("Notes"), notion = app("Notion"), keynote = app("Keynote"), sysInfo = app("System Information")
        let photoNotes = app("Photo Notes"), anote = app("Anote"), maps = app("Maps")
        let rows = [maps, photoNotes, notion, keynote, sysInfo, notes, anote]
        check("edge apps search: a name start first, then a later word start, then a substring; ties alphabetical",
              M.appsMatches("no", in: rows) == [notes, notion, photoNotes, anote, keynote])
        check("edge apps search: case does not matter, and a later word counts",
              M.appsMatches("INFO", in: rows) == [sysInfo] && M.appsMatches("NoTi", in: rows) == [notion])
        check("edge apps search: an empty query leaves the list unchanged",
              M.appsMatches("", in: rows) == rows && M.appsMatches("  ", in: rows) == rows)
        check("edge apps search: no match gives no rows", M.appsMatches("zz", in: rows).isEmpty)

        let (d, name) = EdgeDockFixtures.defaults()
        defer { EdgeDockFixtures.forget(name) }
        let ws = FixtureDockWorkspace()
        let s = FixtureDockWorkspace.sample // Claude, Calendar, Figma, Mail, Notion, Preview, Safari, Terminal, Xcode
        let store = EdgeDockFixtures.appStore(ws, defaults: d)
        let edge = EdgePanelController(apps: store, spotify: SpotifyService(backend: FixtureSpotifyBackend(.notRunning)))
        let m = edge.model
        var told: [Bool] = []
        m.onSearchChange = { told.append($0) } // stands in for the controller's key handover
        edge.debugRevealWithoutWindow()
        m.tapManageApps()
        _ = EdgeDockFixtures.waitUntil { !store.installed.isEmpty }
        check("edge apps search: the card opening gives its field the keyboard with an empty query",
              m.section == .apps && m.appsSearchActive && m.appsQuery.isEmpty && m.wantsKeyboard && told == [true])
        m.query = "x"
        m.appsQuery = "a"
        check("edge apps search: the query filters the card's rows (pinned and installed)",
              m.appsResults.map(\.name) == ["Calendar", "Claude", "Figma", "Mail", "Safari", "Terminal"])
        m.appsQuery = "qq"
        check("edge apps search: no match gives no rows (the \"No app found\" line)", m.appsResults.isEmpty)
        m.submitAppsSearch()
        check("edge apps search: Return with no result adds nothing", store.pinned == [s[0]])
        m.appsQuery = ""
        m.submitAppsSearch()
        check("edge apps search: Return with an empty query adds nothing", store.pinned == [s[0]])
        m.appsFilter = .available
        m.appsQuery = "cl" // only Claude, which is pinned
        check("edge apps search: the tab filters the results too (\"No app found\" when it hides them all)",
              m.appsVisible.isEmpty && m.appsResults == [s[0]])
        m.appsFilter = .inRotation
        m.appsQuery = "ma"
        m.submitAppsSearch()
        check("edge apps search: Return on In Rotation adds nothing (it picks only from the rows shown)",
              m.appsVisible.isEmpty && store.pinned == [s[0]])
        m.appsFilter = .all
        m.appsQuery = "cl" // only Claude, which is pinned
        m.submitAppsSearch()
        check("edge apps search: Return skips a result already in the dock", store.pinned == [s[0]])
        m.appsQuery = "ma"
        m.submitAppsSearch()
        check("edge apps search: Return adds the first result not yet in the dock", store.pinned == [s[0], s[3]])
        m.appsQuery = "e"
        m.submitAppsSearch() // substrings only: Calendar, Claude (pinned), Preview, Terminal, Xcode
        check("edge apps search: ...in ranked, alphabetical order", store.pinned == [s[0], s[3], s[1]])
        [s[2], s[4], s[5]].forEach { store.pin($0) }
        m.appsQuery = "sa"
        m.submitAppsSearch()
        check("edge apps search: at six apps Return adds nothing", store.pinned.count == DockAppStore.maxPinned
              && !store.isPinned(s[6].bundleID) && !store.canPin)

        m.appsQuery = "sa"
        m.escapeAppsSearch()
        check("edge apps search: Esc with a query clears it and keeps the card and its field",
              m.appsQuery.isEmpty && m.section == .apps && m.appsSearchActive)
        m.escapeAppsSearch()
        check("edge apps search: Esc with an empty query closes the card and gives the keyboard back",
              m.section == nil && !m.appsSearchActive && !m.wantsKeyboard && told == [true, false])

        m.tapManageApps()
        m.appsQuery = "te"
        m.releaseKeyboard()
        check("edge apps search: loss of the keyboard clears the query and lets go (the card stays)",
              m.appsQuery.isEmpty && !m.appsSearchActive && m.section == .apps && told.last == false)
        m.activateAppsSearch()
        check("edge apps search: a click on the field takes the keyboard back", m.appsSearchActive && told.last == true)

        let before = told.count
        m.openSearch()
        check("edge apps search: opening the disc's search closes the card and its field, and the keyboard stays",
              m.searchOpen && m.section == nil && !m.appsSearchActive && m.appsQuery.isEmpty && told.count == before)
        m.tapManageApps()
        check("edge apps search: opening the card closes the disc's search, and the keyboard stays",
              !m.searchOpen && m.query.isEmpty && m.appsSearchActive && m.section == .apps && told.count == before)

        m.appsQuery = "te"
        m.appsFilter = .available
        edge.hide(leaveZoneFirst: true)
        check("edge apps search: the dock hiding clears the query and gives the keyboard back",
              !edge.isVisible && m.appsQuery.isEmpty && !m.appsSearchActive && told.last == false)
        m.section = nil
        check("edge apps search: the card closing sets the tab back to All", m.appsFilter == .all)
        withExtendedLifetime(edge) {}
    }

    /// Real events into the real panel: a click on Chats grows the list, a click on a row opens it.
    @MainActor
    private static func windowedEdgePanelChecks(_ check: (String, Bool) -> Void) {
        guard ProcessInfo.processInfo.environment["MERLIN_HEADLESS_TESTS"] == nil else { return }
        guard let screen = NSScreen.main?.frame else { return }
        // The real panel with the real Liquid Glass (`glassEffect` in one `GlassEffectContainer`), so a glass crash shows here.
        EdgeDockArt.glassEnabled = true
        if EdgeDockArt.flat {
            print("WARNING edge (real events): Liquid Glass NOT tested (Reduce Transparency or Motion.still is on): flat path only")
        }
        let (fixtureDefaults, fixtureName) = EdgeDockFixtures.defaults()
        defer { EdgeDockFixtures.forget(fixtureName) }
        let edge = EdgePanelController(apps: EdgeDockFixtures.appStore(FixtureDockWorkspace(), defaults: fixtureDefaults),
                                       spotify: SpotifyService(backend: FixtureSpotifyBackend(.notRunning)))
        var opened: [ObjectIdentifier] = []
        edge.onOpenChat = { opened.append($0) }
        let owners = (0..<3).map { _ in NSObject() }
        edge.sync(owners.enumerated().map { i, o in
            .init(id: ObjectIdentifier(o), title: "Chat \(i + 1)", subtitle: "Done · click to read", phase: .done, isOpen: false)
        })
        edge.debugPresentQuietly(section: nil, on: screen)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        guard let window = edge.debugWindow else { return check("edge (real events): the panel has a window", false) }
        func event(_ type: NSEvent.EventType, _ at: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
        }
        func click(_ at: NSPoint) {
            window.sendEvent(event(.leftMouseDown, at))
            window.sendEvent(event(.leftMouseUp, at))
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        let local = NSRect(origin: .zero, size: EdgePanelLayout.windowSize)
        click(EdgePanelLayout.itemCentre(.chats, count: edge.model.items.count, window: local))
        RunLoop.current.run(until: Date().addingTimeInterval(0.5)) // the grow and the rows' fade
        check("edge (real events): a click on Chats grows the box into the Chats list", edge.model.section == .chats)
        let list = EdgePanelLayout.listFrame(window: local, card: EdgePanelLayout.listSize(rows: 3, newNoteRow: false))
        let firstRow = list.maxY - EdgePanelLayout.headerHeight - (EdgePanelLayout.pad - 1) - EdgePanelLayout.rowHeight / 2
        click(NSPoint(x: list.minX + 90, y: firstRow - EdgePanelLayout.rowHeight)) // the second row
        check("edge (real events): a click on a row opens that chat", opened == [ObjectIdentifier(owners[1])])
        check("edge (real events): ...and the panel goes away", !edge.isVisible)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        check("edge (real events): ...and leaves the screen", !edge.debugWindowIsOrderedIn)
        withExtendedLifetime(owners) {}
    }

    /// Hands back a different fixture cover for each URL (so a second song can have a different palette).
    private struct CoverByURL: DockImageLoader {
        let images: [String: NSImage]
        func load(_ url: URL, completion: @escaping (NSImage?) -> Void) { completion(images[url.absoluteString]) }
    }

    /// The real panel window with real Liquid Glass through every state the dock can show (fixtures only), so a glass crash
    /// that only a window on screen shows has a chance to appear. Each state is followed by a run-loop spin so SwiftUI lays
    /// out and draws. States are reached through the model's own functions, never a click on a text field.
    /// With `MERLIN_EDGE_CAPTURE_DIR` set to a folder, the panel's screen rectangle is saved there for a human look.
    @MainActor
    private static func windowedGlassStateChecks(_ check: (String, Bool) -> Void) {
        guard ProcessInfo.processInfo.environment["MERLIN_HEADLESS_TESTS"] == nil else { return }
        guard let screen = NSScreen.main?.frame, let primary = NSScreen.screens.first?.frame else { return }
        EdgeDockArt.glassEnabled = true
        let captureDir = ProcessInfo.processInfo.environment["MERLIN_EDGE_CAPTURE_DIR"].flatMap { $0.isEmpty ? nil : $0 }

        let (fixtureDefaults, fixtureName) = EdgeDockFixtures.defaults()
        defer { EdgeDockFixtures.forget(fixtureName) }
        let workspace = FixtureDockWorkspace()
        // Claude is pinned first; five more make the ring's six.
        let extra = FixtureDockWorkspace.sample.filter { ["fixture.calendar", "fixture.figma", "fixture.mail", "fixture.notion",
                                                           "fixture.safari"].contains($0.bundleID) }
        let store = EdgeDockFixtures.appStore(workspace, defaults: fixtureDefaults, extra: extra)

        let trackA = EdgeDockFixtures.track
        let trackB = SpotifyTrack(title: "Paper Harbour", artist: "Mira Vale", artworkURL: URL(string: "https://i.scdn.co/image/fixture-b"),
                                  isPlaying: true, uri: "spotify:track:1ZyXwVuTsRqPoNmLkJiHgF")
        let paused = SpotifyTrack(title: trackB.title, artist: trackB.artist, artworkURL: trackB.artworkURL,
                                  isPlaying: false, uri: trackB.uri)
        let backend = FixtureSpotifyBackend(.notRunning)
        let service = SpotifyService(backend: backend, loader: CoverByURL(images: [
            trackA.artworkURL!.absoluteString: EdgeDockFixtures.coverImage(),
            trackB.artworkURL!.absoluteString: EdgeDockFixtures.coverBlue(),
        ]))
        let edge = EdgePanelController(apps: store, spotify: service)
        let model = edge.model
        EdgeDockFixtures.seed(model.songs, 3) // this panel's own list, in memory

        func spin(_ seconds: TimeInterval = 0.3) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
        func ordered() -> Bool { edge.debugWindowIsOrderedIn }
        func setSpotify(_ state: SpotifyState) {
            backend.state = state
            service.refresh()
            _ = EdgeDockFixtures.waitUntil { service.state == state }
        }
        /// Saves the panel's screen rectangle with `screencapture` (top-left coordinates). Never fails a check.
        func capture(_ n: Int) {
            guard let captureDir else { return }
            capturePanel(edge.debugWindow, primary: primary, to: (captureDir as NSString).appendingPathComponent("glass-\(n).png"))
        }

        edge.debugPresentQuietly(section: nil, on: screen)
        model.notes = [
            .init(id: UUID(), title: "Microeconomics terms", detail: "Changed 2 min ago"),
            .init(id: UUID(), title: "Physics forces", detail: "Changed 1 hr ago"),
            .init(id: UUID(), title: "Macro essay plan", detail: "Changed yesterday"),
        ] // the fixture rows (present read the shared library once, like the test above)
        // Quiet means click-through; the faint alpha keeps the window drawn. A capture needs it fully visible.
        edge.debugWindow?.alphaValue = captureDir == nil ? 0.01 : 1
        spin()
        guard edge.debugWindow != nil else { return check("edge glass states: the panel has a window", false) }

        // 1. Eight ring items, no card.
        check("edge glass 1: eight ring items, no card, window on screen",
              model.items.count == 8 && model.section == nil && !model.searchOpen && ordered())
        capture(1)

        // 2. The Notes card.
        model.toggle(.notes)
        spin()
        check("edge glass 2: the Notes card with three sheets", model.section == .notes && model.notes.count == 3 && ordered())

        // 3. The Apps card, its search through the model, then the full six-app state.
        model.tapManageApps()
        _ = EdgeDockFixtures.waitUntil { !model.apps.installed.isEmpty }
        spin()
        check("edge glass 3a: the Apps card (App Customization) with the installed apps",
              model.section == .apps && !model.apps.installed.isEmpty && ordered())
        capture(3)
        model.activateAppsSearch()
        model.appsQuery = "ma"
        spin()
        check("edge glass 3b: the Apps card with a query set through the model",
              model.section == .apps && model.appsQuery == "ma" && !model.appsVisible.isEmpty && ordered())
        model.appsQuery = ""
        model.deactivateAppsSearch()
        spin()
        check("edge glass 3c: the Apps card with six apps in the dock (full)",
              model.section == .apps && model.apps.pinned.count == 6 && !model.apps.canPin && ordered())

        // 4. The Spotify mini window: playing, a palette change, paused, not running.
        model.tapSpotify()
        setSpotify(.track(trackA))
        _ = EdgeDockFixtures.waitUntil { service.cover != nil && service.palette != .emerald }
        spin()
        let paletteA = service.palette
        check("edge glass 4a: the Spotify mini window with a playing song and its cover's palette",
              model.section == .spotify && service.state == .track(trackA) && paletteA != .emerald && ordered())
        capture(4)
        setSpotify(.track(trackB))
        _ = EdgeDockFixtures.waitUntil { service.palette != paletteA }
        spin(0.6) // the 0.4 s palette animation runs with the window on screen
        check("edge glass 4b: a second song with a different cover changes the palette",
              service.state == .track(trackB) && service.palette != paletteA && service.palette != .emerald && ordered())
        setSpotify(.track(paused))
        spin()
        check("edge glass 4c: the song paused", service.state == .track(paused) && model.section == .spotify && ordered())
        setSpotify(.notRunning)
        spin()
        check("edge glass 4d: Spotify not running", service.state == .notRunning && model.section == .spotify && ordered())

        // 5. The songs list (query through the model) and the star filter.
        model.songsQuery = "mint"
        spin()
        check("edge glass 5a: the songs list for a query", model.section == .spotify && model.songsListShown
              && model.songsVisible.count == 1 && ordered())
        model.songsQuery = ""
        model.songsStarredOnly = true
        spin()
        check("edge glass 5b: the star filter", model.songsListShown && model.songsVisible.count == 1
              && model.songsVisible.allSatisfy(\.starred) && ordered())
        model.songsStarredOnly = false
        spin()
        check("edge glass 5c: the list gives way to the record", !model.songsListShown && ordered())

        // 6. The disc search: a match, no match, closed. (It opens with an empty query: the query is set after.)
        model.openSearch()
        model.query = "cal"
        spin()
        check("edge glass 6a: the disc search shows its match",
              model.searchOpen && model.section == nil && model.searchMatch?.name == "Calendar" && ordered())
        model.query = "zzzz"
        spin()
        check("edge glass 6b: the disc search with no match",
              model.searchOpen && model.searchMatch == nil && model.ringItems.isEmpty && ordered())
        model.closeSearch()
        spin()
        check("edge glass 6c: the disc search closed", !model.searchOpen && model.query.isEmpty && model.items.count == 8 && ordered())

        // 7. Dismiss.
        edge.hide(leaveZoneFirst: true)
        spin()
        check("edge glass 7: dismissed, the window leaves the screen", !edge.isVisible && !ordered())
        withExtendedLifetime(edge) {}
    }

    /// Saves `window`'s screen rectangle to `path` with `screencapture -x -R` (top-left coordinates). Never fails anything.
    @MainActor
    private static func capturePanel(_ window: NSWindow?, primary: NSRect, to path: String) {
        guard let frame = window?.frame else { return }
        let r = NSRect(x: frame.minX, y: primary.maxY - frame.maxY, width: frame.width, height: frame.height).integral
        let name = (path as NSString).lastPathComponent
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-R\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(r.height))", path]
        do {
            try p.run()
            let end = Date().addingTimeInterval(5)
            while p.isRunning && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
            if p.isRunning { p.terminate(); print("edge glass capture \(name): screencapture took too long, stopped") }
            else if p.terminationStatus != 0 { print("edge glass capture \(name): screencapture exited \(p.terminationStatus)") }
        } catch {
            print("edge glass capture \(name): could not run screencapture (\(error.localizedDescription))")
        }
    }

    /// `Merlin --edgeglasscheck <dir>`: the real panel with real Liquid Glass at full alpha on the main screen, fixtures only
    /// (no Apple Event, no network, no app launch, memory defaults, a throwaway library). Six states, 0.6 s each, saved as
    /// `1-ring.png` … `6-search.png` in `<dir>`; then five over a white backdrop window (`w*`, each with a printed
    /// `CONTRAST` line measured from the picture) and two over mid grey (`g*`); then the panel goes away and the run exits 0. States are reached through
    /// the model, never a click; the window ignores the pointer, so a real mouse cannot change a state.
    @MainActor
    static func edgeGlassCheck(directory: String) -> Never {
        let started = Date()
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let out = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        // A throwaway library, set before anything touches Library.shared (`present` reads its notes).
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("merlin-edgeglass-\(UUID().uuidString)")
        Library.overrideDirectory = tmp
        guard let screen = NSScreen.main?.frame, let primary = NSScreen.screens.first?.frame else {
            print("EDGEGLASSCHECK: no screen"); exit(1)
        }
        EdgeDockArt.glassEnabled = true
        if EdgeDockArt.flat {
            print("WARNING edgeglasscheck: the FLAT path is drawn (Reduce Transparency or Motion.still is on): no Liquid Glass in these pictures")
        }
        print("edgeglasscheck: glass container \(EdgeDockArt.glassContainer ? "ON" : "OFF (MERLIN_EDGE_NO_GLASS_CONTAINER)")")

        let (fixtureDefaults, _) = EdgeDockFixtures.defaults()
        let workspace = FixtureDockWorkspace()
        let extra = FixtureDockWorkspace.sample.filter { ["fixture.calendar", "fixture.figma", "fixture.mail", "fixture.notion",
                                                           "fixture.safari"].contains($0.bundleID) }
        let store = EdgeDockFixtures.appStore(workspace, defaults: fixtureDefaults, extra: extra)
        let track = EdgeDockFixtures.track
        let backend = FixtureSpotifyBackend(.notRunning)
        let service = SpotifyService(backend: backend, loader: CoverByURL(images: [
            track.artworkURL!.absoluteString: EdgeDockFixtures.coverImage(),
        ]))
        let edge = EdgePanelController(apps: store, spotify: service)
        let model = edge.model
        EdgeDockFixtures.seed(model.songs, 3)
        let owners = (0..<3).map { _ in NSObject() }
        edge.sync(owners.enumerated().map { i, o in
            .init(id: ObjectIdentifier(o), title: "Chat \(i + 1)", subtitle: "Done · click to read", phase: .done, isOpen: false)
        })

        func spin(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
        var missing: [String] = []
        func shot(_ name: String, _ ok: Bool) {
            spin(0.6)
            if !ok { print("edgeglasscheck \(name): the state was not reached") }
            let path = out.appendingPathComponent(name).path
            capturePanel(edge.debugWindow, primary: primary, to: path)
            if FileManager.default.fileExists(atPath: path) { print("saved \(path)") } else { missing.append(name) }
        }

        edge.debugPresentQuietly(section: nil, on: screen)
        model.notes = [
            .init(id: UUID(), title: "Microeconomics terms", detail: "Changed 2 min ago"),
            .init(id: UUID(), title: "Physics forces", detail: "Changed 1 hr ago"),
            .init(id: UUID(), title: "Macro essay plan", detail: "Changed yesterday"),
        ]
        edge.debugWindow?.alphaValue = 1 // full alpha; it still ignores the pointer
        shot("1-ring.png", model.items.count == 8 && model.section == nil)

        model.toggle(.chats)
        shot("2-chats.png", model.section == .chats)

        model.tapManageApps()
        _ = EdgeDockFixtures.waitUntil(1) { !model.apps.installed.isEmpty }
        shot("3-apps.png", model.section == .apps)

        model.tapSpotify()
        backend.state = .track(track)
        service.refresh()
        _ = EdgeDockFixtures.waitUntil(1.5) { service.state == .track(track) && service.cover != nil && service.palette != .emerald }
        shot("4-spotify-playing.png", model.section == .spotify && service.cover != nil)

        model.songsQuery = "mint"
        shot("5-songs-list.png", model.songsListShown)

        model.songsQuery = ""
        model.openSearch()
        model.query = "cal"
        shot("6-search.png", model.searchOpen && model.searchMatch?.name == "Calendar")

        // The same states over the tool's own plain backdrop window (white, then mid grey), right behind the panel.
        let local = NSRect(origin: .zero, size: EdgePanelLayout.windowSize)
        /// The text sample, in window coordinates (AppKit, bottom-left origin), from the `EdgePanelLayout` constants:
        /// the song title (Spotify), the first row's title (Chats, the songs list), the "App Customization" title (apps),
        /// and the "+" glyph on the ring picture (the disc has no text).
        func textSpot() -> (NSRect, String) {
            let L = EdgePanelLayout.self
            if let section = model.section {
                let card = L.listFrame(window: local, card: model.cardSize)
                switch section {
                case .apps:
                    return (NSRect(x: card.midX - 55, y: card.maxY - 26, width: 110, height: 12), "apps title")
                case .spotify where model.songsListShown:
                    // Row 0 of the list (pad, field, spacing): its name, right of the 28 pt cover well.
                    let top = L.spotifyPad + L.spotifySearchHeight + L.spotifySpacing
                    return (NSRect(x: card.minX + L.spotifyPad + 42, y: card.maxY - top - 18, width: 74, height: 10), "row 1 title")
                case .spotify:
                    let top = L.spotifyPad + L.spotifySearchHeight + L.spotifySpacing + L.spotifyOrbRadius * 2 + L.spotifySpacing
                    return (NSRect(x: card.midX - 40, y: card.maxY - top - 19, width: 80, height: 11), "song title")
                case .chats, .notes:
                    // Row 0: under the header and the pad, right of the 20 pt mark; the title is the row's upper line.
                    let top = L.headerHeight + L.pad
                    return (NSRect(x: card.minX + L.pad + 38, y: card.maxY - top - 22, width: 36, height: 10), "row 1 title")
                }
            }
            let dock = L.dockFrame(window: local), c = L.plusCentre
            return (NSRect(x: dock.minX + c.x - 5, y: dock.maxY - c.y - 5, width: 10, height: 10), "\"+\" glyph")
        }
        /// A glass spot with no content, in window coordinates (AppKit, bottom-left origin).
        func emptySpot() -> NSRect {
            if let section = model.section {
                let card = EdgePanelLayout.listFrame(window: local, card: model.cardSize)
                if section == .apps {
                    // App Customization: the title bar, between the close dot (ends ~26 pt in) and the title (~80 pt in).
                    return NSRect(x: card.minX + 36, y: card.maxY - 28, width: 30, height: 16)
                }
                // Chats, Notes, the record and the songs list: the right side at mid height, 14–30 pt in from the edge
                // (clear of the edge's lensing; right of the row text, the waves and the songs list's empty middle).
                return NSRect(x: card.maxX - 30, y: card.midY - 10, width: 16, height: 20)
            }
            // The disc at 135° (up-left), 0.945 of its radius from the centre: between the track hairline (0.89) and the
            // rim, clear of the "+" button.
            let r = EdgePanelLayout.discRadius * 0.945, a = CGFloat.pi * 3 / 4
            return NSRect(x: local.maxX + r * cos(a) - 2, y: local.midY + r * sin(a) - 2, width: 4, height: 4)
        }
        /// The sRGB pixels of `spot` (window points) in a saved picture.
        func pixels(_ rep: NSBitmapImageRep, _ spot: NSRect) -> [NSColor] {
            let scale = CGFloat(rep.pixelsWide) / local.width
            var out: [NSColor] = []
            for py in Int(((local.height - spot.maxY) * scale).rounded())..<Int(((local.height - spot.minY) * scale).rounded()) {
                for px in Int((spot.minX * scale).rounded())..<Int((spot.maxX * scale).rounded()) {
                    guard px >= 0, py >= 0, px < rep.pixelsWide, py < rep.pixelsHigh,
                          let c = rep.colorAt(x: px, y: py)?.usingColorSpace(.sRGB) else { continue }
                    out.append(c)
                }
            }
            return out
        }
        func mean(_ cs: [NSColor]) -> NSColor {
            let n = CGFloat(max(cs.count, 1))
            return NSColor(srgbRed: cs.reduce(0) { $0 + $1.redComponent } / n, green: cs.reduce(0) { $0 + $1.greenComponent } / n,
                           blue: cs.reduce(0) { $0 + $1.blueComponent } / n, alpha: 1)
        }
        func hex(_ c: NSColor) -> String {
            String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
        }
        /// Text on the glass is the system's colour now, so nothing is assumed about the ink: prints the mean glass colour
        /// at `emptySpot()`, the mean colour of the text sample (`textSpot()`) and the WCAG ratio of the two (diluted by the
        /// glass between the letters), and the glyph core: the mean of the 15% of sample pixels furthest in luminance
        /// from the glass, with its ratio to the glass (the number to judge legibility by).
        func measure(_ name: String) {
            let path = out.appendingPathComponent(name).path
            guard let data = FileManager.default.contents(atPath: path), let rep = NSBitmapImageRep(data: data) else {
                return print("CONTRAST \(name) no picture")
            }
            let spot = emptySpot(), (text, what) = textSpot()
            let glassPixels = pixels(rep, spot), textPixels = pixels(rep, text)
            guard !glassPixels.isEmpty, !textPixels.isEmpty else { return print("CONTRAST \(name) a sample lies outside the picture") }
            let glass = mean(glassPixels), sample = mean(textPixels)
            func lum(_ c: NSColor) -> CGFloat { 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent }
            let g = lum(glass)
            let core = mean(Array(textPixels.sorted { abs(lum($0) - g) > abs(lum($1) - g) }.prefix(max(1, textPixels.count * 15 / 100))))
            print(String(format: "CONTRAST %@ glass %@ (%@ %.0f,%.0f pt) text %@ %@ (%@ %.0f,%.0f pt) ratio=%.2f core %@ ratio=%.2f",
                         name, hex(glass),
                         model.section == nil ? "disc 135°" : model.section == .apps ? "apps title bar" : "card right side",
                         spot.midX, spot.midY, what, hex(sample), "mean", text.midX, text.midY,
                         DockPalette.contrast(sample, glass), hex(core), DockPalette.contrast(core, glass)))
        }
        let backdrop = NSWindow(contentRect: edge.debugWindow?.frame ?? .zero, styleMask: .borderless, backing: .buffered, defer: false)
        backdrop.isReleasedWhenClosed = false
        backdrop.isOpaque = true
        backdrop.hasShadow = false
        backdrop.ignoresMouseEvents = true
        backdrop.backgroundColor = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        if let panel = edge.debugWindow {
            backdrop.level = NSWindow.Level(rawValue: panel.level.rawValue - 1)
            backdrop.order(.below, relativeTo: panel.windowNumber)
        }

        model.closeSearch()
        model.toggle(.chats)
        shot("w2-chats.png", model.section == .chats); measure("w2-chats.png")
        model.tapManageApps()
        shot("w3-apps.png", model.section == .apps); measure("w3-apps.png")
        model.tapSpotify()
        shot("w4-spotify-playing.png", model.section == .spotify); measure("w4-spotify-playing.png")
        model.songsQuery = "mint"
        shot("w5-songs-list.png", model.songsListShown); measure("w5-songs-list.png")
        model.songsQuery = ""
        model.section = nil
        shot("w1-ring.png", model.section == nil && !model.searchOpen); measure("w1-ring.png")

        backdrop.backgroundColor = NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        model.tapManageApps()
        shot("g3-apps.png", model.section == .apps); measure("g3-apps.png")
        model.tapSpotify()
        shot("g4-spotify-playing.png", model.section == .spotify); measure("g4-spotify-playing.png")
        backdrop.close()

        edge.hide(leaveZoneFirst: true)
        spin(0.2)
        withExtendedLifetime(owners) {}
        withExtendedLifetime(edge) {}
        try? FileManager.default.removeItem(at: tmp) // `exit` skips a defer
        print(String(format: "EDGEGLASSCHECK %@ in %.1f s", missing.isEmpty ? "DONE" : "MISSING \(missing)", Date().timeIntervalSince(started)))
        exit(0)
    }
}
