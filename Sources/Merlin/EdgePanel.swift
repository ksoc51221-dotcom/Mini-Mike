import AppKit
import Combine
import SwiftUI

// The hidden edge panel (R3). It replaces the top-right Chats sidebar: nothing shows at rest except an optional 3 pt dot.
// The pointer rests in a small hot zone at the middle of the right screen edge for 120 ms and a box slides in with two
// choices, Chats and Notes; hover or click one and the box grows into that list. The pointer away for 400 ms (and nothing
// pinned) or Esc hides it. `AgentDock` still decides where a minimised chat goes: into this panel.

// MARK: - The rule (pure: no AppKit, no clock)

/// When the edge panel shows and hides. The caller passes the time and where the pointer is, so it's tested without a clock.
struct EdgeReveal {
    /// The pointer must rest in the hot zone this long before the panel shows.
    static let dwell: TimeInterval = 0.12
    /// The pointer must be away from the panel this long before it hides.
    static let linger: TimeInterval = 0.4

    enum Change: Equatable { case none, show, hide }

    private(set) var visible = false
    /// Opened by the shortcut (or a command): stays until Esc or a click outside.
    private(set) var pinned = false
    /// A menu from a row is open: it holds the panel like a pin. (No row has a menu yet; the rule is ready for one.)
    var menuOpen = false
    private var zoneSince: TimeInterval?
    private var outsideSince: TimeInterval?
    /// After Esc, a click outside or a row opened, the pointer must leave the zone before the panel can show again.
    private var mustLeaveZone = false

    /// Something is under way that needs the pointer watched: waiting out the dwell, the panel is showing, or the pointer
    /// must first leave the zone (Esc or a click there), which only a watched update can see.
    var isWatching: Bool { visible || zoneSince != nil || mustLeaveZone }

    /// Where the pointer is now. `blocked`: a drag, a snip, point to ask or a full-screen app (stops a new reveal).
    /// `interrupted`: a snip or point to ask started while the panel shows (it hides at once; a mouse button down does not
    /// count, since a click on a row is one).
    mutating func update(inZone: Bool, overPanel: Bool, blocked: Bool, interrupted: Bool = false, now: TimeInterval) -> Change {
        if visible && interrupted { return hide(leaveZoneFirst: true) }
        if !visible {
            outsideSince = nil
            guard inZone else {
                zoneSince = nil
                mustLeaveZone = false
                return .none
            }
            guard !blocked, !mustLeaveZone else {
                zoneSince = nil
                return .none
            }
            let since = zoneSince ?? now
            zoneSince = since
            guard now - since >= Self.dwell else { return .none }
            visible = true
            zoneSince = nil
            return .show
        }
        if pinned || menuOpen || overPanel || inZone {
            outsideSince = nil
            return .none
        }
        let since = outsideSince ?? now
        outsideSince = since
        guard now - since >= Self.linger else { return .none }
        return hide(leaveZoneFirst: false)
    }

    /// The shortcut or a command: show now, pinned. Refused while a snip or point to ask runs (`interrupted`).
    mutating func showPinned(interrupted: Bool = false) -> Change {
        guard !interrupted else { return .none }
        pinned = true
        zoneSince = nil
        outsideSince = nil
        guard !visible else { return .none }
        visible = true
        return .show
    }

    /// Esc: hide at once.
    mutating func escape() -> Change { hide(leaveZoneFirst: true) }
    /// A click anywhere outside the panel: hide at once (pinned too).
    mutating func clickOutside() -> Change { hide(leaveZoneFirst: true) }

    mutating func hide(leaveZoneFirst: Bool) -> Change {
        zoneSince = nil
        outsideSince = nil
        guard visible else { return .none }
        visible = false
        pinned = false
        menuOpen = false
        mustLeaveZone = leaveZoneFirst
        return .hide
    }
}

/// What keeps the panel from showing: a drag (a mouse button is down), a snip, or point to ask. Any one is enough.
/// A full-screen app does not block it.
enum EdgeBlock {
    static func blocked(mouseButtonsDown: Int, snipping: Bool, pointing: Bool) -> Bool {
        mouseButtonsDown != 0 || snipping || pointing
    }
}

/// Where the hot zone and the panel sit. Cocoa screen coordinates (bottom-left origin) unless a name says otherwise.
enum EdgeGeometry {
    static let zoneWidth: CGFloat = 6
    static let zoneHeight: CGFloat = 160

    /// The screen a point is on (half-open on the right, so the seam between two screens belongs to the right one).
    static func screen(containing p: NSPoint, screens: [NSRect]) -> NSRect? {
        screens.first { p.x >= $0.minX && p.x < $0.maxX && p.y >= $0.minY && p.y <= $0.maxY }
            ?? screens.first { p.x >= $0.minX && p.x <= $0.maxX && p.y >= $0.minY && p.y <= $0.maxY }
    }

    /// A screen's hot zone: 6 pt wide at its right edge, 160 pt tall, centred. Nil where another screen continues past
    /// that edge (the pointer just crosses over there, so it's not an edge).
    static func zone(on screen: NSRect, screens: [NSRect]) -> NSRect? {
        let z = NSRect(x: screen.maxX - zoneWidth, y: screen.midY - zoneHeight / 2, width: zoneWidth, height: zoneHeight)
        let continued = screens.contains { other in
            other != screen && abs(other.minX - screen.maxX) < 1 && other.maxY > z.minY && other.minY < z.maxY
        }
        return continued ? nil : z
    }

    /// The zone on the screen the pointer is on.
    static func zone(for pointer: NSPoint, screens: [NSRect]) -> NSRect? {
        screen(containing: pointer, screens: screens).flatMap { zone(on: $0, screens: screens) }
    }

    static func inZone(_ p: NSPoint, screens: [NSRect]) -> Bool {
        guard let z = zone(for: p, screens: screens) else { return false }
        return p.x >= z.minX && p.x <= z.maxX && p.y >= z.minY && p.y <= z.maxY
    }

    /// Every screen's zone, in event-tap coordinates (top-left origin of the first screen), for the tap thread.
    static func tapZones(screens: [NSRect]) -> [CGRect] {
        guard let primary = screens.first else { return [] }
        return screens.compactMap { zone(on: $0, screens: screens) }.map {
            CGRect(x: $0.minX, y: primary.maxY - $0.maxY, width: $0.width, height: $0.height)
        }
    }
}

/// The 3 pt dot at the screen edge: the only thing that shows at rest.
enum EdgeDotState: Equatable {
    case absent, breathing, solid

    /// Breathing while any chat works; solid when an answer is ready and not read yet (done, and not open on screen).
    static func from(_ chats: [(phase: AgentPhase, isOpen: Bool)]) -> EdgeDotState {
        if chats.contains(where: { $0.phase == .working }) { return .breathing }
        if chats.contains(where: { $0.phase == .done && !$0.isOpen }) { return .solid }
        return .absent
    }
}

/// Sizes of the panel. The card is one shape that changes size; the window around it is fixed and transparent.
enum EdgePanelLayout {
    /// From the card to the screen edge.
    static let gap: CGFloat = 8
    /// Room around the card for its shadow (radius 22, 16 pt down), the rise and the 1.02 scale.
    static let slack: CGFloat = 56
    static let pad: CGFloat = 6
    static let choiceHeight: CGFloat = 40
    static let boxWidth: CGFloat = 156
    static let listWidth: CGFloat = 284
    static let headerHeight: CGFloat = 44
    static let rowHeight: CGFloat = 48
    static let lineHeight: CGFloat = 40
    static let maxRows = 8

    /// The glass half-disc: flush with the screen edge, its round side to the left.
    static let discRadius: CGFloat = 110
    static let itemSize: CGFloat = 44
    /// From the disc's rim to each ring item's edge (the same for every item).
    static let ringGap: CGFloat = 12
    /// The thin ring outside the disc, concentric with it. The round items sit on it: disc + gap + half an item.
    static var ringRadius: CGFloat { discRadius + ringGap + itemSize / 2 }
    /// The least clear space between two neighbouring items' edges.
    static let minItemGap: CGFloat = 8
    /// The angle between two neighbouring items on the ring, in degrees (a 55.0 pt chord on 144 pt: 11 pt clear between
    /// 44 pt items; 20.8° is the least for `minItemGap`, and 8 items at 22° keep the end ones clear of the screen edge).
    static let itemStep: CGFloat = 22
    /// An item under the pointer grows to 1.08 and rises 2 pt (the dock keeps room for it).
    static let liftScale: CGFloat = 1.08
    static let liftRise: CGFloat = 2
    /// The glass container's blend distance: below `minItemGap`, so the shapes never fuse at rest, only while they move.
    static let glassBlend: CGFloat = 6
    /// Chats, Notes and up to `DockAppStore.maxPinned` apps.
    static let maxItems = 2 + DockAppStore.maxPinned
    /// The Spotify cover inside the disc (half of it behind the screen edge) and the small "+" button.
    static let coverSize: CGFloat = 72
    static let plusSize: CGFloat = 28
    /// A pinned app's icon image on its ring item (the whole icon, its transparent margin included).
    static let appIconSize: CGFloat = 40
    /// From the list card's right side to the screen edge: the ring, half an item and the gap.
    static var listInset: CGFloat { ringRadius + itemSize / 2 + gap }

