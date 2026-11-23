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

        // Nothing shows it during a drag, a snip, point to ask or a full-screen app.
        for (name, b) in [("a drag (mouse button down)", EdgeBlock.blocked(mouseButtonsDown: 1, snipping: false, pointing: false, fullScreen: false)),
                          ("a snip", EdgeBlock.blocked(mouseButtonsDown: 0, snipping: true, pointing: false, fullScreen: false)),
                          ("point to ask", EdgeBlock.blocked(mouseButtonsDown: 0, snipping: false, pointing: true, fullScreen: false)),
                          ("a full-screen app or video", EdgeBlock.blocked(mouseButtonsDown: 0, snipping: false, pointing: false, fullScreen: true))] {
            var x = EdgeReveal()
            _ = x.update(inZone: true, overPanel: false, blocked: b, now: 0)
            let stays = x.update(inZone: true, overPanel: false, blocked: b, now: 2) == .none && !x.visible
            check("edge: no panel during \(name)", b && stays)
        }
        check("edge: nothing blocking, nothing blocks", !EdgeBlock.blocked(mouseButtonsDown: 0, snipping: false, pointing: false, fullScreen: false))
        var drag = EdgeReveal()
        _ = drag.update(inZone: true, overPanel: false, blocked: true, now: 0)
        _ = drag.update(inZone: true, overPanel: false, blocked: false, now: 0.5)
        check("edge: after the drag ends, the 120 ms wait starts then (no instant pop)",
              drag.update(inZone: true, overPanel: false, blocked: false, now: 0.55) == .none
              && drag.update(inZone: true, overPanel: false, blocked: false, now: 0.63) == .show)
        let menuBarGap = CGRect(x: 0, y: 25, width: 1440, height: 875)
        check("edge: a window covering the whole screen reads as full screen; a zoomed one does not",
              EdgeGeometry.coversScreen([CGRect(x: 0, y: 0, width: 1440, height: 900)], screen: CGRect(x: 0, y: 0, width: 1440, height: 900))
              && !EdgeGeometry.coversScreen([menuBarGap], screen: CGRect(x: 0, y: 0, width: 1440, height: 900)))

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
    }

    /// The dock (version 1): the ring's geometry, the cards' sizes, the app items, the Spotify card and the add/remove cap.
    /// Headless, on fakes only.
    @MainActor
    private static func dockChecks(_ check: (String, Bool) -> Void, store: DockAppStore, workspace: FixtureDockWorkspace) {
        typealias L = EdgePanelLayout
        // Geometry: the numbers.
        check("edge dock: a 110 pt disc, a 160 pt ring, 44 pt items 20° apart", L.discRadius == 110 && L.ringRadius == 160
              && L.itemSize == 44 && L.itemStep == 20 && L.maxItems == 8)
        check("edge dock: the card sits beside the ring's items (ring + half an item + 8 pt)", L.listInset == 160 + 22 + 8)
        check("edge dock: the dock is the ring and its items, flush right", L.dockSize == CGSize(width: 182, height: 346))
        check("edge dock: the window holds the card and the dock", L.windowSize == CGSize(width: 284 + 190 + 56, height: 481 + 112))
        // The card's shadow (radius 22, 16 pt down: about 60 pt below, 44 pt to the sides) stays inside the window.
        check("edge dock: the slack holds the card's shadow", L.slack == 56 && L.slack >= 16 + 22 * 1.8 && L.slack >= 22 * 2)

        // Item centres for 2 and 8 items: no overlap, inside the window, Chats first and on top, centred on the axis.
        let local = NSRect(origin: .zero, size: L.windowSize)
        for n in [2, 8] {
            let c = L.itemCentres(count: n)
            let r = L.itemSize / 2
            var apart = true
            for i in 0..<n { for j in (i + 1)..<n where hypot(c[i].x - c[j].x, c[i].y - c[j].y) < L.itemSize * 1.08 + 2 { apart = false } }
            check("edge dock (\(n) items): no two items overlap, even lifted to 1.08", apart)
            let inDock = c.allSatisfy { $0.x - r >= 0 && $0.x + r <= L.dockSize.width && $0.y - r >= 0 && $0.y + r <= L.dockSize.height }
            let inWindow = (0..<n).allSatisfy { i in
                let p = L.itemCentre(i, of: n, window: local)
                return local.contains(NSRect(x: p.x - r * 1.08, y: p.y - r * 1.08, width: r * 2.16, height: r * 2.16))
            }
            check("edge dock (\(n) items): every item is inside the dock and the window", inDock && inWindow)
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
        check("edge dock: the three buttons share one x, are equally spaced top to bottom and centred on the disc",
              sameX && gap1 > L.plusSize && abs(gap1 - gap2) < 0.001 && abs(buttons[1].y - mid.y) < 0.001)
        let field = L.searchFieldFrame
        let fieldCorners = [CGPoint(x: field.minX, y: field.minY), CGPoint(x: field.minX, y: field.maxY)]
        check("edge dock: the search field sits in the search button's row, inside the disc",
              abs(field.midY - L.searchCentre.y) < 0.001 && field.maxX < L.dockSize.width
              && fieldCorners.allSatisfy { hypot($0.x - mid.x, $0.y - mid.y) <= L.discRadius - 4 })

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
        check("edge dock: the dock frame holds the disc and the outermost item",
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
        check("edge cards: the cover opens the Spotify card (song: 284 × 132)", m.section == .spotify && m.cardSize == CGSize(width: 284, height: 132))
        m.tapSpotify()
        check("edge cards: ...and a second click closes it", m.section == nil)
        m.tapManageApps()
        check("edge cards: \"+\" opens the add/remove card (284 × 362)", m.section == .apps && m.cardSize == CGSize(width: 284, height: 44 + 6 + 7 * 44 + 6))
        check("edge cards: every card fits the window's card slot",
              [L.spotifySize(track: true), L.spotifySize(track: false), L.appsSize].allSatisfy { $0.width <= L.listWidth && $0.height <= L.maxCardHeight })
        check("edge cards: the Spotify card without a song is one line (284 × 76)", L.spotifySize(track: false) == CGSize(width: 284, height: 76))

        // The Spotify card's buttons reach the (fake) backend.
        m.tapSpotifyCommand(.previous)
        m.tapSpotifyCommand(.playPause)
        m.tapSpotifyCommand(.next)
        EdgeDockFixtures.waitUntil { backend.sent.count == 3 }
        check("edge spotify: previous, play-pause and next reach Spotify in order", backend.sent == [.previous, .playPause, .next])
        check("edge spotify: a playing song with a cover takes the cover's colours", music.palette != .emerald)
        let denied = EdgePanelModel(apps: apps, spotify: EdgeDockFixtures.spotify(FixtureSpotifyBackend(.denied)))
        denied.tapSpotify()
        check("edge spotify: without permission the glyph opens the one-line Spotify card (284 × 76)",
              denied.section == .spotify && denied.track == nil && denied.cardSize == CGSize(width: 284, height: 76))
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

        // The window: never key unless search is open (the front app stays active otherwise). Made, never shown.
        let panel = EdgePanelWindow()
        let closed = !panel.canBecomeKey
        panel.searchOpen = true
        let open = panel.canBecomeKey
        panel.searchOpen = false
        check("edge search: the panel is never key unless search is open, and stays non-activating",
              closed && open && !panel.canBecomeKey && !panel.canBecomeMain && panel.styleMask.contains(.nonactivatingPanel))
    }

    /// Real events into the real panel: a click on Chats grows the list, a click on a row opens it.
    @MainActor
    private static func windowedEdgePanelChecks(_ check: (String, Bool) -> Void) {
        guard ProcessInfo.processInfo.environment["MERLIN_HEADLESS_TESTS"] == nil else { return }
        guard let screen = NSScreen.main?.frame else { return }
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
}
