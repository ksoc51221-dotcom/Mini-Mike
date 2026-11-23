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

/// What keeps the panel from showing: a drag (a mouse button is down), a snip, point to ask, or a full-screen app or
/// video on that screen. Any one is enough.
enum EdgeBlock {
    static func blocked(mouseButtonsDown: Int, snipping: Bool, pointing: Bool, fullScreen: Bool) -> Bool {
        mouseButtonsDown != 0 || snipping || pointing || fullScreen
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

    /// The front app shows a window that covers the whole screen (a full-screen app or video). Bounds are top-left based,
    /// like `CGWindowListCopyWindowInfo` gives them; `screen` must be in the same coordinates.
    static func coversScreen(_ windowBounds: [CGRect], screen: CGRect) -> Bool {
        windowBounds.contains { $0.insetBy(dx: -1, dy: -1).contains(screen) }
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
    /// The thin halo ring outside the disc. The round items sit on it.
    static let ringRadius: CGFloat = 160
    static let itemSize: CGFloat = 44
    /// The angle between two neighbouring items on the ring, in degrees (a 55.6 pt chord: 11 pt clear between 44 pt items).
    static let itemStep: CGFloat = 20
    /// Chats, Notes and up to `DockAppStore.maxPinned` apps.
    static let maxItems = 2 + DockAppStore.maxPinned
    /// The Spotify cover inside the disc (half of it behind the screen edge) and the small "+" button.
    static let coverSize: CGFloat = 72
    static let plusSize: CGFloat = 28
    /// A pinned app's icon image on its ring item (the whole icon, its transparent margin included).
    static let appIconSize: CGFloat = 36
    /// From the list card's right side to the screen edge: the ring, half an item and the gap.
    static var listInset: CGFloat { ringRadius + itemSize / 2 + gap }

    /// The dock: the disc, the ring and every item on it (fixed, sized for `maxItems`). The circles' centre is the
    /// middle of its right side.
    static var dockSize: CGSize {
        let half = (CGFloat(maxItems - 1) / 2 * itemStep) * .pi / 180
        let h = max(ringRadius, ringRadius * sin(half) + itemSize / 2)
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

    /// The disc's three small buttons ("+", search, collapse): one column, `discButtonGap` apart, centred on the disc's
    /// vertical centre, `discButtonInset` in from the screen edge (left of the record and its waves).
    static let discButtonGap: CGFloat = 36
    static let discButtonInset: CGFloat = 80
    static func discButtonCentre(_ row: Int) -> CGPoint {
        CGPoint(x: dockSize.width - discButtonInset, y: dockSize.height / 2 + CGFloat(row - 1) * discButtonGap)
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

    /// The Spotify card: a playing song (cover, title, artist, three buttons) or one plain line.
    static func spotifySize(track: Bool) -> CGSize { CGSize(width: listWidth, height: track ? 132 : 76) }
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

    init(apps: @autoclosure @escaping () -> DockAppStore = .shared, spotify: SpotifyService = .shared) {
        makeApps = apps
        self.spotify = spotify
        // The dock redraws when the pinned apps (see `apps`), the song or its colours change.
        forwards.append(spotify.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() })
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

    func openSearch() {
        guard !searchOpen else { return }
        hoverWork?.cancel()
        query = ""
        withAnimation(Motion.still || Motion.reduceMotion ? nil : Motion.edgeIn) {
            section = nil
            searchOpen = true
        }
        onSearchChange?(true)
    }

    /// Esc, a click outside, loss of the keyboard, an app opening or the dock hiding: the field closes and the query clears.
    func closeSearch() {
        guard searchOpen else { return }
        withAnimation(Motion.still || Motion.reduceMotion ? nil : Motion.edgeOut) {
            searchOpen = false
            query = ""
        }
        onSearchChange?(false)
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
    @Published var section: Section?
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
        case .spotify: return EdgePanelLayout.spotifySize(track: track != nil)
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
    /// An app on the ring: opens it, then the panel hides (like a chat row).
    func tapApp(_ app: DockApp) {
        closeSearch()
        apps.open(app)
        onOpenApp?(app)
    }
    /// The cover (or the Spotify glyph): the Spotify card.
    func tapSpotify() { toggle(.spotify) }
    /// "+": the add/remove card (it reads the installed apps the first time).
    func tapManageApps() {
        apps.loadInstalled()
        toggle(.apps)
    }
    func tapSpotifyCommand(_ c: SpotifyCommand) { spotify.send(c) }
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
        let panel = HStack(alignment: .center, spacing: EdgePanelLayout.gap) {
            if let section = model.section {
                listCard(section)
                    .transition(Motion.reduceMotion ? .opacity : .scale(scale: 0.96, anchor: .trailing).combined(with: .opacity))
            }
            EdgeDockView(model: model)
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

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.hairline.color).frame(height: 1)
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
                Rectangle().fill(Theme.hairline.color).frame(height: 1)
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
                    .fill(on ? Theme.surfaceSelected.color : .clear))
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
                    .fill(row.isOpen ? Theme.surfaceSelected.color : (hovering ? Theme.surfaceRaised.color : .clear)))
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
                                   tint: row.starred ? Theme.ink.color : Theme.inkSecondary.color) { model.tapStar(row.id) }
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
                .fill(hovering ? Theme.surfaceRaised.color : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(EdgePressStyle())
        .help(row.title)
        .edgeHover { h in withAnimation(Motion.still ? nil : Motion.animation(Motion.small)) { hovering = h } }
    }
}

private struct EdgeNewNoteRow: View {
    let action: () -> Void
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
                .fill(hovering ? Theme.surfaceRaised.color : .clear))
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
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hovering ? Theme.ink.color : tint)
                .frame(width: 24, height: 24)
                .background(Circle().fill(hovering ? Theme.surfaceSelected.color : .clear))
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