    /// The dock: the disc, the ring and every item on it, lifted ones included (fixed, sized for `maxItems`). The
    /// circles' centre is the middle of its right side.
    static var dockSize: CGSize {
        let half = (CGFloat(maxItems - 1) / 2 * itemStep) * .pi / 180
        let lifted = itemSize / 2 * liftScale
        let h = max(discRadius, ringRadius * sin(half) + lifted + liftRise)
        // The width stops at the leftmost item's edge, so a card sits `gap` from it (a lifted item's 1.76 pt more is in
        // the window's slack and in `hoverFrame`).
        return CGSize(width: ringRadius + itemSize / 2, height: h.rounded(.up) * 2)
    }

    /// Stage one, the dock (the name is from when it was a box).
    static var boxSize: CGSize { dockSize }

    /// Item `index` of `count` on the ring, from the dock's top-left corner (y down). Spread evenly around the horizontal
    /// axis with `itemStep` between neighbours; item 0 (Chats) is the top one.
    static func itemCentre(_ index: Int, of count: Int) -> CGPoint {
        let s = dockSize
        let a = (CGFloat(index) - CGFloat(count - 1) / 2) * itemStep * .pi / 180
        return CGPoint(x: s.width - ringRadius * cos(a), y: s.height / 2 + ringRadius * sin(a))
    }

    /// Every item's centre for `count` items.
    static func itemCentres(count: Int) -> [CGPoint] { (0..<max(count, 0)).map { itemCentre($0, of: count) } }

    /// The same centre in a window frame's coordinates (y up).
    static func itemCentre(_ index: Int, of count: Int, window: NSRect) -> NSPoint {
        let d = dockFrame(window: window), c = itemCentre(index, of: count)
        return NSPoint(x: d.minX + c.x, y: d.maxY - c.y)
    }

    /// Chats (item 0) or Notes (item 1) with `count` items on the ring.
    static func itemCentre(_ s: EdgePanelModel.Section, count: Int = 2, window: NSRect) -> NSPoint {
        itemCentre(s == .notes ? 1 : 0, of: max(count, 2), window: window)
    }

    /// The cover's centre (on the screen edge, in the middle) and the "+" button's centre, from the dock's top-left (y down).
    static var coverCentre: CGPoint { CGPoint(x: dockSize.width, y: dockSize.height / 2) }

    /// The disc's three small buttons ("+", search, collapse): one column with `discButtonGap` between their edges, centred
    /// on the disc's vertical centre, the top and bottom ones `discButtonRim` in from the disc's rim (left of the record).
    static let discButtonGap: CGFloat = 12
    static let discButtonRim: CGFloat = 14
    static var discButtonPitch: CGFloat { plusSize + discButtonGap }
    /// From the screen edge to the column: the outer buttons' centres sit on a circle `discButtonRim` + half a button
    /// inside the rim (about 71.6 pt).
    static var discButtonInset: CGFloat {
        let r = discRadius - discButtonRim - plusSize / 2
        return (r * r - discButtonPitch * discButtonPitch).squareRoot()
    }
    static func discButtonCentre(_ row: Int) -> CGPoint {
        CGPoint(x: dockSize.width - discButtonInset, y: dockSize.height / 2 + CGFloat(row - 1) * discButtonPitch)
    }
    static var plusCentre: CGPoint { discButtonCentre(0) }
    static var searchCentre: CGPoint { discButtonCentre(1) }
    static var collapseCentre: CGPoint { discButtonCentre(2) }
    /// The search field in the disc (it takes the search button's row; the record hides while it shows).
    static var searchFieldFrame: CGRect {
        CGRect(x: dockSize.width - 100, y: dockSize.height / 2 - 14, width: 92, height: 28)
    }
    /// The "No app" line under the field.
    static var noMatchCentre: CGPoint { CGPoint(x: searchFieldFrame.midX, y: dockSize.height / 2 + 30) }
    /// The small Spotify glyph button (Spotify open, but Merlin may not control it), in the cover's place.
    static var glyphCentre: CGPoint { CGPoint(x: dockSize.width - 26, y: dockSize.height / 2) }

    /// The Spotify mini player, one size in every state, top to bottom with `spotifySpacing` between rows and
    /// `spotifyPad` around: the search row, the record in its wave orb, the title and artist (or the status line), the
    /// five round buttons and "Open Spotify".
    static let spotifyPad: CGFloat = 14
    static let spotifySpacing: CGFloat = 10
    static let spotifySearchHeight: CGFloat = 30
    static let spotifyRecord: CGFloat = 100
    /// The orb the card's three waves are drawn in (the outer wave at 0.84 of it, about 1.45 × the record's radius).
    static let spotifyOrbRadius: CGFloat = 86
    static let spotifyTextHeight: CGFloat = 46
    static let spotifyButtonsHeight: CGFloat = 44
    static let spotifyOpenHeight: CGFloat = 22
    static var spotifySize: CGSize {
        let rows = spotifySearchHeight + spotifyOrbRadius * 2 + spotifyTextHeight + spotifyButtonsHeight + spotifyOpenHeight
        return CGSize(width: listWidth, height: rows + spotifySpacing * 4 + spotifyPad * 2)
    }
    /// The add/remove card: the header and a scrolling list of `appsRows` visible rows.
    static let appsRowHeight: CGFloat = 44
    static let appsRows = 7
    static var appsSize: CGSize {
        CGSize(width: listWidth, height: headerHeight + pad + CGFloat(appsRows) * appsRowHeight + pad)
    }

    /// The list card: header, rows (or one quiet line when empty, scrolling past `maxRows`), and Notes' "New note" row.
    static func listSize(rows: Int, newNoteRow: Bool) -> CGSize {
        let body = rows == 0 ? lineHeight : CGFloat(min(rows, maxRows)) * rowHeight
        return CGSize(width: listWidth, height: headerHeight + pad + body + pad + (newNoteRow ? lineHeight + 1 : 0))
    }

    static var maxCardHeight: CGFloat { listSize(rows: maxRows, newNoteRow: true).height }

    static var windowSize: CGSize {
        CGSize(width: listWidth + listInset + slack, height: max(maxCardHeight, dockSize.height) + slack * 2)
    }

    /// The window: right edge on the screen's right edge, centred on the hot zone.
    static func windowFrame(screen: NSRect) -> NSRect {
        let s = windowSize
        return NSRect(x: screen.maxX - s.width, y: (screen.midY - s.height / 2).rounded(), width: s.width, height: s.height)
    }

    /// The half-disc inside a window frame (screen coordinates): flush right, centred vertically.
    static func discFrame(window: NSRect) -> NSRect {
        NSRect(x: window.maxX - discRadius, y: window.midY - discRadius, width: discRadius, height: discRadius * 2)
    }

    /// The whole dock inside a window frame: the disc, the ring and its items. Flush right, centred vertically.
    static func dockFrame(window: NSRect) -> NSRect {
        let s = dockSize
        return NSRect(x: window.maxX - s.width, y: window.midY - s.height / 2, width: s.width, height: s.height)
    }

    /// The list card inside a window frame: left of the disc with the gap, centred vertically.
    static func listFrame(window: NSRect, card: CGSize) -> NSRect {
        NSRect(x: window.maxX - listInset - card.width, y: window.midY - card.height / 2, width: card.width, height: card.height)
    }

    /// Everything the pointer may rest on: the card (or nothing), the dock and the strip between them, as one rectangle
    /// that reaches the screen edge (so the path from the edge to every item stays inside).
    static func hoverFrame(window: NSRect, card: CGSize?) -> NSRect {
        // The dock, grown left by a lifted item's extra (1.76 pt), so a click on the lifted middle item is not "outside".
        let lift = itemSize / 2 * (liftScale - 1)
        var dock = dockFrame(window: window)
        dock.origin.x -= lift
        dock.size.width += lift
        guard let card else { return dock }
        return listFrame(window: window, card: card).union(dock)
    }
}

