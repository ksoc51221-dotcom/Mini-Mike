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

        // The rows' wiring: panel → dock → chat. No window, no real chat.
        let edge = EdgePanelController()
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

        // Sizes: the box grows into the list (one shape, a new size).
        let m = EdgePanelModel()
        check("edge sizes: stage one is the half-disc with two items", m.cardSize == EdgePanelLayout.boxSize)
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

        windowedEdgePanelChecks(check)
    }

    /// Real events into the real panel: a click on Chats grows the list, a click on a row opens it.
    @MainActor
    private static func windowedEdgePanelChecks(_ check: (String, Bool) -> Void) {
        guard ProcessInfo.processInfo.environment["MERLIN_HEADLESS_TESTS"] == nil else { return }
        guard let screen = NSScreen.main?.frame else { return }
        let edge = EdgePanelController()
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
        click(EdgePanelLayout.itemCentre(.chats, window: local))
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