    var body: some View {
        Group {
            switch phase {
            case .idle: Circle().strokeBorder(Theme.inkSecondary.color, lineWidth: 1.5)
            // The accent's text tone: the plain accent can be too pale on a light card for a mark this small.
            case .working: EdgeBreathing { Circle().fill(Theme.accentText.color) }
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

/// The panel's window: a non-activating panel that takes the keyboard only while the search field is open (the front app
/// stays active), takes the first click, and its transparent parts let clicks through.
final class EdgePanelWindow: FloatingPanel {
    /// Set by the controller from `EdgePanelModel.searchOpen`.
    var searchOpen = false
    override var canBecomeKey: Bool { searchOpen }

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
        let over = reveal.visible && (model.searchOpen || hoverFrame.insetBy(dx: -6, dy: -6).contains(p))
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

    /// A drag (a mouse button is down), a snip, point to ask, or a full-screen app or video on that screen.
    private func liveBlocked(at p: NSPoint, screens: [NSRect]) -> Bool {
        // The cheap ones first; the window list is read only when they all say go.
        if EdgeBlock.blocked(mouseButtonsDown: NSEvent.pressedMouseButtons, snipping: Snipper.isActive, pointing: isBlocked(), fullScreen: false) {
            return true
        }
        guard let s = EdgeGeometry.screen(containing: p, screens: screens) else { return false }
        return EdgeBlock.blocked(mouseButtonsDown: 0, snipping: false, pointing: false,
                                 fullScreen: Self.frontAppIsFullScreen(on: s, primary: screens.first ?? s))
    }

    /// The front app has an on-screen window covering the whole screen: a full-screen app or video. Read only while the
    /// pointer waits in the hot zone (a handful of times), never on every move.
    private static func frontAppIsFullScreen(on screen: NSRect, primary: NSRect) -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        let bounds: [CGRect] = list.compactMap { info in
            guard (info[kCGWindowOwnerPID as String] as? Int32) == front.processIdentifier,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let b = info[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b) else { return nil }
            return r
        }
        let flipped = CGRect(x: screen.minX, y: primary.maxY - screen.maxY, width: screen.width, height: screen.height)
        return EdgeGeometry.coversScreen(bounds, screen: flipped)
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
        model.closeSearch() // gives the keyboard back before the panel leaves
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
            // Tab (the first key of a hold-Tab chord reaches the panel before the tap sees the second) would move the
            // focus out of the field.
            if e.type == .keyDown, e.keyCode == 48, self.model.searchOpen, e.window === self.window { return nil }
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
        window.searchOpen = open
        if open {
            guard reveal.visible, window.isVisible else { return }
            keyBeforeSearch = NSApp.isActive ? NSApp.keyWindow : nil
            window.makeKey()
            if resignObserver == nil {
                resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window,
                                                                        queue: .main) { [weak self] _ in
                    self?.model.closeSearch() // a click in another app or window
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
        cardFrame.union(EdgePanelLayout.dockFrame(window: EdgePanelLayout.windowFrame(screen: screen)))
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