// MARK: - Model

final class EdgePanelModel: ObservableObject {
    /// The card left of the dock. Chats and Notes open on hover; Spotify and the add/remove card on a click only.
    enum Section: Equatable { case chats, notes, spotify, apps }

    /// One round item on the ring.
    enum Item: Equatable, Identifiable {
        case chats, notes, app(DockApp)
        var id: String {
            switch self {
            case .chats: return "chats"
            case .notes: return "notes"
            case .app(let a): return "app:" + a.bundleID
            }
        }
    }

    /// The pinned apps and the music. Tests and pictures pass fakes; the app uses the shared ones.
    /// Made on first use (the dock drawn), so a panel that is never shown never reads the app's saved apps.
    lazy var apps: DockAppStore = {
        let a = makeApps()
        forwards.append(a.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() })
        return a
    }()
    let spotify: SpotifyService
    private let makeApps: () -> DockAppStore
    private var forwards: [AnyCancellable] = []

    /// "My songs". The app's own list (on disk) only with the live Spotify service; otherwise the given one, or a list in
    /// memory (tests and pictures never touch the real file). Made on first use.
    lazy var songs: SpotifySongs = {
        let s = givenSongs ?? (spotify === SpotifyService.shared ? SpotifySongs.shared : SpotifySongs(folder: nil))
        forwards.append(s.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() })
        return s
    }()
    private let givenSongs: SpotifySongs?
    /// The last song recorded, so the 5-second poll does not rewrite the list: a song is recorded as it starts.
    private var lastRecorded: String?

    init(apps: @autoclosure @escaping () -> DockAppStore = .shared, spotify: SpotifyService = .shared,
         songs: SpotifySongs? = nil) {
        makeApps = apps
        self.spotify = spotify
        givenSongs = songs
        // The dock redraws when the pinned apps (see `apps`), the song or its colours change.
        forwards.append(spotify.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() })
        forwards.append(spotify.$state.sink { [weak self] s in self?.record(s) })
    }

    /// A song seen playing goes into "my songs" (once each time it starts).
    private func record(_ state: SpotifyState) {
        guard case .track(let t) = state, t.isPlaying, let uri = t.uri, SpotifyTrackURI.isValid(uri),
              uri != lastRecorded else { return }
        lastRecorded = uri
        songs.saw(t)
    }

    /// Chats, Notes, then the pinned apps (at most `DockAppStore.maxPinned`).
    var items: [Item] { [.chats, .notes] + apps.pinned.prefix(DockAppStore.maxPinned).map { .app($0) } }

    /// The pinned apps in ring order.
    var ringApps: [DockApp] { Array(apps.pinned.prefix(DockAppStore.maxPinned)) }

    // MARK: Search

    /// The search field in the disc is open (the panel may take the keyboard only now).
    @Published private(set) var searchOpen = false
    @Published var query = ""
    /// The controller makes the panel key (true) or gives the keyboard back (false).
    var onSearchChange: ((Bool) -> Void)?

    /// The pinned app the query names: case-insensitive; a name that starts with it beats one that only contains it;
    /// ties go to ring order. An empty query names none.
    static func match(_ query: String, in apps: [DockApp]) -> DockApp? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return nil }
        return apps.first { $0.name.lowercased().hasPrefix(q) } ?? apps.first { $0.name.lowercased().contains(q) }
    }

    /// Search is open with a non-empty query (the ring shows only the match).
    var isFiltering: Bool { searchOpen && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var searchMatch: DockApp? { searchOpen ? Self.match(query, in: ringApps) : nil }

    /// What the ring draws: every item, or while a query is typed only its match (at the ring's middle-left point).
    var ringItems: [Item] {
        guard isFiltering else { return items }
        return searchMatch.map { [.app($0)] } ?? []
    }

    /// Opening it closes the apps card (and its field): the two searches are never open together.
    func openSearch() {
        guard !searchOpen else { return }
        hoverWork?.cancel()
        query = ""
        withAnimation(Motion.still || Motion.reduceMotion ? nil : Motion.edgeIn) {
            searchOpen = true // first, so the keyboard stays with the panel while the card's field lets go
            section = nil
        }
        keyboardChanged()
    }

    /// Esc, a click outside, loss of the keyboard, an app opening or the dock hiding: the field closes and the query clears.
    func closeSearch() {
        guard searchOpen else { return }
        withAnimation(Motion.still || Motion.reduceMotion ? nil : Motion.edgeOut) {
            searchOpen = false
            query = ""
        }
        keyboardChanged()
    }

    // MARK: The apps card's search

    /// The apps card's field has the keyboard (it takes it as the card opens).
    @Published private(set) var appsSearchActive = false
    @Published var appsQuery = ""
    /// The card's tab (All / In Rotation / Available). Back to All when the card closes.
    @Published var appsFilter: AppsFilter = .all

    enum AppsFilter: CaseIterable { case all, inRotation, available
        var title: String {
            switch self {
            case .all: return "All"
            case .inRotation: return "In Rotation"
            case .available: return "Available"
            }
        }
    }

    /// The panel may take the keyboard: the disc's search, the apps card's field or the songs field is active.
    var wantsKeyboard: Bool { searchOpen || appsSearchActive || songsSearchActive }
    private var keyboardTold = false
    /// Tells the controller only when `wantsKeyboard` flips (a switch from one field to the other keeps the keyboard).
    private func keyboardChanged() {
        guard wantsKeyboard != keyboardTold else { return }
        keyboardTold = wantsKeyboard
        onSearchChange?(keyboardTold)
    }

    /// The card's rows for a query: case-insensitive; a name that starts with it first, then a later word that starts with
    /// it, then a name that only contains it; ties in alphabetical order. An empty query: the rows as given.
    static func appsMatches(_ query: String, in apps: [DockApp]) -> [DockApp] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return apps }
        func rank(_ name: String) -> Int? {
            let n = name.lowercased()
            if n.hasPrefix(q) { return 0 }
            let words = n.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).dropFirst()
            if words.contains(where: { $0.hasPrefix(q) }) { return 1 }
            return n.contains(q) ? 2 : nil
        }
        var ranked: [(app: DockApp, rank: Int)] = []
        for a in apps { if let r = rank(a.name) { ranked.append((a, r)) } }
        ranked.sort { x, y in
            if x.rank != y.rank { return x.rank < y.rank }
            return x.app.name.localizedCaseInsensitiveCompare(y.app.name) == .orderedAscending
        }
        return ranked.map { $0.app }
    }

    /// The card's rows (pinned and installed) for the typed query.
    var appsResults: [DockApp] { Self.appsMatches(appsQuery, in: manageRows) }

    /// The results the current tab shows (what the card draws and what Return picks from).
    var appsVisible: [DockApp] {
        switch appsFilter {
        case .all: return appsResults
        case .inRotation: return appsResults.filter { apps.isPinned($0.bundleID) }
        case .available: return appsResults.filter { !apps.isPinned($0.bundleID) }
        }
    }

    /// The field takes the keyboard (the card opening, or a click on the field after the keyboard went elsewhere).
    func activateAppsSearch() {
        guard section == .apps, !appsSearchActive else { return }
        if searchOpen { searchOpen = false; query = "" } // never both
        appsQuery = ""
        appsSearchActive = true
        keyboardChanged()
    }

    /// Loss of the keyboard, the card closing, the dock hiding or an app opening: the query clears, the keyboard goes back.
    func deactivateAppsSearch() {
        guard appsSearchActive || !appsQuery.isEmpty else { return }
        appsSearchActive = false
        appsQuery = ""
        keyboardChanged()
    }

    /// Return in the card's field: adds the first result not yet in the dock. Nothing while the dock is full or the query
    /// is empty.
    func submitAppsSearch() {
        guard apps.canPin, !appsQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let app = appsVisible.first(where: { !apps.isPinned($0.bundleID) }) else { return }
        tapPin(app)
    }

    /// Esc in the card's field: clears a typed query, else closes the card.
    func escapeAppsSearch() {
        if !appsQuery.isEmpty { appsQuery = "" } else { toggle(.apps) }
    }

    /// Every field lets go of the keyboard (the panel loses it, hides, or an app opens).
    func releaseKeyboard() {
        closeSearch()
        deactivateAppsSearch()
        deactivateSongsSearch()
    }

    // MARK: The Spotify card's songs

    /// The songs field has the keyboard. Only a click on the field activates it (never the card opening).
    @Published private(set) var songsSearchActive = false
    @Published var songsQuery = "" { didSet { if songsQuery != oldValue { songsNotice = nil } } }
    /// The star filter: starred songs only.
    @Published var songsStarredOnly = false
    /// A line about the last row click ("Spotify is not open.").
    @Published private(set) var songsNotice: String?

    /// The card shows the list (in the record's place) while a query is typed or the star filter is on.
    var songsListShown: Bool { songsStarredOnly || !songsQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var songsVisible: [SpotifySong] { SpotifySongs.filter(songs.songs, query: songsQuery, starredOnly: songsStarredOnly) }

    /// A click on the songs field: it takes the keyboard (the other two let go).
    func activateSongsSearch() {
        guard section == .spotify, !songsSearchActive else { return }
        if searchOpen { searchOpen = false; query = "" } // never two at once
        songsSearchActive = true
        keyboardChanged()
    }

    /// Loss of the keyboard, the card closing, the dock hiding or an app opening: the query clears, the keyboard goes back.
    func deactivateSongsSearch() {
        guard songsSearchActive || !songsQuery.isEmpty else { return }
        songsSearchActive = false
        songsQuery = ""
        keyboardChanged()
    }

    /// Esc in the songs field: clears a typed query, else lets go of the keyboard (the card stays).
    func escapeSongsSearch() {
        if !songsQuery.isEmpty { songsQuery = "" } else { deactivateSongsSearch() }
    }

    /// Return in the songs field: plays the first result.
    func submitSongsSearch() {
        guard songsListShown, let first = songsVisible.first else { return }
        tapSong(first)
    }

    /// A row: plays that song, only while Spotify is open (never launches it). The query and the filter stay.
    func tapSong(_ song: SpotifySong) {
        guard SpotifyTrackURI.isValid(song.uri) else { return }
        guard spotify.state != .notRunning else {
            songsNotice = "Spotify is not open."
            return
        }
        songsNotice = nil
        spotify.play(song.uri)
    }

    func tapSongsStarFilter() { songsStarredOnly.toggle() }

    /// The song playing or paused has a URI Merlin can keep (the heart is on).
    var canStarCurrent: Bool { SpotifyTrackURI.isValid(track?.uri) }
    var currentStarred: Bool { canStarCurrent && songs.isStarred(track?.uri) }
    /// The heart: stars or unstars the current song in Merlin's list only (never in Spotify's library).
    func tapHeart() {
        guard canStarCurrent, let t = track else { return }
        songs.toggleStar(t)
    }

    /// Return: opens the match (as a click on it would) and closes search. No match: nothing happens.
    func submitSearch() {
        guard let app = searchMatch else { return }
        tapApp(app)
    }

    var palette: DockPalette { spotify.palette }

    /// The song playing or paused, if any.
    var track: SpotifyTrack? {
        if case .track(let t) = spotify.state { return t }
        return nil
    }

    struct ChatRow: Identifiable, Equatable {
        let id: ObjectIdentifier
        var title: String
        var subtitle: String
        var phase: AgentPhase
        /// The chat is open on screen now.
        var isOpen: Bool
        var starred = false
        var canStar = false
    }

    struct NoteRow: Identifiable, Equatable {
        let id: UUID
        var title: String
        var detail: String
    }

    /// nil: the small box with the two choices.
    @Published var section: Section? {
        didSet {
            guard oldValue != section else { return }
            // The new field first, so a switch from one field to another keeps the keyboard.
            if section == .apps { activateAppsSearch() } // focus goes to the card's field as it opens
            else if oldValue == .apps { deactivateAppsSearch(); appsFilter = .all }
            if oldValue == .spotify { deactivateSongsSearch(); songsStarredOnly = false; songsNotice = nil }
        }
    }
    @Published var chats: [ChatRow] = []
    @Published var notes: [NoteRow] = []
    /// Drives the slide in and out.
    @Published var shown = false
    /// The pointer is over the box (it rises a little).
    @Published var hoveringBox = false

    var onOpenChat: ((ObjectIdentifier) -> Void)?
    var onStar: ((ObjectIdentifier) -> Void)?
    var onDelete: ((ObjectIdentifier) -> Void)?
    var onOpenNote: ((UUID) -> Void)?
    var onNewNote: (() -> Void)?
    /// After an app on the ring opened (the controller hides the panel).
    var onOpenApp: ((DockApp) -> Void)?
    /// The collapse button in the disc (the controller hides the panel).
    var onCollapse: (() -> Void)?

    var cardSize: CGSize {
        switch section {
        case nil: return EdgePanelLayout.boxSize
        case .chats: return EdgePanelLayout.listSize(rows: chats.count, newNoteRow: false)
        case .notes: return EdgePanelLayout.listSize(rows: notes.count, newNoteRow: true)
        case .spotify: return EdgePanelLayout.spotifySize
        case .apps: return EdgePanelLayout.appsSize
        }
    }

    /// Hover or click on a choice (or a tab): the shape grows into that list.
    func choose(_ s: Section) {
        guard section != s else { return }
        hoverWork?.cancel()
        // Reduce Motion: the new size lands at once (no movement); the rows still fade in.
        let animation: Animation? = Motion.still || Motion.reduceMotion ? nil : Motion.edgeIn
        withAnimation(animation) { section = s }
    }

    /// A click on the cover or "+": opens that card, or closes it when it is open.
    func toggle(_ s: Section) {
        hoverWork?.cancel()
        guard section == s else { return choose(s) }
        withAnimation(Motion.still || Motion.reduceMotion ? nil : Motion.edgeOut) { section = nil }
    }

    private var hoverWork: DispatchWorkItem?
    /// Hovering a choice grows it after a short intent delay, so a pointer passing across it on the way doesn't.
    func hoverChoice(_ s: Section, _ inside: Bool) {
        hoverWork?.cancel()
        guard inside else { return }
        let work = DispatchWorkItem { [weak self] in self?.choose(s) }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    // What the buttons call (and the tests).
    func tapChat(_ id: ObjectIdentifier) { onOpenChat?(id) }
    func tapStar(_ id: ObjectIdentifier) { onStar?(id) }
    func tapDelete(_ id: ObjectIdentifier) { onDelete?(id) }
    func tapNote(_ id: UUID) { onOpenNote?(id) }
    func tapNewNote() { onNewNote?() }
    /// An app on the ring: opens it, then the panel hides (like a chat row). Spotify's icon (a click, or Return on it in
    /// search) opens or closes the mini player instead and never opens or activates Spotify.
    func tapApp(_ app: DockApp) {
        releaseKeyboard()
        if app.bundleID == LiveSpotifyBackend.bundleID { return tapSpotify() }
        apps.open(app)
        onOpenApp?(app)
    }
    /// The cover (or the Spotify glyph): the Spotify card.
    func tapSpotify() { toggle(.spotify) }
    /// The mini player's transport buttons work only while Spotify runs and lets Merlin control it.
    var transportEnabled: Bool {
        switch spotify.state {
        case .track, .stopped: return true
        case .notRunning, .denied: return false
        }
    }
    /// "Open Spotify": the only control that may launch or activate Spotify (through the workspace).
    func tapOpenSpotify() { apps.open(DockApp(bundleID: LiveSpotifyBackend.bundleID, name: "Spotify")) }
    /// "+": the add/remove card (it reads the installed apps the first time).
    func tapManageApps() {
        apps.loadInstalled()
        toggle(.apps)
    }
    func tapSpotifyCommand(_ c: SpotifyCommand) {
        guard transportEnabled else { return }
        spotify.send(c)
    }
    func tapCollapse() { onCollapse?() }
    func tapPin(_ app: DockApp) { apps.pin(app) }
    func tapUnpin(_ app: DockApp) { apps.unpin(app.bundleID) }

    /// The add/remove card's rows: the pinned apps first (in dock order), then every other installed app.
    var manageRows: [DockApp] { apps.pinned + apps.installed.filter { !apps.isPinned($0.bundleID) } }

    /// Sheets as rows, in the order given (`Library.sheets` is most recently changed first).
    static func noteRows(_ sheets: [Note], now: Date = Date()) -> [NoteRow] {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return sheets.map { s in
            NoteRow(id: s.id, title: s.name.isEmpty ? s.title : s.name,
                    detail: "Changed " + f.localizedString(for: min(s.lastChanged, now), relativeTo: now))
        }
    }
}

// MARK: - Views

/// The panel: one card that is either the two-choice box or a list. Laid out inside the fixed, transparent window
/// (`framed`), or on its own for pictures.
struct EdgePanelView: View {
    @ObservedObject var model: EdgePanelModel
    var framed = true

    private var radius: CGFloat { Theme.Radius.container }

    var body: some View {
        let stack = HStack(alignment: .center, spacing: EdgePanelLayout.gap) {
            if let section = model.section {
                listCard(section)
                    .transition(Motion.reduceMotion ? .opacity : .scale(scale: 0.96, anchor: .trailing).combined(with: .opacity))
            }
            EdgeDockView(model: model)
        }
        // The dock and the card follow a song's cover with the one palette crossfade (`Motion.edgePalette`).
        .animation(Motion.edgePaletteAnimation, value: model.palette)
        // One glass container for the disc, the ring items and the card, so near shapes blend like one liquid glass.
        // The flat path (pictures, Reduce Transparency, `Motion.still`) draws no glass and needs none.
        // Every surface's content is its glass view's own content (`edgeGlass`), so the container blends shapes only.
        let panel = Group {
            if EdgeDockArt.flat || !EdgeDockArt.glassContainer {
                stack
            } else {
                GlassEffectContainer(spacing: EdgePanelLayout.glassBlend) { stack }
            }
        }
        .offset(x: model.shown || Motion.reduceMotion ? 0 : 16)
        .opacity(model.shown ? 1 : 0)

        if framed {
            let w = EdgePanelLayout.windowSize
            panel.frame(width: w.width, height: w.height, alignment: .trailing)
        } else {
            panel
        }
    }

    /// The card beside the dock (the same slot for every section).
    private func listCard(_ section: EdgePanelModel.Section) -> some View {
        let size = model.cardSize
        return Group {
            switch section {
            case .chats, .notes: EdgeListView(model: model, section: section)
            case .spotify: EdgeSpotifyCard(model: model)
            case .apps: EdgeAppsCard(model: model)
            }
        }
            .frame(width: size.width, height: size.height, alignment: .top)
            // Dark glass in light and dark mode alike, so every row uses the light ink.
            .environment(\.colorScheme, .dark)
            .environment(\.edgePalette, model.palette)
            .edgeCardChrome(model.palette, radius: radius)
    }
}

/// A half circle with its flat side on the right. Stroked, it draws the arc only.
struct EdgeHalfDisc: Shape {
    var radius: CGFloat?
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.addArc(center: CGPoint(x: rect.maxX, y: rect.midY), radius: radius ?? rect.width,
                 startAngle: .degrees(90), endAngle: .degrees(270), clockwise: false)
        return p
    }
}

/// Stage two: the list (the same card, grown). The header keeps both choices as tabs, so you can switch.
private struct EdgeListView: View {
    @ObservedObject var model: EdgePanelModel
    let section: EdgePanelModel.Section
    @Environment(\.edgePalette) private var pal

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(pal.hairlineColor).frame(height: 1)
            Group {
                switch section {
                case .chats: chatRows
                case .notes: noteRows
                case .spotify, .apps: EmptyView() // their own cards
                }
            }
            .padding(.vertical, EdgePanelLayout.pad - 1)
            .id(section) // a new list restarts its stagger
            if section == .notes {
                Rectangle().fill(pal.hairlineColor).frame(height: 1)
                EdgeNewNoteRow { model.tapNewNote() }
                    .padding(.horizontal, EdgePanelLayout.pad)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 4) {
            tab(.chats, "Chats")
            tab(.notes, "Notes")
            Spacer()
        }
        .padding(.horizontal, EdgePanelLayout.pad + 4)
        .frame(height: EdgePanelLayout.headerHeight - 1)
    }

    private func tab(_ s: EdgePanelModel.Section, _ title: String) -> some View {
        let on = section == s
        return Button { model.choose(s) } label: {
            Text(title)
                .font(.geist(13, on ? .semibold : .medium))
                .foregroundStyle(on ? Theme.ink.color : Theme.inkTertiary.color)
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                    .fill(on ? pal.selectedFill : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(EdgePressStyle())
        .edgeHover { model.hoverChoice(s, $0) }
    }

    @ViewBuilder private var chatRows: some View {
        if model.chats.isEmpty {
            EdgeQuietLine(text: "No chats yet")
        } else {
            EdgeRows(count: model.chats.count) { i in
                EdgeChatRowView(row: model.chats[i], model: model)
            }
        }
    }

    @ViewBuilder private var noteRows: some View {
        if model.notes.isEmpty {
            EdgeQuietLine(text: "No notes yet")
        } else {
            EdgeRows(count: model.notes.count) { i in
                EdgeNoteRowView(row: model.notes[i]) { model.tapNote(model.notes[i].id) }
            }
        }
    }
}

/// Rows that fade in one after another (30 ms apart, capped), and scroll past `maxRows`.
private struct EdgeRows<Row: View>: View {
    let count: Int
    @ViewBuilder let row: (Int) -> Row
    @State private var appeared = Motion.still

    var body: some View {
        let list = VStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { i in
                row(i)
                    .frame(height: EdgePanelLayout.rowHeight)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared || Motion.reduceMotion ? 0 : 4)
                    .animation(Motion.still ? nil : Motion.animation(.easeOut(duration: 0.18)).delay(Motion.edgeStagger(i)), value: appeared)
            }
        }
        .padding(.horizontal, EdgePanelLayout.pad)
        .onAppear { appeared = true }
        Group {
            if count > EdgePanelLayout.maxRows {
                ScrollView(.vertical, showsIndicators: false) { list }
                    .frame(height: CGFloat(EdgePanelLayout.maxRows) * EdgePanelLayout.rowHeight)
            } else {
                list
            }
        }
    }
}

struct EdgeQuietLine: View {
    let text: String
    var body: some View {
        Text(text).font(.geist(13)).foregroundStyle(Theme.inkTertiary.color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, EdgePanelLayout.pad + 10)
            .frame(height: EdgePanelLayout.lineHeight)
    }
}

/// One chat: its status mark, title and status line; star and × on hover (a starred chat always shows its star).
private struct EdgeChatRowView: View {
    let row: EdgePanelModel.ChatRow
    @ObservedObject var model: EdgePanelModel
    @Environment(\.edgePalette) private var pal
    @State private var hovering = false

    private var statusColor: Color {
        switch row.phase {
        case .idle: return Theme.inkTertiary.color
        case .working, .done: return Theme.inkSecondary.color
        case .failed: return Theme.alert.color
        }
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            Button { model.tapChat(row.id) } label: {
                HStack(spacing: 10) {
                    EdgeStatusMark(phase: row.phase).frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.title).font(.geist(13, .medium)).foregroundStyle(Theme.ink.color).lineLimit(1)
                        Text(row.subtitle).font(.geist(12)).foregroundStyle(statusColor).lineLimit(1)
                    }
                    Spacer(minLength: trailingRoom)
                }
                .padding(.leading, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(row.isOpen ? pal.selectedFill : (hovering ? pal.hoverFill : .clear)))
                .overlay(alignment: .leading) {
                    // The open chat's slim ink bar (the Library marks selected rows the same way).
                    if row.isOpen { Capsule().fill(Theme.ink.color).frame(width: 2, height: 20).padding(.leading, 4) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(EdgePressStyle())
            .help(row.title)

            HStack(spacing: 2) {
                if row.canStar && (hovering || row.starred) {
                    EdgeIconButton(symbol: row.starred ? "star.fill" : "star", help: row.starred ? "Unstar" : "Star",
                                   tint: row.starred ? pal.accentColor : Theme.inkSecondary.color) { model.tapStar(row.id) }
                }
                if hovering {
                    EdgeIconButton(symbol: "xmark", help: "Delete chat", tint: Theme.inkSecondary.color) { model.tapDelete(row.id) }
                }
            }
            .padding(.trailing, 6)
        }
        .edgeHover { h in withAnimation(Motion.still ? nil : Motion.animation(Motion.small)) { hovering = h } }
    }

    /// The text steps back only while the star or × shows, so a resting row shows its whole status.
    private var trailingRoom: CGFloat {
        let star = row.canStar && (hovering || row.starred)
        return (star ? 26 : 0) + (hovering ? 26 : 0) + 8
    }
}

private struct EdgeNoteRowView: View {
    let row: EdgePanelModel.NoteRow
    let action: () -> Void
    @Environment(\.edgePalette) private var pal
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "tablecells").font(.system(size: 12)).foregroundStyle(Theme.inkTertiary.color).frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.title).font(.geist(13, .medium)).foregroundStyle(Theme.ink.color).lineLimit(1)
                    Text(row.detail).font(.geist(12)).foregroundStyle(Theme.inkTertiary.color).lineLimit(1)
                }
                Spacer(minLength: 8)
            }
            .padding(.leading, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(hovering ? pal.hoverFill : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(EdgePressStyle())
        .help(row.title)
        .edgeHover { h in withAnimation(Motion.still ? nil : Motion.animation(Motion.small)) { hovering = h } }
    }
}

private struct EdgeNewNoteRow: View {
    let action: () -> Void
    @Environment(\.edgePalette) private var pal
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "plus").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.inkSecondary.color).frame(width: 20)
                Text("New note").font(.geist(13, .medium)).foregroundStyle(Theme.inkSecondary.color)
                Spacer()
            }
            .padding(.leading, 8)
            .frame(height: EdgePanelLayout.lineHeight - 8)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(hovering ? pal.hoverFill : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(EdgePressStyle())
        .frame(height: EdgePanelLayout.lineHeight)
        .help("Open the Library to name a new note")
        .edgeHover { h in withAnimation(Motion.still ? nil : Motion.animation(Motion.small)) { hovering = h } }
    }
}

private struct EdgeIconButton: View {
    let symbol: String
    let help: String
    let tint: Color
    let action: () -> Void
    @Environment(\.edgePalette) private var pal
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hovering ? Theme.ink.color : tint)
                .frame(width: 24, height: 24)
                .background(Circle().fill(hovering ? pal.selectedFill : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(EdgePressStyle(scale: 0.9))
        .help(help)
        .accessibilityLabel(help)
        .edgeHover { hovering = $0 }
    }
}

/// A chat's state in one small mark, the same vocabulary as the old folded dots: a hollow ring waiting for you, a softly
/// breathing accent dot working, a solid ink dot done, alert red when something went wrong.
struct EdgeStatusMark: View {
    let phase: AgentPhase
    var size: CGFloat = 8
    @Environment(\.edgePalette) private var pal

    var body: some View {
        Group {
            switch phase {
            case .idle: Circle().strokeBorder(Theme.inkSecondary.color, lineWidth: 1.5)
            // The dock's accent (the card is always dark glass, and the accent keeps 3:1 on its base).
            case .working: EdgeBreathing { Circle().fill(pal.accentColor) }
            case .done: Circle().fill(Theme.ink.color)
            case .failed: Circle().fill(Theme.alert.color)
            }
        }
        .frame(width: size, height: size)
        .id(phase)
    }
}

/// A slow opacity breath (1.1 s each way). Still under Reduce Motion and in pictures.
struct EdgeBreathing<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @State private var dim = false

    var body: some View {
        content()
            .opacity(dim ? 0.4 : 1)
            .onAppear {
                guard !Motion.still, !Motion.reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}

/// The dot at the screen edge, as a view (the live one is a layer in its own window; this one is for pictures).
struct EdgeDotView: View {
    let state: EdgeDotState
    var body: some View {
        switch state {
        case .absent: Color.clear.frame(width: EdgeDotWindow.size.width, height: EdgeDotWindow.size.height)
        case .breathing: Capsule().fill(Theme.accentText.color).frame(width: EdgeDotWindow.size.width, height: EdgeDotWindow.size.height)
        case .solid: Capsule().fill(Theme.ink.color).frame(width: EdgeDotWindow.size.width, height: EdgeDotWindow.size.height)
        }
    }
}

/// Hover from an AppKit tracking area with the old sidebar rows' options (`.activeAlways`), so it works in a panel that
/// never takes the keyboard, in an app that usually isn't active. It never takes a click.
struct EdgeHoverArea: NSViewRepresentable {
    let onChange: (Bool) -> Void
    func makeNSView(context: Context) -> EdgeHoverView {
        let v = EdgeHoverView()
        v.onChange = onChange
        return v
    }
    func updateNSView(_ view: EdgeHoverView, context: Context) { view.onChange = onChange }
}

final class EdgeHoverView: NSView {
    var onChange: ((Bool) -> Void)?
    private var inside = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func mouseEntered(with event: NSEvent) { set(true) }
    override func mouseExited(with event: NSEvent) { set(false) }
    // Hidden or taken off screen under the pointer: no exit arrives, so forget the hover here.
    override func viewDidHide() { super.viewDidHide(); set(false) }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { set(false) } }

    private func set(_ on: Bool) {
        guard on != inside else { return }
        inside = on
        onChange?(on)
    }
}

extension View {
    /// Hover for the edge panel (see `EdgeHoverArea`).
    /// (Left out of the headless pictures: `ImageRenderer` can't draw an AppKit view and paints a placeholder.)
    func edgeHover(_ action: @escaping (Bool) -> Void) -> some View {
        background { if !Motion.still { EdgeHoverArea(onChange: action) } }
    }
}

struct EdgePressStyle: ButtonStyle {
    var scale: CGFloat = Motion.pressScale
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !Motion.reduceMotion ? scale : 1)
            .animation(Motion.still ? nil : Motion.animation(Motion.small), value: configuration.isPressed)
    }
}

// MARK: - Windows

/// The panel's window: a non-activating panel that takes the keyboard only while the disc's search, the apps card's field
/// or the Spotify card's songs field is active (the front app
/// stays active), takes the first click, and its transparent parts let clicks through.
final class EdgePanelWindow: FloatingPanel {
    /// Set by the controller from `EdgePanelModel.searchOpen` and `appsSearchActive`.
    var searchOpen = false
    var appsSearchOpen = false
    var songsSearchOpen = false
    override var canBecomeKey: Bool { searchOpen || appsSearchOpen || songsSearchOpen }

    init() {
        super.init(size: EdgePanelLayout.windowSize, canKey: false)
        hasShadow = false // the card draws its own
    }
}

private final class EdgeHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The 3 pt dot at the screen edge, in a tiny click-through window.
final class EdgeDotWindow {
    /// 3 pt wide, 2 pt in from the edge (so it never merges with the bezel); a little taller than wide so it can be seen
    /// at a glance.
    static let size = CGSize(width: 3, height: 12)
    static let inset: CGFloat = 2
    private let window = FloatingPanel(size: EdgeDotWindow.size, canKey: false)
    private let dot = CALayer()
    private(set) var state: EdgeDotState = .absent

    init() {
        window.ignoresMouseEvents = true
        window.hasShadow = false
        let view = NSView(frame: NSRect(origin: .zero, size: Self.size))
        view.wantsLayer = true
        dot.frame = view.bounds
        dot.cornerRadius = Self.size.width / 2
        view.layer?.addSublayer(dot)
        window.contentView = view
    }

    var isVisible: Bool { window.isVisible }

    func show(_ state: EdgeDotState, on screen: NSRect) {
        self.state = state
        guard state != .absent else { return window.orderOut(nil) }
        window.setFrame(NSRect(x: screen.maxX - Self.size.width - Self.inset, y: (screen.midY - Self.size.height / 2).rounded(),
                               width: Self.size.width, height: Self.size.height), display: false)
        var color = NSColor.clear
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            color = state == .breathing ? Theme.accentText.ns : Theme.ink.ns
            self.dot.backgroundColor = color.cgColor
        }
        if state == .breathing && !Motion.reduceMotion && !Motion.still {
            if dot.animation(forKey: "breath") == nil {
                let a = CABasicAnimation(keyPath: "opacity")
                a.fromValue = 0.35
                a.toValue = 1
                a.duration = 1.1
                a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                a.autoreverses = true
                a.repeatCount = .infinity
                dot.add(a, forKey: "breath")
            }
        } else {
            dot.removeAnimation(forKey: "breath")
        }
        window.orderFrontRegardless()
    }

    func hide() { window.orderOut(nil) }
}

/// The hot zones, read on the event tap's thread for every pointer move, so behind a lock.
final class EdgeZoneCache: @unchecked Sendable {
    private let lock = NSLock()
    private var zones: [CGRect] = []
    private var armed = true

    func set(_ z: [CGRect]) { lock.lock(); zones = z; lock.unlock() }

    /// True once when the pointer enters a zone; quiet after that until `rearm` (the main thread then watches the pointer).
    func hit(_ p: CGPoint) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard armed, zones.contains(where: { $0.insetBy(dx: -0.5, dy: 0).contains(p) }) else { return false }
        armed = false
        return true
    }

    func rearm() { lock.lock(); armed = true; lock.unlock() }
}

// MARK: - Controller

/// Owns the panel, the dot and the pointer watch. Creates no window or timer until it's used (several docks exist in the
/// demos and tests). `EdgePanelController.shared` is the app's; R4's commands use `show(.chats)` / `show(.notes)`.
final class EdgePanelController {
    static let shared = EdgePanelController()

    let model: EdgePanelModel
    /// The shared Spotify service is the live one: only the app (`start`) may run it. An injected one always runs.
    private let liveSpotify: Bool
    private var reveal = EdgeReveal()
    private var window: EdgePanelWindow?
    private var dotWindow: EdgeDotWindow?
    private let zones = EdgeZoneCache()
    private var poll: Timer?
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var hideWork: DispatchWorkItem?
    private var started = false
    /// The screen the panel is on (its frame).
    private var screen: NSRect = .zero
    private var dotState: EdgeDotState = .absent

    /// Point to ask (and anything else the app knows about) stops the panel from showing.
    var isBlocked: () -> Bool = { false }
    /// Rows of the dock's chats: open (or restore) one, star it, delete it (the dock calls `closeFromUser`).
    var onOpenChat: ((ObjectIdentifier) -> Void)?
    var onStar: ((ObjectIdentifier) -> Void)?
    var onDelete: ((ObjectIdentifier) -> Void)?
    var openNote: (UUID) -> Void = { LibraryWindow.shared.show(sheet: $0) }
    var newNote: () -> Void = { LibraryWindow.shared.showNewSheet() }

    init(apps: @autoclosure @escaping () -> DockAppStore = .shared, spotify: SpotifyService = .shared) {
        model = EdgePanelModel(apps: apps(), spotify: spotify)
        liveSpotify = spotify === SpotifyService.shared
        model.onOpenApp = { [weak self] _ in self?.hide(leaveZoneFirst: true) } // the app opened beside it
        model.onCollapse = { [weak self] in self?.hide(leaveZoneFirst: true) }
        model.onSearchChange = { [weak self] open in self?.searchChanged(open) }
        model.onOpenChat = { [weak self] id in
            self?.hide(leaveZoneFirst: true) // the panel's job is done: the chat comes out beside it
            self?.onOpenChat?(id)
        }
        model.onStar = { [weak self] id in self?.onStar?(id) }
        model.onDelete = { [weak self] id in self?.onDelete?(id) }
        model.onOpenNote = { [weak self] id in
            self?.hide(leaveZoneFirst: true)
            self?.openNote(id)
        }
        model.onNewNote = { [weak self] in
            self?.hide(leaveZoneFirst: true)
            self?.newNote()
        }
    }

    // MARK: Start (the app only)

    /// Watches the screens and the dot setting. The pointer comes from the event tap (`tapMoved`).
    func start() {
        guard !started else { return }
        started = true
        refreshZones()
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            self?.refreshZones()
            self?.syncDot()
        })
        observers.append(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            guard let self, self.dotSetting != Settings.shared.edgeDot else { return }
            self.dotSetting = Settings.shared.edgeDot
            self.syncDot()
        })
        observers.append(NotificationCenter.default.addObserver(forName: Library.changed, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.reveal.visible else { return }
            self.refreshNotes()
        })
        dotSetting = Settings.shared.edgeDot
        syncDot()
    }
    private var dotSetting = true

    private func refreshZones() {
        zones.set(EdgeGeometry.tapZones(screens: NSScreen.screens.map(\.frame)))
    }

    /// On the event tap's thread, for every pointer move: only a few rect checks; the main thread hears only "entered".
    func tapMoved(_ p: CGPoint) {
        guard zones.hit(p) else { return }
        DispatchQueue.main.async { [weak self] in self?.startWatching() }
    }

    // MARK: Showing and hiding

    /// Shows the panel pinned (the shortcut, "show my chats"): it stays until Esc or a click outside. `animated: false` for
    /// the keyboard (a key gets no animation).
    func show(_ section: EdgePanelModel.Section? = nil, animated: Bool = true) {
        let s = screenUnderPointer()
        if reveal.visible {
            _ = reveal.showPinned()
            if let section { model.choose(section) }
            return
        }
        guard reveal.showPinned(interrupted: interrupted) == .show else { return }
        present(section: section, on: s, animated: animated)
        startWatching()
    }

    /// The shortcut: shows the panel pinned on the Chats list, or hides it if it's showing.
    func toggleFromShortcut() {
        if reveal.visible { hide(leaveZoneFirst: true) } else { show(.chats, animated: false) }
    }

    /// A snip or point to ask is under way: the panel hides, and nothing shows it.
    private var interrupted: Bool { Snipper.isActive || isBlocked() }

    func hide(leaveZoneFirst: Bool = false) {
        guard reveal.hide(leaveZoneFirst: leaveZoneFirst) == .hide else { return }
        dismiss()
    }

    var isVisible: Bool { reveal.visible }

    private func startWatching() {
        guard poll == nil else { return }
        tick()
        guard reveal.isWatching else { return zones.rearm() }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
    }

    private func stopWatching() {
        poll?.invalidate()
        poll = nil
        zones.rearm()
    }

    private func tick() {
        let p = NSEvent.mouseLocation
        let screens = NSScreen.screens.map(\.frame)
        let inZone = EdgeGeometry.inZone(p, screens: screens)
        // While search is open the dock stays, wherever the pointer goes (it may leave mid-typing).
        let over = reveal.visible && (model.wantsKeyboard || hoverFrame.insetBy(dx: -6, dy: -6).contains(p))
        let blocked = !reveal.visible && inZone && liveBlocked(at: p, screens: screens)
        let stop = reveal.visible && interrupted
        let now = ProcessInfo.processInfo.systemUptime
        switch reveal.update(inZone: inZone, overPanel: over, blocked: blocked, interrupted: stop, now: now) {
        case .show:
            present(section: nil, on: EdgeGeometry.screen(containing: p, screens: screens) ?? screenUnderPointer(), animated: true)
        case .hide:
            dismiss()
        case .none:
            break
        }
        if !reveal.isWatching { stopWatching() }
    }

    /// A drag (a mouse button is down), a snip, or point to ask. A full-screen front app does not block: the panel
    /// shows above it (`.fullScreenAuxiliary`).
    private func liveBlocked(at p: NSPoint, screens: [NSRect]) -> Bool {
        EdgeBlock.blocked(mouseButtonsDown: NSEvent.pressedMouseButtons, snipping: Snipper.isActive, pointing: isBlocked())
    }

    private func screenUnderPointer() -> NSRect {
        let screens = NSScreen.screens.map(\.frame)
        let p = NSEvent.mouseLocation
        if let s = EdgeGeometry.screen(containing: p, screens: screens), EdgeGeometry.zone(on: s, screens: screens) != nil { return s }
        return screens.first { EdgeGeometry.zone(on: $0, screens: screens) != nil } ?? screens.first ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    private func ensureWindow() -> EdgePanelWindow {
        if let window { return window }
        let w = EdgePanelWindow()
        let host = EdgeHostingView(rootView: AnyView(ThemedRoot { EdgePanelView(model: self.model) }))
        host.frame = NSRect(origin: .zero, size: EdgePanelLayout.windowSize)
        w.contentView = host
        window = w
        return w
    }

    private func present(section: EdgePanelModel.Section?, on screen: NSRect, animated: Bool) {
        hideWork?.cancel()
        self.screen = screen
        refreshNotes()
        let w = ensureWindow()
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            model.section = section
            model.hoveringBox = false
            model.shown = !animated || Motion.still
        }
        w.setFrame(EdgePanelLayout.windowFrame(screen: screen), display: false)
        w.alphaValue = 1
        w.orderFrontRegardless()
        if animated && !Motion.still {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.reveal.visible else { return }
                withAnimation(Motion.reduceMotion ? .easeOut(duration: 0.15) : Motion.edgeIn) { self.model.shown = true }
            }
        }
        installMonitors()
        dotWindow?.hide()
        if drivesSpotify { model.spotify.start() }
    }

    /// The music is read only while the panel shows, and the live service only in the app (never in a test).
    private var drivesSpotify: Bool { started || !liveSpotify }

    private func dismiss() {
        model.releaseKeyboard() // gives the keyboard back before the panel leaves
        removeMonitors()
        if drivesSpotify { model.spotify.stop() }
        withAnimation(Motion.still ? nil : (Motion.reduceMotion ? .easeOut(duration: 0.12) : Motion.edgeOut)) { model.shown = false }
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.reveal.visible else { return }
            self.window?.orderOut(nil)
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { self.model.section = nil; self.model.hoveringBox = false }
            self.syncDot()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (Motion.still ? 0 : 0.2), execute: work)
    }

    /// Esc anywhere, and a click outside the panel, hide it (the panel never takes the keyboard, so these are watched).
    private func installMonitors() {
        guard monitors.isEmpty else { return }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown], handler: { [weak self] e in
            self?.outside(e)
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown], handler: { [weak self] e in
            guard let self else { return e }
            // Esc while searching closes the search only (the dock stays); the field never sees it.
            if e.type == .keyDown, e.keyCode == 53, self.model.searchOpen {
                self.model.closeSearch()
                return nil
            }
            // Esc in the apps card's field: clears the query, else closes the card (the dock stays).
            if e.type == .keyDown, e.keyCode == 53, self.model.appsSearchActive {
                self.model.escapeAppsSearch()
                return nil
            }
            // Esc in the songs field: clears the query, then a second Esc lets go of the keyboard (the card stays).
            if e.type == .keyDown, e.keyCode == 53, self.model.songsSearchActive {
                self.model.escapeSongsSearch()
                return nil
            }
            // Tab (the first key of a hold-Tab chord reaches the panel before the tap sees the second) would move the
            // focus out of the field.
            if e.type == .keyDown, e.keyCode == 48, self.model.wantsKeyboard, e.window === self.window { return nil }
            if e.type == .keyDown || e.window !== self.window { self.outside(e) }
            return e
        }) { monitors.append(m) }
    }

    // MARK: Search and the keyboard

    /// What had the keyboard before search took it: Merlin's own key window, if Merlin was active.
    private weak var keyBeforeSearch: NSWindow?
    private var resignObserver: NSObjectProtocol?

    /// Search opened: the panel (non-activating) becomes key, so the front app stays active. Search closed: the keyboard
    /// goes back to where it was.
    private func searchChanged(_ open: Bool) {
        guard let window else { return }
        window.searchOpen = model.searchOpen
        window.appsSearchOpen = model.appsSearchActive
        window.songsSearchOpen = model.songsSearchActive
        if open {
            guard reveal.visible, window.isVisible, !window.isKeyWindow else { return }
            keyBeforeSearch = NSApp.isActive ? NSApp.keyWindow : nil
            window.makeKey()
            if resignObserver == nil {
                resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window,
                                                                        queue: .main) { [weak self] _ in
                    self?.model.releaseKeyboard() // a click in another app or window
                }
            }
        } else {
            if let o = resignObserver { NotificationCenter.default.removeObserver(o) }
            resignObserver = nil
            guard window.isKeyWindow else { return }
            if let previous = keyBeforeSearch, previous.isVisible {
                previous.makeKey()
            } else {
                // A key window that leaves the screen hands the keyboard back to the active app's window. The panel
                // comes straight back (it can no longer become key), so nothing moves on screen.
                let visible = window.isVisible
                window.orderOut(nil)
                if visible { window.orderFrontRegardless() } // a hiding dock still fades; its own work item orders it out
            }
            keyBeforeSearch = nil
        }
    }

    private func outside(_ e: NSEvent) {
        if e.type == .keyDown {
            if e.keyCode == 53, reveal.escape() == .hide { dismiss() }
        } else if !hoverFrame.contains(NSEvent.mouseLocation), reveal.clickOutside() == .hide {
            dismiss()
        }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    /// The card on screen now.
    private var cardFrame: NSRect {
        let w = EdgePanelLayout.windowFrame(screen: screen)
        return model.section == nil ? EdgePanelLayout.dockFrame(window: w) : EdgePanelLayout.listFrame(window: w, card: model.cardSize)
    }

    /// Everything the pointer may rest on: the disc, the ring with its items, the card and the strip between them.
    private var hoverFrame: NSRect {
        EdgePanelLayout.hoverFrame(window: EdgePanelLayout.windowFrame(screen: screen),
                                   card: model.section == nil ? nil : model.cardSize)
    }

    // MARK: Rows and the dot

    /// The dock's chats changed.
    func sync(_ rows: [EdgePanelModel.ChatRow]) {
        if rows != model.chats {
            let animation: Animation? = (reveal.visible && !Motion.still && !Motion.reduceMotion) ? Motion.edgeGrow : nil
            withAnimation(animation) { model.chats = rows }
        }
        dotState = EdgeDotState.from(rows.map { ($0.phase, $0.isOpen) })
        syncDot()
    }

    func refreshNotes(library: Library = .shared) {
        let rows = EdgePanelModel.noteRows(library.sheets)
        if rows != model.notes { model.notes = rows }
    }

    private func syncDot() {
        guard started else { return } // tests and demos never put a dot on screen
        let state: EdgeDotState = (Settings.shared.edgeDot && !reveal.visible) ? dotState : .absent
        if state == .absent { dotWindow?.hide(); return }
        let d = dotWindow ?? EdgeDotWindow()
        dotWindow = d
        d.show(state, on: screenUnderPointer())
    }

    /// Where a minimised chat flies to: the middle of the right edge of its screen (where the dot and the panel are).
    func landingFrame(near rect: NSRect) -> NSRect {
        let screens = NSScreen.screens.map(\.frame)
        let c = NSPoint(x: rect.midX, y: rect.midY)
        let s = EdgeGeometry.screen(containing: c, screens: screens).flatMap { EdgeGeometry.zone(on: $0, screens: screens) != nil ? $0 : nil }
            ?? screenUnderPointer()
        let d: CGFloat = 12
        return NSRect(x: s.maxX - d - 2, y: s.midY - d / 2, width: d, height: d)
    }

    /// What a chat opening from the panel opens beside: the Chats list as it shows (or would show) on the pointer's screen.
    func restingFrame() -> NSRect {
        let s = reveal.visible ? screen : screenUnderPointer()
        return EdgePanelLayout.listFrame(window: EdgePanelLayout.windowFrame(screen: s),
                                         card: EdgePanelLayout.listSize(rows: model.chats.count, newNoteRow: false))
    }

    // MARK: Debug hooks (--sidebartest, --placetest, --demo, the unit run)

    func debugTitles() -> [String] { model.chats.map(\.title) }
    var debugRowCount: Int { model.chats.count }
    func debugClickRow(_ index: Int) { if model.chats.indices.contains(index) { model.tapChat(model.chats[index].id) } }
    func debugClickDelete(_ index: Int) { if model.chats.indices.contains(index) { model.tapDelete(model.chats[index].id) } }
    func debugClickStar(_ index: Int) { if model.chats.indices.contains(index) { model.tapStar(model.chats[index].id) } }
    var debugIsVisible: Bool { reveal.visible && window?.isVisible == true }
    var debugWindowIsOrderedIn: Bool { window?.isVisible == true }
    var debugPanelFrame: NSRect { cardFrame }
    var debugDotState: EdgeDotState { dotState }
    var debugWindow: NSWindow? { window }
    /// For a headless test: the panel counts as shown (pinned) without a window, so a hide can be seen.
    func debugRevealWithoutWindow() { _ = reveal.showPinned() }
    /// The hover and click-outside area now (screen coordinates).
    var debugHoverFrame: NSRect { hoverFrame }
    /// For a windowed test: shows the panel invisible and click-through, so only the test's own events reach it.
    func debugPresentQuietly(section: EdgePanelModel.Section?, on screen: NSRect) {
        _ = reveal.showPinned()
        present(section: section, on: screen, animated: false)
        removeMonitors()
        window?.alphaValue = 0
        window?.ignoresMouseEvents = true
    }

    /// The card as it looks now, over a flat backdrop (the window's own pixels).
    func debugSnapshot(backdrop: NSColor = NSColor(white: 0.30, alpha: 1)) -> NSBitmapImageRep? {
        guard let view = window?.contentView else { return nil }
        let local = NSRect(origin: .zero, size: EdgePanelLayout.windowSize)
        let disc = EdgePanelLayout.dockFrame(window: local)
        let card = model.section == nil ? disc : EdgePanelLayout.listFrame(window: local, card: model.cardSize).union(disc)
        let crop = card.insetBy(dx: -16, dy: -16)
        guard let rep = view.bitmapImageRepForCachingDisplay(in: crop) else { return nil }
        view.cacheDisplay(in: crop, to: rep)
        guard let out = NSBitmapImageRep.rgba(pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh),
              let ctx = NSGraphicsContext(bitmapImageRep: out) else { return rep }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        backdrop.setFill()
        NSRect(x: 0, y: 0, width: out.pixelsWide, height: out.pixelsHigh).fill()
        rep.draw(in: NSRect(x: 0, y: 0, width: out.pixelsWide, height: out.pixelsHigh), from: .zero, operation: .sourceOver,
                 fraction: 1, respectFlipped: false, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        out.size = crop.size
        return out
    }
}
