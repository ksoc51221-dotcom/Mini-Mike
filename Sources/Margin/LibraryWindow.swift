import AppKit
import SwiftUI

/// Where the dashboard hands off to windows other agents own. The app sets these; until it does, the sidebar's "New sector" row
/// does nothing and Settings falls back to the old menu.
enum LibraryHooks {
    static var openSectorEditor: (() -> Void)?
    static var openSettings: (() -> Void)?
}

/// The dashboard's window. It floats over whatever you're doing and opens on the Space you're on, WITHOUT switching you to
/// Margin: the app you were using stays the active one (like the chats), so ⌘⇧L never pulls you out of your work.
final class LibraryPanel: NSPanel {
    /// False for a demo or a test running while you work, so clicking the window can't pull your typing into it.
    var allowsKey = true
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}

/// "History, Notebook, Screenshots & Bin": every saved chat filed by sector, searchable, the notes you kept, every screenshot
/// you took, and what you deleted in the last 30 days.
final class LibraryWindow {
    static let shared = LibraryWindow()
    /// Opens a chat about something from the library (set by the app).
    var onAsk: ((_ selection: String, _ prompt: String) -> Void)?
    /// Opens a chat about a screenshot (its picture as a JPEG, and the app it came from).
    var onAskImage: ((_ jpeg: Data, _ appName: String) -> Void)?
    /// Starts a new, empty chat (the sidebar's New Chat button).
    var onNewChat: (() -> Void)?

    private var window: LibraryPanel?
    private let state = LibraryState()
    /// For a test running while you work: the window is invisible, passes your clicks through, and never takes the keyboard.
    var quiet = false

    /// ⌘⇧L: opens the history, or puts it away if it's showing.
    func toggle() {
        if let window, window.isVisible, state.mode == .chats {
            window.orderOut(nil)
        } else {
            show()
        }
    }

    var isVisible: Bool { window?.isVisible == true }
    var debugMode: LibraryState.Mode { state.mode }
    var debugWindow: NSWindow? { window }
    var debugState: LibraryState { state }
    func debugAllowKey(_ on: Bool) { window?.allowsKey = on }
    /// A demo or test on your screen: real clicks pass through it (a test sends its own clicks straight to the window).
    func debugClickThrough(_ on: Bool) { window?.ignoresMouseEvents = on }

    func show(notebook: Bool = false) { show(mode: notebook ? .notebook : .chats) }

    func show(mode: LibraryState.Mode, takeKeyboard: Bool = true) {
        if mode == .chats, !isVisible {
            // A plain "open the Library" lands where Settings say. (The menu's Notebook, Screenshots and Bin go where they name.)
            // "Last used" is what the state already holds while the app runs; a fresh launch restores it from Settings.
            let s = Settings.shared
            if s.libraryDefaultView != .last || window == nil { state.apply(defaultView: s.libraryDefaultView, last: s.libraryLastView) }
        } else {
            state.mode = mode
        }
        Library.shared.applyRetention() // what's outlived the Bin / screenshot settings goes now, before you look at it
        if window == nil {
            let host = NSHostingController(rootView: ThemedRoot { LibraryView(
                state: state,
                onAsk: { [weak self] s, p in self?.onAsk?(s, p) },
                onAskImage: { [weak self] data, app in self?.onAskImage?(data, app) },
                onNewChat: { [weak self] in self?.onNewChat?() }) })
            let w = LibraryPanel(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 700),
                                 styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
            w.contentViewController = host
            w.title = "Margin Dashboard"
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true // the dashboard draws its own top bar; the window's three buttons float over it
            w.backgroundColor = Ink.nsLowest
            w.isMovableByWindowBackground = true
            w.setContentSize(NSSize(width: 1120, height: 700))
            w.minSize = NSSize(width: 920, height: 520)
            w.isReleasedWhenClosed = false
            w.isFloatingPanel = true
            w.level = .floating
            w.hidesOnDeactivate = false
            w.becomesKeyOnlyIfNeeded = false
            // Opens on the Space you're on (also over a full-screen app), and never switches you away.
            w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            w.setFrameAutosaveName("MarginDashboard")
            if !w.setFrameUsingName("MarginDashboard") { w.center() }
            window = w
        }
        // Comes to the front and takes focus. (A demo passes takeKeyboard: false so it never eats your typing.)
        window?.allowsKey = takeKeyboard && !quiet
        window?.ignoresMouseEvents = quiet
        window?.alphaValue = quiet ? 0 : 1 // (set before it's ordered in front, so a quiet test never shows)
        // Only ever called from a click or shortcut (status menu, ⌘⇧L), so taking focus is what you asked for.
        if takeKeyboard && !quiet { NSApp.activate(); window?.makeKeyAndOrderFront(nil); window?.orderFrontRegardless() } else { window?.orderFrontRegardless() }
    }
}

// MARK: - State

/// One thing in the dashboard: a chat, a note or a screenshot.
struct ItemRef: Hashable {
    var kind: BinItem.Kind
    var id: UUID
}

final class LibraryState: ObservableObject {
    enum Mode: Equatable { case all, chats, notebook, screenshots, review, bin }

    /// "Moved to the Bin · Undo": shown for a few seconds after you clear something.
    struct Toast: Equatable {
        var id = UUID()
        var text: String
        /// What Undo puts back.
        var undo: [UUID]
    }

    @Published var mode: Mode = .chats {
        didSet {
            guard mode != oldValue else { return }
            browsing = true
            sector = nil
            kind = nil
            multi = []
            selecting = false
            if let s = selection, !Self.shows(s.kind, in: mode) { selection = nil }
            rememberView()
        }
    }
    /// In the mixed views (All, Bin): show only chats, only notes…
    @Published var kind: BinItem.Kind?
    @Published var sector: String?
    @Published var query = ""
    @Published var selection: ItemRef? {
        didSet { if let selection, !multi.contains(selection) { multi = [] } }
    }
    /// More than one row picked (⌘-click, ⇧-click). Empty when it's just `selection`.
    @Published var multi: Set<ItemRef> = []
    /// The row a ⇧-click extends from.
    var anchor: ItemRef?
    /// False while the Desk is showing (nothing picked, no scope chosen); true once you open a scope or a sector.
    @Published var browsing = false { didSet { if browsing != oldValue { rememberView() } } }
    /// What a drag in progress carries.
    @Published var dragging: [ItemRef] = []
    /// ⌘⇧M: bumped so the open page shows its Move to… list.
    @Published var moveRequest = 0
    /// Only for --uishots, to photograph states that need a pointer: a hovered row, a lifted row and a sector being dropped on.
    @Published var debugHover: ItemRef?
    @Published var debugLift: ItemRef?
    @Published var debugDropTarget: String?
    @Published var newestFirst = true
    @Published var revision = 0
    @Published var toast: Toast?
    /// Bumped by ⌘K so the search box takes the cursor.
    @Published var searchFocus = 0

    init() {
        NotificationCenter.default.addObserver(forName: Library.changed, object: nil, queue: .main) { [weak self] _ in
            self?.revision += 1
        }
    }

    /// Back to the Desk: nothing picked, no scope.
    func goDesk() {
        selection = nil; multi = []; anchor = nil; selecting = false
        sector = nil; kind = nil; query = ""
        if mode != .chats { mode = .chats }
        browsing = false
    }

    var isDesk: Bool { selection == nil && !browsing && mode != .bin }

    /// Where the Library was last left, for the "Last used" setting. The Bin and the Desk both come back as the Desk.
    private func rememberView() {
        let key = (isDesk || mode == .bin) ? "desk" : "\(mode)"
        if Settings.shared.libraryLastView != key { Settings.shared.libraryLastView = key }
    }

    /// Opens on what the Library settings say: the Desk, All, or wherever it was last left.
    func apply(defaultView: LibraryDefaultView, last: String) {
        switch defaultView {
        case .desk: goDesk()
        case .all: goDesk(); mode = .all
        case .last:
            switch last {
            case "all": goDesk(); mode = .all
            case "chats": goDesk(); mode = .chats; browsing = true
            case "notebook": goDesk(); mode = .notebook
            case "screenshots": goDesk(); mode = .screenshots
            case "review": goDesk(); mode = .review
            default: goDesk()
            }
        }
    }

    /// Whether a view of this mode can show a thing of this kind.
    static func shows(_ kind: BinItem.Kind, in mode: Mode) -> Bool {
        switch mode {
        case .all, .bin: return true
        case .chats: return kind == .chat
        case .notebook: return kind == .note
        case .screenshots: return kind == .screenshot
        case .review: return kind == .chat
        }
    }

    var selectedChat: UUID? {
        get { selection?.kind == .chat ? selection?.id : nil }
        set { selection = newValue.map { ItemRef(kind: .chat, id: $0) } }
    }
    var selectedNote: UUID? {
        get { selection?.kind == .note ? selection?.id : nil }
        set { selection = newValue.map { ItemRef(kind: .note, id: $0) } }
    }
    var selectedScreenshot: UUID? {
        get { selection?.kind == .screenshot ? selection?.id : nil }
        set { selection = newValue.map { ItemRef(kind: .screenshot, id: $0) } }
    }

    /// Says what just happened, with a way back, for a few seconds.
    func announce(_ text: String, undo ids: [UUID]) {
        let toast = Toast(text: text, undo: ids)
        withAnimation(DashboardProbe.enabled ? nil : .easeOut(duration: 0.18)) { self.toast = toast }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.toast?.id == toast.id else { return }
            withAnimation(DashboardProbe.enabled ? nil : .easeIn(duration: 0.18)) { self.toast = nil }
        }
    }

    /// Moves one thing to the Bin (nothing is lost: Undo, or the Bin, gets it back). `next` is what to show instead.
    func clear(_ ref: ItemRef, next: ItemRef? = nil) {
        let library = Library.shared
        let noun: String
        switch ref.kind {
        case .chat:
            guard let c = library.chat(ref.id) else { return }
            guard !c.starred else { announce("Starred chats can't be deleted. Unstar it first.", undo: []); return }
            library.delete(chat: ref.id); noun = "Chat"
        case .note:
            guard library.notes.contains(where: { $0.id == ref.id }) else { return }
            library.delete(note: ref.id); noun = "Note"
        case .screenshot:
            guard library.screenshot(ref.id) != nil else { return }
            library.delete(screenshot: ref.id); noun = "Screenshot"
        }
        if selection == ref { selection = next }
        announce("\(noun) moved to the Bin", undo: [ref.id])
    }

    /// Moves several things to the Bin at once, with one Undo.
    func clearMany(_ refs: [ItemRef], next: ItemRef? = nil) {
        let library = Library.shared
        var ids: [UUID] = []
        var keptStarred = 0
        for ref in refs {
            switch ref.kind {
            case .chat:
                if let c = library.chat(ref.id) {
                    if c.starred { keptStarred += 1 } else if library.delete(chat: ref.id) { ids.append(ref.id) }
                }
            case .note: if library.notes.contains(where: { $0.id == ref.id }) { library.delete(note: ref.id); ids.append(ref.id) }
            case .screenshot: if library.screenshot(ref.id) != nil { library.delete(screenshot: ref.id); ids.append(ref.id) }
            }
        }
        guard !ids.isEmpty else {
            if keptStarred > 0 { announce("Starred chats can't be deleted. Unstar them first.", undo: []) }
            return
        }
        multi = []
        picked = []
        if let sel = selection, ids.contains(sel.id) { selection = next }
        var text = ids.count == 1 ? "Moved to the Bin" : "\(ids.count) items moved to the Bin"
        if keptStarred > 0 { text += " · \(keptStarred) starred kept" }
        announce(text, undo: ids)
    }

    // MARK: Select mode (mass delete)

    /// "Select" mode: rows get a checkbox, one click picks or drops a row, and the bar at the top deletes the lot.
    @Published var selecting = false {
        didSet { if !selecting { picked = [] } }
    }
    /// What's ticked in select mode (never a starred chat).
    @Published var picked: Set<ItemRef> = []

    /// Whether a row can be ticked: starred chats are protected.
    static func deletable(_ item: FeedItem) -> Bool { !item.starred }

    /// Ticks or unticks a row.
    func toggle(_ item: FeedItem) {
        guard Self.deletable(item) else { return }
        if picked.contains(item.ref) { picked.remove(item.ref) } else { picked.insert(item.ref) }
    }

    /// Ticks every deletable row in the list, or clears them all if everything is already ticked.
    func toggleAll(in feed: [FeedItem]) {
        let all = Set(feed.filter(Self.deletable).map(\.ref))
        picked = (picked == all) ? [] : all
    }

    /// Moves everything ticked to the Bin with one Undo, and leaves select mode.
    func deletePicked(in feed: [FeedItem]) {
        let refs = feed.map(\.ref).filter { picked.contains($0) }
        selecting = false
        guard !refs.isEmpty else { return }
        clearMany(refs, next: nil)
    }

    /// Puts something back from the Bin.
    func restore(_ ref: ItemRef, next: ItemRef? = nil) {
        guard Bin.restore(ref.id) else { return }
        if selection == ref { selection = next }
        announce("Put back", undo: [])
    }

    /// Deletes one thing for good.
    func deleteForever(_ ref: ItemRef, next: ItemRef? = nil) {
        Bin.deleteForever(ref.id)
        if selection == ref { selection = next }
    }

    func undo(_ toast: Toast) {
        for id in toast.undo { _ = Bin.restore(id) }
        withAnimation(DashboardProbe.enabled ? nil : .easeIn(duration: 0.18)) { self.toast = nil }
    }
}

// MARK: - The Bin's actions

/// What restoring and deleting for good mean for each kind of thing.
enum Bin {
    /// Puts a deleted thing back where it was: chats, notes and screenshots into their lists.
    @discardableResult
    static func restore(_ id: UUID) -> Bool {
        Library.shared.restore(id)
    }

    static func deleteForever(_ id: UUID) {
        Library.shared.deleteForever(id)
    }

    static func empty() {
        Library.shared.emptyBin()
    }
}

// MARK: - Look

/// The dashboard's colours: the Instrument tokens under their old short names. Sidebar = surface, panes = canvas, hairlines for structure.
enum Ink {
    static let lowest = Theme.canvas.color
    static let surface = Theme.canvas.color
    /// Sidebars and cards.
    static let side = Theme.surface.color
    static let low = Theme.surfaceRaised.color
    static let container = Theme.surfaceRaised.color
    /// Selected rows (inkTertiary falls to 4.1 on it: meta text there is `onVariant`).
    static let high = Theme.surfaceSelected.color
    static let strong = Theme.hairlineStrong.color
    static let outline = Theme.inkTertiary.color
    static let onSurface = Theme.ink.color
    static let onVariant = Theme.inkSecondary.color
    /// Accent as text.
    static let primary = Theme.accentText.color
    /// Accent fills and marks.
    static let accent = Theme.accent.color
    static let onAccent = Theme.onAccent.color
    static let wash = Theme.accentWash.color
    static let error = Theme.alert.color
    /// Hairlines between panes and rows.
    static let edge = Theme.hairline.color
    static let nsLowest = Theme.canvas.ns
}

extension Font {
    /// Counts and times: Geist Mono with steady digits.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .geistMono(size, weight).monospacedDigit() }
}

/// Sectors are told apart by their glyph, never by colour: this is the one colour left, ink.
func sectorColor(_ name: String) -> Color { Theme.ink.color }

/// A sector's glyph (the user's pick, else the default for its name). Static in lists; `active` on hover or selection.
func sectorGlyph(_ name: String, size: CGFloat = 14, active: Bool = false, animated: Bool = false, color: Color? = nil) -> Glyph {
    Glyph(kind: SectorStore.shared.icon(for: name), size: size, color: color ?? Ink.onSurface, animated: animated, active: active)
}

/// The one list/sidebar mark: a 14pt glyph in an 18pt cell (same left inset and size everywhere), nudged up half a point so its centre
/// sits on the text's cap height rather than its line box. Desk tiles use 20pt, tags 12pt; those are their own contexts.
func sectorMark(_ name: String, active: Bool = false) -> some View {
    sectorGlyph(name, size: 14, active: active).frame(width: 18, height: 18).offset(y: -0.5)
}


enum SectorOrder {
    private static var cache: [String: Int] = [:]
    private static var stamp = -1

    static func index(of name: String) -> Int {
        let library = Library.shared
        let now = library.chats.count &* 7919 &+ library.notes.count &* 104_729 &+ library.screenshots.count &* 15_485_863 &+ library.directory.path.hashValue
        if now != stamp {
            stamp = now
            cache = Dictionary(library.allSectors.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        }
        if let i = cache[name] { return i }
        let stable = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } // (hashValue changes every launch)
        return Sector.defaults.count + stable % 8
    }
}

/// A rounded box with a 1px border drawn as two fills (a stroke leaves notches where it meets itself).
extension View {
    func boxed(_ fill: Color, radius: CGFloat = Theme.Radius.chip, border: Color = Ink.edge) -> some View {
        background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill).padding(1)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(border)))
    }

    /// Primary button look: accent fill, onAccent text, radius 6.
    func primaryButtonLook(height: CGFloat = 26) -> some View {
        font(.mUI.weight(.medium)).foregroundStyle(Ink.onAccent)
            .padding(.horizontal, 12).frame(height: height)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(Ink.accent))
    }

    /// Secondary button look: raised fill with a hairline (two fills), radius 6.
    func secondaryButtonLook(height: CGFloat = 28, tint: Color = Ink.onSurface) -> some View {
        font(.geist(12, .semibold)).foregroundStyle(tint)
            .padding(.horizontal, 12).frame(height: height)
            .boxed(Ink.low, radius: Theme.Radius.chip)
    }

    /// An input: raised fill, hairline border that strengthens on focus, and a 1px accent underline that sweeps in from the left.
    func libField(focused: Bool, radius: CGFloat = Theme.Radius.control) -> some View {
        boxed(Ink.low, radius: radius, border: focused ? Ink.strong : Ink.edge)
            .overlay(alignment: .bottom) { FocusUnderline(on: focused).padding(.horizontal, 1).padding(.bottom, 0) }
            .animation(LibMotion.hover, value: focused)
    }

    /// Fades in and rises 6pt, `index` × 30 ms after the view appears (capped at 8 steps).
    func bootIn(_ index: Int) -> some View { modifier(BootIn(index: index)) }
}

/// The 1px accent line under a focused field: it sweeps in from the left (and out again).
struct FocusUnderline: View {
    let on: Bool
    var body: some View {
        GeometryReader { g in
            Rectangle().fill(Ink.accent)
                .frame(width: on ? g.size.width : 0, height: 1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(on ? 1 : 0)
        }
        .frame(height: 1)
        .clipShape(Rectangle())
        .animation(LibMotion.still ? nil : Motion.animation(Motion.smooth), value: on)
        .accessibilityHidden(true)
    }
}

/// `⌘K` as a keyboard tag: mono text in a 1px hairline box, radius 3.
struct Kbd: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.mMeta).tracking(0.4).foregroundStyle(Ink.outline)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .boxed(Ink.low, radius: Theme.Radius.chip)
            .accessibilityHidden(true)
    }
}

/// "Recent  3": a sentence-case label with its count at the right (hidden at 0). No rule under it.
struct SectionLabel<Trailing: View>: View {
    let title: String
    var count: Int?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            Text(title).mLabelStyle()
            Spacer(minLength: 4)
            trailing
            if let count, let text = Theme.count(count) {
                Text(text).libCount()
                    .contentTransition(.numericText())
                    .animation(LibMotion.small, value: count)
            }
        }
    }
}

extension SectionLabel where Trailing == EmptyView {
    init(_ title: String, count: Int? = nil) {
        self.title = title; self.count = count; self.trailing = EmptyView()
    }
}

extension View {
    /// A count beside a label or row: Geist 13/500 in grey (never mono, never zero padded).
    func libCount(_ color: Color = Ink.outline) -> some View { font(.geist(13, .medium)).monospacedDigit().foregroundStyle(color) }
}

/// The text of a title resolves from random mono characters in ~350 ms, once per appearance. Plain text under Reduce Motion
/// (and in pictures). Mono-only effect: never on body text.
struct DecodeText: View {
    let text: String
    var monoSize: CGFloat = 26
    @State private var resolved: Int
    @State private var noise = ""
    private static let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ0123456789#%&/<>+=")
    private static var skip: Bool { LibMotion.still || LibMotion.reduce }

    init(_ text: String, monoSize: CGFloat = 26) {
        self.text = text
        self.monoSize = monoSize
        _resolved = State(initialValue: Self.skip ? text.count : 0)
    }

    var body: some View {
        let head = String(text.prefix(resolved))
        let tail = String(text.dropFirst(resolved)).map { $0 == " " ? " " : String(noise.randomElement() ?? "·") }.joined()
        (Text(head) + Text(tail).font(.geistMono(monoSize, .medium)).foregroundStyle(Ink.outline))
            .lineLimit(1)
            .accessibilityLabel(text)
            .task(id: text) {
                guard !Self.skip else { resolved = text.count; return }
                noise = String(Self.alphabet)
                resolved = 0
                let frames = 12
                for f in 1...frames {
                    try? await Task.sleep(nanoseconds: 29_000_000)
                    resolved = Int((Double(text.count) * Double(f) / Double(frames)).rounded(.down))
                }
                resolved = text.count
            }
    }
}

/// A quote from the page: a 2px neutral bar at the left, Geist Italic in secondary ink, a "Selection · Safari" label above.
struct LibQuote: View {
    let text: String
    var app = ""
    var lineLimit: Int?

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Rectangle().fill(Ink.strong).frame(width: 2)
            VStack(alignment: .leading, spacing: 6) {
                Text(app.isEmpty ? "Selection" : "Selection · \(app)").mLabelStyle().lineLimit(1)
                Text(text).font(.mQuote).foregroundStyle(Ink.onVariant).lineSpacing(3).lineLimit(lineLimit)
                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 12)
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
        .help(text)
    }
}

/// Detail open: blur 8 -> 0, fade and a 12pt slide from the right.
private struct BlurSlide: ViewModifier {
    let amount: Double // 1 = hidden, 0 = shown
    func body(content: Content) -> some View {
        content.blur(radius: 8 * amount).opacity(1 - amount).offset(x: 12 * amount)
    }
}

extension AnyTransition {
    static var detailOpen: AnyTransition {
        LibMotion.reduce || LibMotion.still
            ? .opacity
            : .asymmetric(insertion: .modifier(active: BlurSlide(amount: 1), identity: BlurSlide(amount: 0)), removal: .opacity)
    }
}

/// Where the dashboard's buttons are drawn, so --bintest can click them. Only filled in while a test runs.
enum DashboardProbe {
    static var enabled = false
    /// Frames in the window's own space (top-left origin), by name ("clear:<id>", "restore:<id>", "undo"…).
    static var frames: [String: CGRect] = [:]
    /// Whether the list has the keyboard (for the Delete key).
    static var listFocused = false
}

private struct ProbeKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue()) { $1 } }
}

extension View {
    func probe(_ name: String?) -> some View {
        background(GeometryReader { g in
            Color.clear.preference(key: ProbeKey.self, value: DashboardProbe.enabled && name != nil ? [name!: g.frame(in: .global)] : [:])
        })
    }
}

struct HLine: View { var body: some View { Ink.edge.frame(height: 1) } }
struct VLine: View { var body: some View { Ink.edge.frame(width: 1) } }

// MARK: - What the lists show

/// A row in the lists: a chat, a note or a screenshot.
struct FeedItem: Identifiable, Equatable {
    var ref: ItemRef
    var id: ItemRef { ref }
    var title: String
    var sector: String
    var snippet: String
    /// What the list sorts and groups by (when you deleted it, in the Bin).
    var date: Date
    var thumb: URL?
    /// Days until it's deleted for good (Bin only).
    var daysLeft: Int?
    /// A chat you have been quizzed on.
    var quizzed = false
    /// What was highlighted (the stand-in for a bad title).
    var quote = ""
    /// A starred chat: pinned to the top, and it can't be deleted.
    var starred = false
    /// In "To review" (a quiz you missed, or you put it there).
    var inReview = false

    var headline: (text: String, quoted: Bool) { Feed.headline(title: title, quote: quote) }

    var kindName: String {
        switch ref.kind {
        case .chat: return "Chat"
        case .note: return "Note"
        case .screenshot: return "Shot"
        }
    }

    /// The dot beside the sector: a sector's own color.
    var dot: Color { sectorColor(sector) }

    /// What kind of thing it is, for the lists that mix them.
    var symbol: String {
        switch ref.kind {
        case .chat: return "bubble.left.fill"
        case .note: return "bookmark.fill"
        case .screenshot: return "camera.fill"
        }
    }

    init(chat: ChatRecord) {
        ref = ItemRef(kind: .chat, id: chat.id)
        title = chat.title; sector = chat.sector; snippet = chat.snippet; date = chat.updated
        quizzed = !chat.quizzes.isEmpty
        quote = chat.quote
        starred = chat.starred
        inReview = chat.inReview
    }

    init(note: Note) {
        ref = ItemRef(kind: .note, id: note.id)
        title = note.question; sector = note.sector; snippet = note.body.replacingOccurrences(of: "\n", with: " "); date = note.created
        quote = note.quote
    }

    init(shot: ScreenshotRecord, library: Library) {
        ref = ItemRef(kind: .screenshot, id: shot.id)
        title = shot.title; sector = shot.sector; snippet = shot.snippet; date = shot.created
        thumb = library.imageURL(for: shot)
    }

    init(binned item: BinItem, library: Library, now: Date = Date()) {
        ref = ItemRef(kind: item.kind, id: item.id)
        title = item.title; sector = item.sector; snippet = String(item.snippet.prefix(160)); date = item.deleted
        daysLeft = Library.binDays > 0 ? library.daysLeft(item, now: now) : nil
        quote = item.chat?.quote ?? item.note?.quote ?? ""
        if let s = item.screenshot { thumb = library.imageURL(for: s) }
    }
}

struct FeedGroup: Identifiable {
    var label: String
    var items: [FeedItem]
    var id: String { label }
}

enum Feed {
    /// Starred rows first, each half keeping its order.
    static func starredFirst(_ items: [FeedItem]) -> [FeedItem] {
        items.filter(\.starred) + items.filter { !$0.starred }
    }

    /// Today, Yesterday, Previous 7 days, Previous 30 days, then a month.
    static func dayLabel(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days <= 0 { return "Today" }
        if days == 1 { return "Yesterday" }
        if days < 7 { return "Previous 7 days" }
        if days < 30 { return "Previous 30 days" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "MMMM yyyy"
        return f.string(from: date)
    }

    /// Items already in order: the starred ones first under "Starred", then runs under the same day label.
    static func groups(_ items: [FeedItem], now: Date = Date(), calendar: Calendar = .current) -> [FeedGroup] {
        var out: [FeedGroup] = []
        let stars = items.filter(\.starred)
        if !stars.isEmpty { out.append(FeedGroup(label: "Starred", items: stars)) }
        for item in items where !item.starred {
            let label = dayLabel(item.date, now: now, calendar: calendar)
            if let last = out.last, last.label == label { out[out.count - 1].items.append(item) } else { out.append(FeedGroup(label: label, items: [item])) }
        }
        return out
    }

    /// A title Margin shouldn't lead with: fewer than 3 words, or all lowercase ("answer", "how to do 10 b").
    static func isBadTitle(_ title: String) -> Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.split(whereSeparator: { $0.isWhitespace }).count < 3 { return true }
        return t == t.lowercased() && t.contains(where: { $0.isLetter })
    }

    /// The first few words of what was highlighted, for a row whose title is bad.
    static func quoteWords(_ quote: String, words: Int = 7) -> String {
        let parts = quote.split(whereSeparator: { $0.isWhitespace })
        let head = parts.prefix(words).joined(separator: " ")
        return parts.count > words ? head + "…" : head
    }

    /// What a row leads with, and whether it's the quote standing in (set in italic).
    static func headline(title: String, quote: String) -> (text: String, quoted: Bool) {
        if isBadTitle(title), !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return (quoteWords(quote), true) }
        return (title, false)
    }

    /// "now", "5m", "2h", "Yesterday", "Mon", "12 Oct".
    static func ago(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let s = max(0, now.timeIntervalSince(date))
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if s < 86_400 && days <= 0 { return "\(Int(s / 3600))h" }
        if days <= 1 { return "Yesterday" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.calendar = calendar; f.timeZone = calendar.timeZone
        f.dateFormat = days < 7 ? "EEE" : "d MMM"
        return f.string(from: date)
    }

    /// "computer_science" / "avoiding-the-vibe-coded-look": for the path across the top of a page.
    static func slug(_ text: String, separator: Character = "-", limit: Int = 40) -> String {
        var out = ""
        var pendingSeparator = false
        for ch in text.lowercased() {
            if ch.isLetter || ch.isNumber {
                if pendingSeparator, !out.isEmpty { out.append(separator) }
                pendingSeparator = false
                out.append(ch)
            } else {
                pendingSeparator = true
            }
        }
        return String(out.prefix(limit))
    }

    /// Reading time for the top of a page: "3 min read · 840 words".
    static func readingTime(_ text: String) -> String {
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        return "\(max(1, Int((Double(words) / 200).rounded()))) min read · \(words) word\(words == 1 ? "" : "s")"
    }
}
// MARK: - Motion

/// The dashboard's motion in one place, on the shared Motion tokens. A picture, a test or Reduce Motion gets opacity changes only.
enum LibMotion {
    static var still: Bool { Motion.still || DashboardProbe.enabled }
    static var reduce: Bool { Motion.reduceMotion }
    /// Panels: the detail opening, the Desk and the list trading places.
    static var panel: Animation? { still ? nil : Motion.animation(Motion.smooth) }
    /// Small controls: the selection bar, a row collapsing, counts rolling.
    static var small: Animation? { still ? nil : Motion.animation(Motion.snappy) }
    static var hover: Animation? { still ? nil : .easeOut(duration: 0.12) }
}

/// Boot / stagger: fades in and rises, 30 ms apart (the first 8 only).
private struct BootIn: ViewModifier {
    let index: Int
    var rise: CGFloat = 6
    @State private var shown: Bool

    init(index: Int, rise: CGFloat = 6) {
        self.index = index
        self.rise = rise
        _shown = State(initialValue: LibMotion.still || index >= 8)
    }

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || LibMotion.reduce ? 0 : rise)
            .onAppear {
                guard !shown else { return }
                let a = Motion.animation(.easeOut(duration: 0.26)).delay(LibMotion.reduce ? 0 : Double(index) * 0.03)
                withAnimation(a) { shown = true }
            }
    }
}

/// A row leaving: its height folds away while it fades.
private struct Fold: ViewModifier {
    let amount: Double // 1 = gone
    func body(content: Content) -> some View {
        content.opacity(1 - amount).scaleEffect(x: 1, y: max(0.001, 1 - amount), anchor: .top)
    }
}

// MARK: - The window

struct LibraryView: View {
    @ObservedObject var state: LibraryState
    let onAsk: (_ selection: String, _ prompt: String) -> Void
    var onAskImage: (_ jpeg: Data, _ appName: String) -> Void = { _, _ in }
    var onNewChat: () -> Void = {}
    @State private var confirmClear = false
    @State private var confirmClearShots = false
    @State private var confirmEmpty = false
    @State private var assistantOpen = LibraryView.debugAssistantOpen
    /// Pictures open the Assistant's card this way.
    nonisolated(unsafe) static var debugAssistantOpen = false
    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool
    @Namespace private var rowSelection
    @Namespace private var navSelection

    private var library: Library { Library.shared }

    var body: some View {
        let _ = state.revision // refresh when the library changes
        let feed = state.isDesk ? [] : makeFeed()
        HStack(spacing: 0) {
            sidebar.frame(width: 224).zIndex(1)
            VLine()
            ZStack {
                if state.isDesk {
                    DeskView(library: library, onOpen: { openFromDesk($0) }, onSector: { open(.all, sector: $0) },
                             onNewChat: onNewChat)
                        .transition(.opacity)
                } else {
                    HStack(spacing: 0) {
                        listPane(feed).frame(width: 336)
                        VLine()
                        detailPane(feed).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(LibMotion.panel, value: state.isDesk)
        }
        .background(Ink.lowest)
        .overlay(alignment: .bottomLeading) {
            if assistantOpen {
                AssistantCard { withAnimation(LibMotion.panel) { assistantOpen = false } }
                    .padding(.leading, 236).padding(.bottom, 16)
                    .transition(LibMotion.reduce ? .opacity : .opacity.combined(with: .scale(scale: 0.95, anchor: .bottomLeading)))
            }
        }
        .onPreferenceChange(ProbeKey.self) { DashboardProbe.frames = $0 }
        .ignoresSafeArea(.container, edges: .top) // the sidebar takes the title bar's place
        .onChange(of: state.searchFocus) { _, _ in searchFocused = true }
        .onChange(of: listFocused) { _, focused in DashboardProbe.listFocused = focused }
        .onChange(of: state.query) { _, q in if !q.isEmpty { state.browsing = true } }
        .onExitCommand { state.goDesk() }
        .background(Button("") { state.moveRequest += 1 }.keyboardShortcut("m", modifiers: [.command, .shift]).opacity(0).frame(width: 0, height: 0))
        .confirmationDialog("Move every saved chat to the Bin?", isPresented: $confirmClear) {
            Button("Move all chats to the Bin", role: .destructive) {
                let ids = library.deleteAllChats()
                if state.mode == .chats || state.mode == .all { state.selection = nil }
                if !ids.isEmpty { state.announce("\(ids.count) chat\(ids.count == 1 ? "" : "s") moved to the Bin", undo: ids) }
            }
        } message: { Text("Starred chats and your notes aren't touched. You can put the rest back from the Bin \(Library.binDays > 0 ? "for \(Library.binDays) days" : "until you empty it").") }
        .confirmationDialog("Move every saved screenshot to the Bin?", isPresented: $confirmClearShots) {
            Button("Move all screenshots to the Bin", role: .destructive) {
                let ids = library.deleteAllScreenshots()
                if state.mode == .screenshots || state.mode == .all { state.selection = nil }
                if !ids.isEmpty { state.announce("\(ids.count) screenshot\(ids.count == 1 ? "" : "s") moved to the Bin", undo: ids) }
            }
        } message: { Text("Only Margin's copies move. The files macOS saved in your screenshots folder aren't touched.") }
        .confirmationDialog("Empty the Bin?", isPresented: $confirmEmpty) {
            Button("Delete everything in the Bin for good", role: .destructive) {
                Bin.empty()
                state.selection = nil
            }
        } message: { Text("\(library.binned.count) item\(library.binned.count == 1 ? "" : "s") will be deleted for good. This can't be undone.") }
    }

    // MARK: Going places

    /// Opens a scope (and a sector inside it) and shows its first thing, so the right side is never empty.
    private func open(_ mode: LibraryState.Mode, sector: String? = nil) {
        withAnimation(LibMotion.panel) {
            state.mode = mode
            state.sector = sector
            state.browsing = true
            let feed = makeFeed()
            if let sel = state.selection, feed.contains(where: { $0.ref == sel }) { return }
            state.selection = feed.first?.ref
            state.anchor = state.selection
        }
    }

    private func openFromDesk(_ ref: ItemRef) {
        withAnimation(LibMotion.panel) {
            state.browsing = true
            state.selection = ref
            state.anchor = ref
        }
        listFocused = true
    }

    // MARK: Sidebar

    private var activeKey: String {
        if state.isDesk { return "desk" }
        if let s = state.sector { return "sector:" + s }
        return "mode:\(state.mode)"
    }

    private var sidebar: some View {
        let total = library.chats.count + library.notes.count + library.screenshots.count
        return VStack(spacing: 0) {
            Color.clear.frame(height: 34) // the window's close, minimize and zoom buttons
            HStack(spacing: 8) {
                searchField
                newChatButton
            }
            .padding(.horizontal, 12).padding(.bottom, 12)
            .bootIn(0)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(spacing: 2) {
                        NavRow(symbol: "square.grid.2x2", activeSymbol: "square.grid.2x2.fill", title: "Desk", count: 0, active: state.isDesk, ns: navSelection) {
                            withAnimation(LibMotion.panel) { state.goDesk() }
                        }
                    }
                    .padding(.horizontal, 10).padding(.top, 2)
                    .bootIn(1)

                    sidebarHeader("Library", count: total).bootIn(2)
                    VStack(spacing: 2) {
                        navRow("square.stack.3d.up", "square.stack.3d.up.fill", "All", library.chats.count + library.notes.count + library.screenshots.count, .all)
                        navRow("bubble.left.and.bubble.right", "bubble.left.and.bubble.right.fill", "Chats", library.chats.count, .chats)
                        navRow("book", "book.fill", "Notes", library.notes.count, .notebook)
                        navRow("camera.viewfinder", "camera.viewfinder", "Screenshots", library.screenshots.count, .screenshots)
                        navRow("bookmark", "bookmark.fill", "To review", Review.chats(library.chats).count, .review)
                    }
                    .padding(.horizontal, 10)
                    .bootIn(3)

                    if state.mode != .bin {
                        sidebarHeader("Sectors", count: sectorRows.count, trailing: LibraryHooks.openSectorEditor.map { edit in
                            AnyView(Button("Edit", action: edit).buttonStyle(.plain).mLabelStyle()
                                .foregroundStyle(Ink.onVariant).help("Edit sectors").accessibilityLabel("Edit sectors"))
                        }).bootIn(4)
                        VStack(spacing: 1) {
                            ForEach(sectorRows, id: \.name) { s in sectorRow(s.name, s.count) }
                            NewSectorRow { LibraryHooks.openSectorEditor?() }
                        }
                        .padding(.horizontal, 10)
                        .bootIn(5)
                    }
                }
                .padding(.bottom, 12)
            }
            .mask(VStack(spacing: 0) { // the list fades out above the Assistant instead of being cut off
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 18)
            })
            Rectangle().fill(Ink.onSurface.opacity(0.16)).frame(height: 1).padding(.horizontal, 10).padding(.top, 4)
            AssistantOrbButton(open: assistantOpen) { withAnimation(LibMotion.panel) { assistantOpen.toggle() } }
                .padding(.horizontal, 10).padding(.top, 6)
                .bootIn(6)
            VStack(spacing: 0) {
                NavRow(symbol: "trash", activeSymbol: "trash.fill", title: "Bin", count: 0, active: !state.isDesk && state.mode == .bin, ns: navSelection,
                       hoverNote: Library.binDays > 0 ? "Empties after \(Library.binDays) days" : "Empties when you empty it") { open(.bin) }
                    .help(Library.binDays > 0 ? "Empties after \(Library.binDays) days" : "Empties when you empty it")
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            HLine()
            footer.bootIn(6)
        }
        .animation(LibMotion.small, value: activeKey)
        .background(Ink.side)
    }

    /// New chat: a neutral bordered button (the lime is kept for one primary per view). It folds away while the search field has the cursor.
    private var newChatButton: some View {
        Button(action: onNewChat) {
            Image(systemName: "plus").font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.onSurface)
                .frame(width: 28, height: 28)
                .boxed(Ink.low, radius: Theme.Radius.chip)
        }
        .buttonStyle(LibPressStyle())
        .keyboardShortcut("n", modifiers: .command)
        .help("New chat (⌘N)").accessibilityLabel("New Chat")
        .frame(width: searchFocused ? 0 : 28)
        .opacity(searchFocused ? 0 : 1)
        .clipped()
        .padding(.leading, searchFocused ? -8 : 0)
        .animation(LibMotion.still ? nil : Motion.animation(Motion.smooth), value: searchFocused)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Ink.outline)
            TextField("Search", text: $state.query)
                .textFieldStyle(.plain).font(.mUI).foregroundStyle(Ink.onSurface)
                .focused($searchFocused)
                .onKeyPress(.escape) {
                    if !state.query.isEmpty { state.query = "" } else { searchFocused = false }
                    return .handled
                }
            if state.query.isEmpty {
                Kbd("⌘K")
            } else {
                Button { state.query = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(Ink.outline) }
                    .buttonStyle(.plain).help("Clear the search").accessibilityLabel("Clear the search")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .libField(focused: searchFocused)
        .background(Button("") { state.searchFocus += 1 }.keyboardShortcut("k", modifiers: .command).opacity(0).frame(width: 0, height: 0))
        .background(Button("") { state.searchFocus += 1 }.keyboardShortcut("f", modifiers: .command).opacity(0).frame(width: 0, height: 0))
    }

    /// The settings (also behind "Settings" at the bottom left, until the settings window is hooked up).
    @ViewBuilder
    private var settingsItems: some View {
        Toggle("Save chat history", isOn: Binding(get: { Settings.shared.saveHistory },
                                                  set: { Settings.shared.saveHistory = $0; state.revision += 1 }))
        Toggle("Name chats when I close them", isOn: Binding(get: { Settings.shared.nameChatsOnClose },
                                                             set: { Settings.shared.nameChatsOnClose = $0; state.revision += 1 }))
        Toggle("Also write kept notes to Documents/Margin Notes",
               isOn: Binding(get: { Settings.shared.mirrorNotes }, set: { Settings.shared.mirrorNotes = $0; state.revision += 1 }))
        Toggle("Save my screenshots here automatically",
               isOn: Binding(get: { Settings.shared.saveScreenshots }, set: { Settings.shared.saveScreenshots = $0; state.revision += 1 }))
        Divider()
        Button("Show the library in Finder") { NSWorkspace.shared.activateFileViewerSelecting([library.directory]) }
        Divider()
        Button("Move all chats to the Bin…", role: .destructive) { confirmClear = true }
        Button("Move all screenshots to the Bin…", role: .destructive) { confirmClearShots = true }
        Button("Empty the Bin…", role: .destructive) { confirmEmpty = true }.disabled(library.binned.isEmpty)
    }

    private func sidebarHeader(_ title: String, count: Int? = nil, trailing: AnyView? = nil) -> some View {
        SectionLabel(title: title, count: count) { trailing }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 6)
    }

    private func navRow(_ symbol: String, _ activeSymbol: String, _ title: String, _ count: Int, _ mode: LibraryState.Mode, glyph: GlyphKind? = nil) -> some View {
        NavRow(symbol: symbol, activeSymbol: activeSymbol, title: title, count: count, glyph: glyph,
               active: !state.isDesk && state.mode == mode && state.sector == nil, ns: navSelection) {
            open(mode)
        }
    }

    private func sectorRow(_ name: String, _ count: Int) -> some View {
        SectorRow(name: name, count: count, active: !state.isDesk && state.sector == name, ns: navSelection,
                  forcedTarget: state.debugDropTarget == name,
                  onTap: { open(state.isDesk || state.mode == .bin ? .all : state.mode, sector: state.sector == name ? nil : name) },
                  onDrop: { dropOn(name) })
    }

    /// The sectors in use for what's showing, with how many each holds.
    private var sectorRows: [(name: String, count: Int)] {
        switch state.isDesk ? .all : state.mode {
        case .chats: return library.usedSectors.map { ($0.name, $0.chats) }.filter { $0.1 > 0 }
        case .notebook: return library.usedSectors.map { ($0.name, $0.notes) }.filter { $0.1 > 0 }
        case .screenshots: return library.usedScreenshotSectors.map { ($0.name, $0.count) }
        case .review:
            let due = Review.chats(library.chats).map(\.chat)
            return library.usedSectors.map { s in (s.name, due.filter { $0.sector == s.name }.count) }.filter { $0.1 > 0 }
        case .all: return library.usedSectors.map { s in
            (s.name, s.chats + s.notes + library.screenshots.filter { $0.sector == s.name }.count)
        } + library.usedScreenshotSectors.filter { s in !library.usedSectors.contains { $0.name == s.name } }.map { ($0.name, $0.count) }
        case .bin: return []
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "lock").font(.system(size: 9)).foregroundStyle(Ink.outline)
                Text("Local").mLabelStyle()
                Text("·").foregroundStyle(Ink.outline)
                StorageNote(signature: "\(library.chats.count)-\(library.notes.count)-\(library.screenshots.count)-\(library.binned.count)")
                Spacer(minLength: 0)
            }
            HStack {
                if let open = LibraryHooks.openSettings {
                    Button(action: open) { Label("Settings", systemImage: "gearshape").font(.geist(12, .medium)).foregroundStyle(Ink.onVariant) }
                        .buttonStyle(.plain).accessibilityLabel("Settings")
                } else {
                    Menu { settingsItems } label: {
                        Label("Settings", systemImage: "gearshape").font(.geist(12, .medium)).foregroundStyle(Ink.onVariant)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
                Spacer()
                Button { NSWorkspace.shared.activateFileViewerSelecting([library.directory]) } label: {
                    Label("Folder", systemImage: "folder").font(.geist(12, .medium)).foregroundStyle(Ink.onVariant)
                }
                .buttonStyle(.plain).help("Show the library in Finder").accessibilityLabel("Show the library in Finder")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    // MARK: Moving things between sectors

    /// Files chats and screenshots under a sector (notes have no sector move yet). Returns how many moved.
    @discardableResult
    private func moveItems(_ refs: [ItemRef], to sector: String) -> Int {
        var moved = 0
        for ref in refs {
            switch ref.kind {
            case .chat:
                if library.chat(ref.id)?.sector != sector { library.move(ref.id, toSector: sector); moved += 1 }
            case .screenshot:
                if library.screenshot(ref.id)?.sector != sector { library.move(screenshot: ref.id, toSector: sector); moved += 1 }
            case .note:
                break
            }
        }
        if moved > 0 { state.announce(moved == 1 ? "Moved to \(sector)" : "\(moved) moved to \(sector)", undo: []) }
        return moved
    }

    /// Something dropped on a sector in the sidebar.
    private func dropOn(_ sector: String) -> Bool {
        let refs = state.dragging
        state.dragging = []
        guard !refs.isEmpty else { return false }
        return withAnimation(LibMotion.small) { moveItems(refs, to: sector) } > 0
    }

    private func selectedRefs(in feed: [FeedItem]) -> [ItemRef] {
        if state.multi.count > 1 { return feed.map(\.ref).filter { state.multi.contains($0) } }
        return state.selection.map { [$0] } ?? []
    }

    // MARK: List

    /// What the middle column shows, in order.
    private func makeFeed() -> [FeedItem] {
        let q = state.query, sec = state.sector
        var out: [FeedItem] = []
        func wants(_ k: BinItem.Kind) -> Bool { state.kind == nil || state.kind == k }
        switch state.mode {
        case .chats: out = library.search(chats: q, sector: sec).map(FeedItem.init(chat:))
        case .notebook: out = library.search(notes: q, sector: sec).map(FeedItem.init(note:))
        case .screenshots: out = library.search(screenshots: q, sector: sec).map { FeedItem(shot: $0, library: library) }
        case .all:
            if wants(.chat) { out += library.search(chats: q, sector: sec).map(FeedItem.init(chat:)) }
            if wants(.note) { out += library.search(notes: q, sector: sec).map(FeedItem.init(note:)) }
            if wants(.screenshot) { out += library.search(screenshots: q, sector: sec).map { FeedItem(shot: $0, library: library) } }
        case .review:
            let due = Dictionary(Review.chats(library.chats).map { ($0.chat.id, $0.missed) }, uniquingKeysWith: { a, _ in a })
            out = library.search(chats: q, sector: sec).compactMap { c in
                guard let missed = due[c.id] else { return nil }
                var item = FeedItem(chat: c)
                item.date = missed
                return item
            }
        case .bin: out = library.search(bin: q, kind: state.kind).map { FeedItem(binned: $0, library: library) }
        }
        out.sort { state.newestFirst ? $0.date > $1.date : $0.date < $1.date }
        return Feed.starredFirst(out) // (the arrow keys and ⇧-click follow this order, so it must match what's drawn)
    }

    private var listTitle: String {
        switch state.mode {
        case .all: return state.sector ?? "All"
        case .chats: return state.sector ?? "Chats"
        case .notebook: return state.sector ?? "Notes"
        case .screenshots: return state.sector ?? "Screenshots"
        case .review: return "To review"
        case .bin: return "Bin"
        }
    }

    private func listPane(_ feed: [FeedItem]) -> some View {
        VStack(spacing: 0) {
            listHeader(feed)
            if state.mode == .bin { binBanner }
            if feed.isEmpty {
                emptyList
            } else {
                feedList(feed)
            }
        }
        .background(Ink.lowest)
        .background(Button("") { _ = clearSelected(in: feed) }.keyboardShortcut(.delete, modifiers: .command).opacity(0).frame(width: 0, height: 0))
        .overlay(alignment: .bottom) {
            if let toast = state.toast {
                UndoBar(toast: toast, onUndo: { state.undo(toast) }, onClose: { withAnimation(DashboardProbe.enabled ? nil : .default) { state.toast = nil } })
                    .padding(10)
                    .transition(DashboardProbe.enabled ? AnyTransition.identity : AnyTransition.move(edge: .bottom).combined(with: .opacity)) // (a test needs it where it ends up, at once)
            }
        }
    }

    private func listHeader(_ feed: [FeedItem]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if state.selecting && state.mode != .bin {
                    selectBar(feed)
                } else {
                    if state.mode == .bin {
                        KindPicker(kind: $state.kind)
                    } else {
                        if let s = state.sector { sectorMark(s, active: true) }
                        Text(listTitle).font(.mUI.weight(.semibold)).foregroundStyle(Ink.onSurface).lineLimit(1)
                        if let n = Theme.count(feed.count) {
                            Text(n).libCount()
                                .contentTransition(.numericText()).animation(LibMotion.small, value: feed.count)
                        }
                    }
                    Spacer(minLength: 4)
                    if state.mode != .bin && !feed.isEmpty {
                        // Always in view, and labelled: this is how you clear many at once.
                        Button { withAnimation(LibMotion.small) { state.selecting = true; state.multi = [] } } label: {
                            Text("Select").font(.geist(12, .semibold)).foregroundStyle(Ink.onVariant)
                                .padding(.horizontal, 8).frame(height: 24)
                        }
                        .buttonStyle(LibPressStyle())
                        .help("Pick several to delete at once").accessibilityLabel("Select several").probe("select-mode")
                    }
                    BarIconButton(symbol: "arrow.up.arrow.down", help: state.newestFirst ? "Newest first (click for oldest first)" : "Oldest first (click for newest first)") {
                        state.newestFirst.toggle()
                    }
                }
            }
            .padding(.horizontal, 12).frame(height: 46)
            HLine()
        }
        .padding(.top, 6)
        .background(Ink.lowest)
    }

    /// What replaces the list title while you pick rows: Cancel, how many, All, and the delete button.
    private func selectBar(_ feed: [FeedItem]) -> some View {
        let allTicked = !feed.filter(LibraryState.deletable).isEmpty && state.picked == Set(feed.filter(LibraryState.deletable).map(\.ref))
        let n = state.picked.count
        return HStack(spacing: 8) {
            Button("Cancel") { withAnimation(LibMotion.small) { state.selecting = false } }
                .buttonStyle(.plain).font(.geist(12, .semibold)).foregroundStyle(Ink.onVariant)
                .accessibilityLabel("Cancel selecting").probe("select-cancel")
            Text(n == 0 ? "Pick items" : "\(n) selected").font(.mUI.weight(.semibold)).foregroundStyle(Ink.onSurface).lineLimit(1)
                .contentTransition(.numericText()).animation(LibMotion.small, value: n)
            Spacer(minLength: 4)
            Button(allTicked ? "None" : "All") { state.toggleAll(in: feed) }
                .buttonStyle(.plain).font(.geist(12, .semibold)).foregroundStyle(Ink.onVariant)
                .help(allTicked ? "Untick everything" : "Tick everything in this list (starred chats are skipped)")
                .accessibilityLabel(allTicked ? "Select none" : "Select all").probe("select-all")
            Button { withAnimation(LibMotion.small) { state.deletePicked(in: feed) } } label: {
                Text(n == 0 ? "Delete" : "Delete \(n)").font(.geist(12, .semibold))
                    .foregroundStyle(n == 0 ? Ink.outline : Ink.error)
                    .padding(.horizontal, 8).frame(height: 24)
            }
            .buttonStyle(LibPressStyle()).disabled(n == 0)
            .help("Move the ticked items to the Bin (Undo is on the bar that appears)")
            .accessibilityLabel("Delete selected").probe("select-delete")
        }
    }

    private var binBanner: some View {
        HStack(spacing: 8) {
            Text(Library.binDays > 0 ? "Empties after \(Library.binDays) days" : "Empties when you empty it")
                .mLabelStyle().lineLimit(1)
            Spacer(minLength: 4)
            if !library.binned.isEmpty {
                Button("Empty") { confirmEmpty = true }
                    .buttonStyle(.plain).font(.geist(12, .semibold)).foregroundStyle(Ink.error)
                    .help("Delete everything in the Bin for good").accessibilityLabel("Empty the Bin")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Ink.side)
        .overlay(alignment: .bottom) { HLine() }
    }

    private var emptyList: some View {
        let text: String
        let glyph: GlyphKind
        let line: String
        let searching = !state.query.isEmpty
        switch state.mode {
        case .bin:
            text = searching ? "Nothing in the Bin matches." : "Anything you delete waits here \(Library.binDays > 0 ? "for \(Library.binDays) days" : "until you empty it")."
            glyph = searching ? .scan : .emptyVoid
            line = searching ? "No results" : "Bin empty"
        case .screenshots:
            glyph = .scan
            text = library.screenshots.isEmpty
                ? (Settings.shared.saveScreenshots
                   ? "Screenshots you take (⌘⇧3, ⌘⇧4, ⌘⇧5 or Tab+\\) show up here on their own, labeled by what's in them."
                   : "Saving screenshots is off. Turn it on from Settings, at the bottom left.")
                : "No screenshots match."
            line = library.screenshots.isEmpty ? "No screenshots" : "No results"
        case .notebook:
            glyph = library.notes.isEmpty ? .void : .scan
            text = library.notes.isEmpty ? "Tap Keep under an answer to save it here." : "No notes match."
            line = library.notes.isEmpty ? "No notes" : "No results"
        case .review:
            glyph = searching ? .scan : .check
            text = searching ? "No chats to review match." : "Nothing to review. Chats show up here when you miss a quiz question, and leave once you get them all right."
            line = searching ? "No results" : "All caught up"
        case .chats:
            glyph = library.chats.isEmpty ? .void : .scan
            text = library.chats.isEmpty ? "Your chats show up here as you ask questions." : "No chats match."
            line = library.chats.isEmpty ? "No chats" : "No results"
        case .all:
            let blank = library.chats.isEmpty && library.notes.isEmpty && library.screenshots.isEmpty
            glyph = blank ? .void : .scan
            text = blank ? "Chats, notes and screenshots show up here as you make them." : "Nothing matches."
            line = blank ? "Library empty" : "No results"
        }
        return EmptyNote(text: text, glyph: glyph, line: line)
    }

    private func feedList(_ feed: [FeedItem]) -> some View {
        let groups = Feed.groups(feed)
        let mixed = state.mode == .all || state.mode == .bin
        let sectors = library.allSectors
        let scope = "\(state.mode)-\(state.sector ?? "")-\(state.kind?.rawValue ?? "")"
        let indexOf = Dictionary(feed.enumerated().map { ($1.ref, $0) }, uniquingKeysWith: { a, _ in a })
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2, pinnedViews: [.sectionHeaders]) {
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.items) { item in
                                FeedCard(item: item,
                                         selected: state.selecting ? state.picked.contains(item.ref)
                                             : (state.multi.isEmpty ? state.selection == item.ref : state.multi.contains(item.ref)),
                                         lone: state.multi.isEmpty && !state.selecting,
                                         checkMode: state.selecting && state.mode != .bin,
                                         onStar: { library.setStarred(item.ref.id, !item.starred) },
                                         onReview: { library.setReview(item.ref.id, !item.inReview) },
                                         showKind: mixed, inBin: state.mode == .bin, hideMark: state.sector != nil,
                                         hovered: state.debugHover == item.ref, lifted: state.debugLift == item.ref || state.dragging.contains(item.ref),
                                         dragCount: state.dragging.count, index: indexOf[item.ref] ?? 99, ns: rowSelection, sectors: sectors,
                                         onSelect: { if state.selecting && state.mode != .bin { state.toggle(item) } else { pick(item.ref, in: feed) } },
                                         onClear: { state.clear(item.ref, next: neighbor(of: item.ref, in: feed)) },
                                         onRestore: { state.restore(item.ref, next: neighbor(of: item.ref, in: feed)) },
                                         onForever: { state.deleteForever(item.ref, next: neighbor(of: item.ref, in: feed)) },
                                         onMove: { moveItems(selectedRefs(in: feed).contains(item.ref) ? selectedRefs(in: feed) : [item.ref], to: $0) },
                                         onDragStart: {
                                             guard state.mode != .bin else { return }
                                             let carried = state.multi.contains(item.ref) ? feed.map(\.ref).filter { state.multi.contains($0) } : [item.ref]
                                             state.dragging = carried
                                         },
                                         onPointerBack: { if !state.dragging.isEmpty { state.dragging = [] } })
                                    .id(item.ref)
                                    .transition(LibMotion.reduce || LibMotion.still ? .opacity
                                                : .asymmetric(insertion: .identity, removal: .modifier(active: Fold(amount: 1), identity: Fold(amount: 0))))
                            }
                        } header: {
                            HStack(spacing: 6) {
                                Text(group.label).mLabelStyle()
                                Spacer(minLength: 0)
                                if let n = Theme.count(group.items.count) { Text(n).libCount().contentTransition(.numericText()) }
                            }
                            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 5)
                            .frame(maxWidth: .infinity)
                            .background(Ink.lowest)
                        }
                    }
                }
                .id(scope)
                .animation(LibMotion.small, value: feed.map(\.ref))
                .animation(LibMotion.small, value: state.selection)
            }
            .focusable()
            .focused($listFocused)
            .focusEffectDisabled()
            .onKeyPress(.downArrow) { move(1, in: feed, proxy); return .handled }
            .onKeyPress(.upArrow) { move(-1, in: feed, proxy); return .handled }
            .onKeyPress(.return) {
                if state.selection == nil, let first = feed.first { state.selection = first.ref }
                return .handled
            }
            .onKeyPress(.escape) {
                if state.selecting { withAnimation(LibMotion.small) { state.selecting = false }; return .handled }
                if state.multi.count > 1 { state.multi = [] } else { withAnimation(LibMotion.panel) { state.goDesk() } }
                return .handled
            }
            .onKeyPress(characters: CharacterSet(charactersIn: "123456789"), phases: .down) { press in
                guard state.mode != .bin, let n = Int(press.characters), n >= 1, n <= sectorRows.count else { return .ignored }
                let name = sectorRows[n - 1].name
                open(state.mode, sector: name)
                return .handled
            }
            // Backspace, fn-Delete, and the Edit menu's Delete: all move the selected row to the Bin (never in the Bin itself).
            .onKeyPress(keys: [.delete, .deleteForward, KeyEquivalent("\u{7F}"), KeyEquivalent("\u{8}")]) { _ in
                clearSelected(in: feed) ? .handled : .ignored
            }
            .onDeleteCommand { _ = clearSelected(in: feed) }
        }
    }
    /// A click: on its own it picks the row; with ⌘ it adds or drops the row; with ⇧ it takes everything from the last pick.
    private func pick(_ ref: ItemRef, in feed: [FeedItem]) {
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        listFocused = true
        if flags.contains(.command) && state.mode != .bin {
            var set = state.multi.isEmpty ? Set(state.selection.map { [$0] } ?? []) : state.multi
            if set.contains(ref) { set.remove(ref) } else { set.insert(ref) }
            state.anchor = ref
            state.selection = set.contains(ref) ? ref : set.first
            state.multi = set.count > 1 ? set : []
        } else if flags.contains(.shift), state.mode != .bin, let anchor = state.anchor ?? state.selection,
                  let a = feed.firstIndex(where: { $0.ref == anchor }), let b = feed.firstIndex(where: { $0.ref == ref }) {
            let set = Set(feed[min(a, b)...max(a, b)].map(\.ref))
            state.selection = ref
            state.multi = set.count > 1 ? set : []
        } else {
            state.multi = []
            state.selection = ref
            state.anchor = ref
        }
    }

    /// Moves the selected row (or rows) to the Bin. False if there's nothing to move (nothing selected, or we're looking at the Bin).
    private func clearSelected(in feed: [FeedItem]) -> Bool {
        guard state.mode != .bin else { return false }
        if state.multi.count > 1 {
            let refs = selectedRefs(in: feed)
            let next = feed.map(\.ref).last(where: { r in !refs.contains(r) && (feed.firstIndex { $0.ref == r } ?? 0) > (feed.firstIndex { $0.ref == refs.last } ?? 0) })
                ?? feed.map(\.ref).last(where: { !refs.contains($0) })
            state.clearMany(refs, next: next)
            return true
        }
        guard let ref = state.selection, feed.contains(where: { $0.ref == ref }) else { return false }
        state.clear(ref, next: neighbor(of: ref, in: feed))
        return true
    }

    /// The row to show once this one is gone: the next one down, or the one above if it was last.
    private func neighbor(of ref: ItemRef, in feed: [FeedItem]) -> ItemRef? {
        guard let i = feed.firstIndex(where: { $0.ref == ref }) else { return nil }
        if i + 1 < feed.count { return feed[i + 1].ref }
        return i > 0 ? feed[i - 1].ref : nil
    }

    private func move(_ step: Int, in feed: [FeedItem], _ proxy: ScrollViewProxy) {
        guard !feed.isEmpty else { return }
        let current = state.selection.flatMap { ref in feed.firstIndex { $0.ref == ref } }
        let target = min(max((current ?? (step > 0 ? -1 : feed.count)) + step, 0), feed.count - 1)
        state.multi = []
        state.selection = feed[target].ref
        state.anchor = feed[target].ref
        withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(feed[target].ref) }
    }

    // MARK: Detail

    private func detailPane(_ feed: [FeedItem]) -> some View {
        let key = state.multi.count > 1 ? "multi" : (state.selection.map { "\($0.id)" } ?? "none")
        return ZStack {
            detailContent(feed)
                .id(key)
                .transition(.detailOpen)
        }
        .animation(LibMotion.still ? nil : Motion.animation(Motion.snappy), value: key)
        .clipped()
        .background(Ink.surface)
    }

    @ViewBuilder
    private func detailContent(_ feed: [FeedItem]) -> some View {
        let next: ItemRef? = state.selection.flatMap { neighbor(of: $0, in: feed) }
        if state.multi.count > 1 {
            let refs = selectedRefs(in: feed)
            MultiDetail(count: refs.count, movable: refs.filter { $0.kind == .chat || $0.kind == .screenshot }.count,
                        sectors: library.allSectors, moveRequest: state.moveRequest,
                        onMove: { moveItems(refs, to: $0) },
                        onClear: { _ = clearSelected(in: feed) },
                        onCancel: { state.multi = [] })
        } else if let ref = state.selection, state.mode == .bin, let item = library.binItem(ref.id) {
            BinDetail(item: item, daysLeft: library.daysLeft(item),
                      onRestore: { state.restore(ref, next: next) }, onForever: { state.deleteForever(ref, next: next) })
        } else if let ref = state.selection, state.mode != .bin, LibraryState.shows(ref.kind, in: state.mode) {
            liveDetail(ref, next: next)
        } else if state.mode == .bin {
            EmptyNote(text: "Pick something to preview it.", glyph: .emptyVoid, line: "Nothing selected")
        } else {
            EmptyDetail(onNewChat: onNewChat)
        }
    }

    @ViewBuilder
    private func liveDetail(_ ref: ItemRef, next: ItemRef?) -> some View {
        let move: (String) -> Void = { moveItems([ref], to: $0) }
        if ref.kind == .chat, let chat = library.chat(ref.id) {
            ChatDetail(chat: chat, moveRequest: state.moveRequest, onMove: move, onAsk: onAsk, onClear: { state.clear(ref, next: next) })
        } else if ref.kind == .note, let note = library.notes.first(where: { $0.id == ref.id }) {
            NoteDetail(note: note, moveRequest: state.moveRequest, onAsk: onAsk, onClear: { state.clear(ref, next: next) })
        } else if ref.kind == .screenshot, let shot = library.screenshot(ref.id) {
            ScreenshotDetail(shot: shot, moveRequest: state.moveRequest, onMove: move, onAskImage: onAskImage, onClear: { state.clear(ref, next: next) })
        } else {
            EmptyNote(text: "Pick something on the left.", glyph: .scan, line: "Nothing selected")
        }
    }
}

// MARK: - The Desk

/// One sector's tile on the Desk.
struct DeskSector: Identifiable {
    var name: String
    var count: Int
    var last: Date
    /// Things per week, oldest first, for the last 8 weeks.
    var weekly: [Int]
    var id: String { name }
}

/// What you see with nothing picked: where you left off, your sectors, and what's waiting for review.
struct DeskView: View {
    let library: Library
    let onOpen: (ItemRef) -> Void
    let onSector: (String) -> Void
    let onNewChat: () -> Void

    static func sectors(_ library: Library, now: Date = Date()) -> [DeskSector] {
        var dates: [String: [Date]] = [:]
        for c in library.chats { dates[c.sector, default: []].append(c.updated) }
        for n in library.notes { dates[n.sector, default: []].append(n.created) }
        for s in library.screenshots { dates[s.sector, default: []].append(s.created) }
        let order = library.allSectors
        return order.compactMap { name in
            guard let ds = dates[name], let last = ds.max() else { return nil }
            var weekly = Array(repeating: 0, count: 8)
            for d in ds {
                let weeksAgo = Int(max(0, now.timeIntervalSince(d)) / (7 * 86_400))
                if weeksAgo < 8 { weekly[7 - weeksAgo] += 1 }
            }
            return DeskSector(name: name, count: ds.count, last: last, weekly: weekly)
        }
    }

    var body: some View {
        let recent = Array(library.chats.sorted { $0.updated > $1.updated }.prefix(3))
        let review = library.notes.filter { $0.kind == .missed }.sorted { $0.created > $1.created }
        let total = library.chats.count + library.notes.count + library.screenshots.count
        ScrollView {
            if total == 0 {
                EmptyDetail(onNewChat: onNewChat).frame(minHeight: 420)
            } else {
                VStack(alignment: .leading, spacing: 32) {
                    VStack(alignment: .leading, spacing: 8) {
                        DecodeText("Desk").mDisplayStyle().foregroundStyle(Ink.onSurface).frame(minHeight: 34, alignment: .leading)
                    }
                    .bootIn(0)
                    if !recent.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            SectionLabel("Recent", count: recent.count)
                            VStack(spacing: 2) {
                                ForEach(recent) { chat in
                                    DeskRow(chat: chat) { onOpen(ItemRef(kind: .chat, id: chat.id)) }
                                }
                            }
                        }
                        .bootIn(1)
                    }
                    if !review.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionLabel("To review", count: review.count)
                            VStack(spacing: 2) {
                                ForEach(review.prefix(4)) { note in
                                    ReviewRow(note: note) { onOpen(ItemRef(kind: .note, id: note.id)) }
                                }
                            }
                        }
                        .bootIn(2)
                    }
                }
                .frame(maxWidth: 820, alignment: .leading)
                .padding(.horizontal, 36).padding(.top, 44).padding(.bottom, 32)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Ink.surface)
    }
}

/// A recent chat as a 44px row: glyph, title, sector, time (the To review rows match).
struct DeskRow: View {
    let chat: ChatRecord
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        let bad = Feed.isBadTitle(chat.title) && !chat.quote.isEmpty
        Button(action: action) {
            HStack(spacing: 10) {
                sectorMark(chat.sector, active: hover)
                Text(bad ? chat.quote : chat.title).font(.mUI.weight(.medium)).foregroundStyle(Ink.onSurface).lineLimit(1)
                Spacer(minLength: 8)
                Text(chat.sector).font(.geist(12, .medium)).foregroundStyle(Ink.outline).lineLimit(1)
                Text(Feed.ago(chat.updated)).mMetaStyle().foregroundStyle(Ink.outline)
                    .frame(minWidth: 44, alignment: .trailing)
            }
            .padding(.horizontal, 10).frame(height: 44)
            .rowHoverFill(hover)
        }
        .buttonStyle(LibPressStyle())
        .onHover { hover = $0 }
        .animation(LibMotion.hover, value: hover)
        .accessibilityLabel("Open \(chat.title)")
    }
}

/// A line that draws itself on, with a dot at today's end that pulses once.
struct Sparkline: View {
    let values: [Int]
    @State private var drawn: CGFloat
    @State private var pulse = false

    init(values: [Int]) {
        self.values = values
        _drawn = State(initialValue: LibMotion.still ? 1 : 0)
    }

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let peak = CGFloat(max(1, values.max() ?? 1))
            let pts: [CGPoint] = values.enumerated().map { i, v in
                CGPoint(x: w * CGFloat(i) / CGFloat(max(1, values.count - 1)), y: 2 + (h - 4) * (1 - CGFloat(v) / peak))
            }
            ZStack {
                Path { p in p.move(to: CGPoint(x: 0, y: h - 0.5)); p.addLine(to: CGPoint(x: w, y: h - 0.5)) }
                    .stroke(Ink.edge, lineWidth: 1)
                Path { p in
                    guard let f = pts.first else { return }
                    p.move(to: f)
                    for q in pts.dropFirst() { p.addLine(to: q) }
                }
                .trim(from: 0, to: drawn)
                .stroke(Ink.onSurface, style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
                if let last = pts.last {
                    Circle().fill(Ink.onSurface.opacity(0.3)).frame(width: 4, height: 4)
                        .scaleEffect(pulse ? 3.4 : 1).opacity(pulse ? 0 : 0.8).position(last)
                    Circle().fill(Ink.onSurface).frame(width: 4, height: 4).position(last).opacity(drawn >= 1 ? 1 : 0)
                }
            }
        }
        .onAppear {
            guard !LibMotion.still else { return }
            withAnimation(Motion.animation(.easeOut(duration: 0.6))) { drawn = 1 }
            guard !LibMotion.reduce else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { withAnimation(.easeOut(duration: 0.6)) { pulse = true } }
        }
        .accessibilityHidden(true)
    }
}

/// A note you missed in a quiz, waiting to be looked at again.
struct ReviewRow: View {
    let note: Note
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                sectorMark(note.sector, active: hover)
                Text(note.question).font(.mUI).foregroundStyle(Ink.onSurface).lineLimit(1)
                Spacer(minLength: 8)
                Text("↵").font(.geist(12, .medium)).foregroundStyle(Ink.outline).opacity(hover ? 1 : 0)
                Text(Feed.ago(note.created)).mMetaStyle().foregroundStyle(Ink.outline)
            }
            .padding(.horizontal, 10).frame(height: 44)
            .rowHoverFill(hover)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(LibMotion.hover, value: hover)
    }
}

/// Press feedback: 0.97, like the rest of Margin's buttons.
struct LibPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !LibMotion.reduce ? Motion.pressScale : 1)
            .animation(LibMotion.still ? nil : Motion.animation(Motion.small), value: configuration.isPressed)
    }
}

// MARK: - Sidebar rows

/// The fill behind the picked row, with a 2px accent bar at its left edge. It's one view that slides from row to row
/// (matchedGeometryEffect).
private struct SlidingFill: View {
    let ns: Namespace.ID
    var radius: CGFloat = Theme.Radius.control
    /// The selection bar is ink everywhere (lime is for the one primary).
    var bar: Color = Ink.onSurface

    var body: some View {
        ZStack(alignment: .leading) {
            Ink.high
            bar.frame(width: 2)
        }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .matchedGeometryEffect(id: "selection", in: ns)
    }
}

struct NavRow: View {
    let symbol: String
    let activeSymbol: String
    let title: String
    let count: Int
    /// A drawn glyph in place of the symbols.
    var glyph: GlyphKind?
    let active: Bool
    let ns: Namespace.ID
    /// Shown at the right while the pointer is over the row (the Bin's "Empties after 30 days").
    var hoverNote: String?
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Group {
                    if let glyph {
                        Glyph(kind: glyph, size: 14, color: active || hover ? Ink.onSurface : Ink.onVariant)
                    } else {
                        Image(systemName: active ? activeSymbol : symbol).font(.system(size: 12))
                    }
                }
                .frame(width: 18, height: 18)
                .foregroundStyle(active || hover ? Ink.onSurface : Ink.onVariant)
                Text(title).font(.mUI.weight(active ? .medium : .regular))
                    .foregroundStyle(active || hover ? Ink.onSurface : Ink.onVariant)
                Spacer(minLength: 0)
                if let hoverNote, hover {
                    Text(hoverNote).font(.geist(12, .medium)).foregroundStyle(active ? Ink.onVariant : Ink.outline).transition(.opacity)
                } else if count > 0 {
                    Text(String(count)).libCount(active ? Ink.onVariant : Ink.outline)
                        .contentTransition(.numericText())
                }
            }
            .padding(.horizontal, 10).frame(height: 30)
            .background {
                if active { SlidingFill(ns: ns) }
                else if hover { RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(Ink.container) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(LibMotion.hover, value: hover)
        .animation(LibMotion.small, value: count)
        .accessibilityLabel(title)
    }
}

struct SectorRow: View {
    let name: String
    let count: Int
    let active: Bool
    let ns: Namespace.ID
    /// Only --uishots: draw the "something is being dropped here" state.
    var forcedTarget = false
    let onTap: () -> Void
    /// A drop landed here. True if something moved.
    let onDrop: () -> Bool
    @State private var hover = false
    @State private var targeted = false
    @State private var pulse = false

    var body: some View {
        let glow = targeted || forcedTarget
        Button(action: onTap) {
            HStack(spacing: 10) {
                sectorMark(name, active: active || hover || glow || pulse)
                    .scaleEffect(pulse && !LibMotion.reduce ? 0.55 : 1) // the "absorb" beat
                    .frame(width: 18)
                Text(name).font(.mUI.weight(active ? .medium : .regular))
                    .foregroundStyle(active || hover || glow ? Ink.onSurface : Ink.onVariant).lineLimit(1)
                Spacer(minLength: 0)
                if let n = Theme.count(count) {
                    Text(n).libCount(active ? Ink.onVariant : Ink.outline)
                        .contentTransition(.numericText())
                }
            }
            .padding(.horizontal, 10).frame(height: 28)
            .background {
                if glow {
                    // The drop target: the accent wash inside a hairlineStrong frame.
                    RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(Ink.wash).padding(1)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(Ink.strong))
                } else if active { SlidingFill(ns: ns) }
                else if hover { RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(Ink.container) }
            }
            .scaleEffect(glow && !LibMotion.reduce ? 1.02 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .onDrop(of: [.plainText, .text], isTargeted: $targeted) { _ in
            let moved = onDrop()
            if moved {
                withAnimation(.spring(response: 0.18, dampingFraction: 0.6)) { pulse = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { pulse = false } }
            }
            return moved
        }
        .animation(LibMotion.hover, value: hover)
        .animation(LibMotion.small, value: glow)
        .animation(LibMotion.small, value: count)
        .accessibilityLabel("Sector \(name)")
    }
}

/// The last row of the sectors: "New sector".
struct NewSectorRow: View {
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "plus").font(.system(size: 10, weight: .semibold)).frame(width: 18)
                Text("New sector").font(.mUI)
                Spacer(minLength: 0)
            }
            .foregroundStyle(hover ? Ink.onSurface : Ink.outline)
            .padding(.horizontal, 10).frame(height: 28)
            .rowHoverFill(hover)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(LibMotion.hover, value: hover)
        .opacity(LibraryHooks.openSectorEditor == nil ? 0.6 : 1)
        .accessibilityLabel("New sector")
    }
}

// MARK: - Rows

/// One row in a list: the title with the time at the right, then a line of the answer. The sector's glyph leads it (unless the list is
/// already one sector). The trash button shows on hover or when the row is picked; in the Bin, Restore is always there and
/// Delete forever is in the alert colour.
struct FeedCard: View {
    let item: FeedItem
    let selected: Bool
    /// Exactly one row is picked (the sliding indicator belongs to it); false while several are.
    let lone: Bool
    /// Select mode: a checkbox leads the row and a click ticks it.
    var checkMode = false
    /// Stars or unstars the chat.
    var onStar: () -> Void = {}
    var onReview: () -> Void = {}
    let showKind: Bool
    let inBin: Bool
    let hideMark: Bool
    var hovered = false
    var lifted = false
    var dragCount = 1
    let index: Int
    let ns: Namespace.ID
    let sectors: [String]
    let onSelect: () -> Void
    let onClear: () -> Void
    let onRestore: () -> Void
    let onForever: () -> Void
    let onMove: (String) -> Void
    let onDragStart: () -> Void
    let onPointerBack: () -> Void
    @State private var hover = false
    @AppStorage("libraryRowDensity") private var density = LibraryRowDensity.comfortable.rawValue
    @AppStorage("libraryShowPreviews") private var showPreviews = false

    var body: some View {
        let pointerOver = hover || hovered
        ZStack(alignment: .bottomTrailing) {
            Button(action: onSelect) { content }.buttonStyle(.plain).probe("card:\(item.ref.id)")
            HStack(spacing: 4) {
                if inBin {
                    Button(action: onRestore) {
                        Text("Restore").secondaryButtonLook(height: 24)
                    }
                    .buttonStyle(LibPressStyle()).help("Put it back where it was").accessibilityLabel("Restore").probe("restore:\(item.ref.id)")
                    FeedCardButton(symbol: "xmark.bin", help: "Delete forever", danger: true, alwaysDanger: true, probe: "forever:\(item.ref.id)", action: onForever)
                } else if !checkMode {
                    if item.ref.kind == .chat {
                        FeedCardButton(symbol: item.inReview ? "bookmark.fill" : "bookmark", help: item.inReview ? "Take out of To review" : "Add to To review",
                                       probe: "review:\(item.ref.id)", action: onReview)
                            .opacity(pointerOver || item.inReview ? 1 : 0).allowsHitTesting(pointerOver || item.inReview)
                        FeedCardButton(symbol: item.starred ? "star.fill" : "star", help: item.starred ? "Unstar" : "Star (keeps it at the top and safe from delete)",
                                       probe: "star:\(item.ref.id)", action: onStar)
                            .opacity(pointerOver || item.starred ? 1 : 0).allowsHitTesting(pointerOver || item.starred)
                    }
                    if !item.starred {
                        FeedCardButton(symbol: "trash", help: "Move to Bin", danger: true, probe: "clear:\(item.ref.id)", action: onClear)
                            .opacity(pointerOver ? 1 : 0).allowsHitTesting(pointerOver)
                    }
                }
            }
            .padding(.trailing, 12).padding(.bottom, inBin ? 6 : 5)
        }
        .background {
            if selected && lone { SlidingFill(ns: ns) }
            else if selected { RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(Ink.high) }
            else if lifted { RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(Ink.high) }
            else if hover || hovered { RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(Ink.container) }
        }
        .padding(.horizontal, 6)
        .scaleEffect(lifted && !LibMotion.reduce ? 1.02 : 1)
        .shadow(color: .black.opacity(lifted ? 0.28 : 0), radius: lifted ? 12 : 0, y: lifted ? 5 : 0)
        .zIndex(lifted ? 1 : 0)
        .modifier(BootIn(index: index, rise: 8))
        .onHover { inside in
            hover = inside
            if inside { onPointerBack() }
        }
        .animation(LibMotion.hover, value: hover)
        .animation(LibMotion.small, value: lifted)
        .onDrag {
            onDragStart()
            return NSItemProvider(object: item.title as NSString)
        } preview: {
            DragChip(item: item, count: dragCount)
        }
        .contextMenu {
            if inBin {
                Button("Restore", action: onRestore)
                Button("Delete forever", role: .destructive, action: onForever)
            } else {
                Button("Open", action: onSelect)
                Button("Copy question") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.title, forType: .string)
                }
                if item.ref.kind == .chat || item.ref.kind == .screenshot {
                    Menu("Move to…") {
                        ForEach(sectors, id: \.self) { s in
                            Button { onMove(s) } label: {
                                if s == item.sector { Label(s, systemImage: "checkmark") } else { Text(s) }
                            }
                        }
                    }
                }
                Divider()
                if item.ref.kind == .chat {
                    Button(item.starred ? "Unstar" : "Star", action: onStar)
                    Button(item.inReview ? "Take out of To review" : "Add to To review", action: onReview)
                }
                if item.starred {
                    Button("Move to Bin") {}.disabled(true) // protected until you unstar it
                } else {
                    Button("Move to Bin", role: .destructive, action: onClear)
                }
            }
        }
    }

    private var content: some View {
        let head = item.headline
        let compact = density == LibraryRowDensity.compact.rawValue
        let lead: CGFloat = hideMark ? 0 : 24
        return HStack(alignment: .top, spacing: 10) {
            if checkMode {
                // A starred chat can't be ticked: it shows its star where the box would be.
                Group {
                    if item.starred {
                        Image(systemName: "star.fill").foregroundStyle(Ink.outline)
                    } else {
                        MarginDoneBadge(on: selected, size: 16)
                    }
                }
                .font(.system(size: 14)).frame(width: 18).padding(.top, 1)
                .help(item.starred ? "Starred, so it can't be deleted" : "")
            }
            if let thumb = item.thumb { ScreenshotThumb(url: thumb, height: 40).padding(.top, 1) }
            VStack(alignment: .leading, spacing: compact ? 1 : 3) {
                HStack(spacing: 6) {
                    if !hideMark {
                        sectorMark(item.sector.isEmpty ? "Other" : item.sector, active: hover || selected || hovered)
                    }
                    if showKind {
                        Image(systemName: item.symbol).font(.system(size: 9, weight: .semibold)).foregroundStyle(Ink.outline).help(item.kindName)
                    }
                    Text(head.text)
                        .font(head.quoted ? .geistItalic(13) : .mUI.weight(.semibold))
                        .foregroundStyle(Ink.onSurface).lineLimit(1)
                    Spacer(minLength: 6)
                    if item.starred && !checkMode && item.ref.kind != .chat { // a chat's star is the clickable one at the card's corner
                        Image(systemName: "star.fill").font(.system(size: 10)).foregroundStyle(selected ? Ink.onVariant : Ink.outline).help("Starred")
                    }
                    if item.quizzed {
                        Image(systemName: "questionmark.circle").font(.system(size: 10)).foregroundStyle(selected ? Ink.onVariant : Ink.outline).help("Quizzed")
                    }
                    Text("↵").font(.geist(12, .medium)).foregroundStyle(Ink.onVariant).frame(width: 10)
                        .opacity((hover || hovered) && !selected && !inBin ? 1 : 0)
                    // The trash takes the time's place while the pointer is over the row (they used to overlap on the picked row).
                    Text(Feed.ago(item.date)).mMetaStyle().foregroundStyle(selected ? Ink.onVariant : Ink.outline)
                        .opacity((hover || hovered) && !inBin ? 0 : 1)
                }
                if showPreviews && !item.snippet.isEmpty {
                    Text(item.snippet).font(.mUI).foregroundStyle(Ink.onVariant).lineLimit(1)
                        .padding(.trailing, inBin ? 0 : 30)
                        .padding(.leading, lead)
                }
                if let left = item.daysLeft {
                    Text("\(left) day\(left == 1 ? "" : "s") left").font(.geist(12, .semibold)).foregroundStyle(left <= 3 ? Ink.error : (selected ? Ink.onVariant : Ink.outline))
                        .frame(height: 24, alignment: .leading)
                        .padding(.leading, lead)
                }
            }
        }
        .padding(.leading, 12).padding(.trailing, 12).padding(.vertical, compact ? 6 : 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// What the pointer carries while you drag a row: a small raised label, with a count for several.
struct DragChip: View {
    let item: FeedItem
    let count: Int

    var body: some View {
        HStack(spacing: 7) {
            sectorMark(item.sector.isEmpty ? "Other" : item.sector, active: true)
            Text(item.headline.text).font(.mUI.weight(.medium)).foregroundStyle(Ink.onSurface).lineLimit(1)
            if count > 1 {
                Text(String(count)).font(.geist(12, .semibold)).foregroundStyle(Ink.onSurface)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(Ink.strong))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: 260)
        .boxed(Ink.high, radius: Theme.Radius.chip, border: Ink.strong)
    }
}

/// The button on the right of a row.
struct FeedCardButton: View {
    let symbol: String
    let help: String
    var danger = false
    /// Drawn in the alert colour even at rest (the Bin's Delete forever).
    var alwaysDanger = false
    var tint: Color?
    var probe: String?
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                .foregroundStyle(alwaysDanger ? Ink.error : (hover ? (danger ? Ink.error : (tint ?? Ink.onSurface)) : Ink.onVariant))
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(hover ? (danger ? Ink.error.opacity(0.14) : Ink.strong) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .help(help)
        .accessibilityLabel(help)
        .probe(probe)
    }
}

// MARK: - Detail pieces

/// The strip across the top of a page: the sector (click to move it), where it came from and when, then the actions on the right.
struct DetailHeader<Before: View, After: View>: View {
    let sector: String
    var app = ""
    let when: Date
    /// ⌘⇧M bumps this to open Move to….
    var moveRequest = 0
    /// nil when this can't be filed somewhere else (a note, a thing in the Bin).
    var onMove: ((String) -> Void)?
    @ViewBuilder var before: Before
    @ViewBuilder var after: After
    @State private var moveOpen = false
    @State private var hover = false

    /// "Today 20:21", "Yesterday 09:05", "Mon 20:21", "12 Oct 20:21": one sans string.
    static func whenText(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = date.formatted(.dateTime.hour().minute())
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 99
        if days <= 0 { return "Today \(time)" }
        if days == 1 { return "Yesterday \(time)" }
        if days < 7 { return "\(date.formatted(.dateTime.weekday(.abbreviated))) \(time)" }
        return "\(date.formatted(.dateTime.day().month(.abbreviated))) \(time)"
    }

    var body: some View {
        HStack(spacing: 10) {
            Button { if onMove != nil { moveOpen = true } } label: {
                HStack(spacing: 6) {
                    sectorMark(sector, active: moveOpen)
                    Text(sector).font(.mUI.weight(.medium)).foregroundStyle(Ink.onSurface).lineLimit(1)
                    if onMove != nil { Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(Ink.outline) }
                }
                .padding(.horizontal, 8).frame(height: 24)
                .boxed(Ink.low, radius: Theme.Radius.chip)
                .fixedSize()
            }
            .buttonStyle(LibPressStyle())
            .layoutPriority(2)
            .help(onMove != nil ? "Move to another sector" : sector)
            .accessibilityLabel("Sector \(sector)")
            if !app.isEmpty {
                Text(app).font(.mUI).foregroundStyle(Ink.onVariant).lineLimit(1)
                Text("·").foregroundStyle(Ink.outline)
            }
            Text(Self.whenText(when))
                .font(.geist(12, .medium)).foregroundStyle(Ink.outline).lineLimit(1)
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                before
                if let onMove {
                    BarIconButton(symbol: "folder", help: "Move to… (⌘⇧M)") { moveOpen = true }
                        .popover(isPresented: $moveOpen, arrowEdge: .bottom) {
                            MovePicker(current: sector) { moveOpen = false; onMove($0) }
                        }
                }
                after
            }
            .opacity(hover || LibMotion.still ? 1 : 0.55)
            .animation(LibMotion.hover, value: hover)
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
        .padding(.top, 6)
        .background(Ink.lowest)
        .overlay(alignment: .bottom) { HLine() }
        .onHover { hover = $0 }
        .onChange(of: moveRequest) { _, _ in if onMove != nil { moveOpen = true } }
    }
}

/// The list of sectors you can file something under, with a box to start a new one.
struct MovePicker: View {
    let current: String?
    let onPick: (String) -> Void
    @State private var fresh = ""
    @FocusState private var typing: Bool

    var body: some View {
        let sectors = Library.shared.allSectors
        VStack(alignment: .leading, spacing: 2) {
            SectionLabel("Move to", count: sectors.count).padding(.horizontal, 10).padding(.bottom, 4)
            ForEach(Array(sectors.enumerated()), id: \.element) { i, s in
                MovePickerRow(name: s, current: s == current, number: i < 9 ? i + 1 : nil) { onPick(s) }
            }
            HLine().padding(.vertical, 4)
            HStack(spacing: 8) {
                Image(systemName: "plus").font(.system(size: 10, weight: .semibold)).foregroundStyle(Ink.outline).frame(width: 18)
                TextField("New sector", text: $fresh)
                    .textFieldStyle(.plain).font(.mUI).focused($typing)
                    .onSubmit {
                        let t = fresh.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !t.isEmpty { onPick(t) }
                    }
            }
            .padding(.horizontal, 10).frame(height: 28)
            .libField(focused: typing)
        }
        .padding(8)
        .frame(width: 220)
        .background(Ink.side)
    }
}

private struct MovePickerRow: View {
    let name: String
    let current: Bool
    let number: Int?
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                sectorMark(name, active: hover)
                Text(name).font(.mUI).foregroundStyle(Ink.onSurface).lineLimit(1)
                Spacer(minLength: 0)
                if current { MarginDoneBadge(on: true, size: 14) }
            }
            .padding(.horizontal, 10).frame(height: 28)
            .rowHoverFill(hover)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Several rows picked: what you can do with them all at once.
struct MultiDetail: View {
    let count: Int
    let movable: Int
    let sectors: [String]
    let moveRequest: Int
    let onMove: (String) -> Void
    let onClear: () -> Void
    let onCancel: () -> Void
    @State private var moveOpen = false

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Text(String(count)).font(.geist(34, .semibold)).monospacedDigit().foregroundStyle(Ink.onSurface)
                    .contentTransition(.numericText()).animation(LibMotion.small, value: count)
                Text("Selected").mLabelStyle()
                Text("Drag them onto a sector in the sidebar, or use the buttons.")
                    .font(.mUI).foregroundStyle(Ink.onVariant).multilineTextAlignment(.center).padding(.top, 4)
            }
            HStack(spacing: 8) {
                Button { moveOpen = true } label: {
                    Label("Move to…", systemImage: "folder").primaryButtonLook(height: 28)
                }
                .buttonStyle(LibPressStyle()).disabled(movable == 0)
                .popover(isPresented: $moveOpen, arrowEdge: .bottom) { MovePicker(current: nil) { moveOpen = false; onMove($0) } }
                Button(action: onClear) {
                    Label("Move to Bin", systemImage: "trash").secondaryButtonLook(height: 28, tint: Ink.error)
                }
                .buttonStyle(LibPressStyle())
                Button(action: onCancel) {
                    Text("Clear selection").font(.mUI).foregroundStyle(Ink.onVariant).padding(.horizontal, 10).frame(height: 28)
                }
                .buttonStyle(.plain)
            }
            if movable < count {
                Text("\(count - movable) can't be filed under a sector (notes stay where they are).")
                    .font(.mUI).foregroundStyle(Ink.outline)
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: moveRequest) { _, _ in if movable > 0 { moveOpen = true } }
    }
}

/// An empty list or page: a status glyph and one mono line ("Bin empty"), then a sentence of help.
struct EmptyNote: View {
    let text: String
    var glyph: GlyphKind = .scan
    var line: String?

    var body: some View {
        VStack(spacing: 12) {
            Glyph(kind: glyph, size: 40, color: Ink.onVariant, animated: true).bootIn(0)
            if let line { Text(line).mLabelStyle().bootIn(1) }
            Text(text).font(.mUI).foregroundStyle(Ink.outline).multilineTextAlignment(.center).bootIn(2)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Nothing picked: one line of help, one action.
struct EmptyDetail: View {
    let onNewChat: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Glyph(kind: .spark, size: 40, color: Ink.onSurface, animated: true).bootIn(0)
            Text("Nothing yet").mLabelStyle().bootIn(1)
            Text("Highlight text anywhere to ask, or press ⌥⇧⇥ for a new chat.")
                .font(.mUI).foregroundStyle(Ink.onVariant).multilineTextAlignment(.center).bootIn(2)
            Button(action: onNewChat) {
                Text("Start a new chat").primaryButtonLook(height: 28)
            }
            .buttonStyle(LibPressStyle()).accessibilityLabel("Start a new chat").bootIn(3)
        }
        .padding(30)
        .frame(maxWidth: 440).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// How much room the library takes on this Mac.
struct StorageNote: View {
    /// Changes when something is added or removed, which is when the size changes.
    let signature: String
    @State private var bytes: Int64 = 0

    var body: some View {
        Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)).mLabelStyle()
            .contentTransition(.numericText())
            .task(id: signature) {
                let dir = Library.shared.directory
                bytes = await Task.detached(priority: .utility) { StorageNote.size(of: dir) }.value
            }
    }

    nonisolated static func size(of directory: URL) -> Int64 {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            total += Int64(v.fileSize ?? 0)
        }
        return total
    }
}


/// A small square icon button with a tooltip.
struct BarIconButton: View {
    let symbol: String
    let help: String
    var danger = false
    var tint: Color?
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12))
                .foregroundStyle(hover ? (danger ? Ink.error : (tint ?? Ink.onSurface)) : Ink.outline)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(hover ? (danger ? Ink.error.opacity(0.14) : Ink.container) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// All · Chats · Notes · Shots.
struct KindPicker: View {
    @Binding var kind: BinItem.Kind?

    private var options: [(label: String, value: BinItem.Kind?)] {
        [("All", nil), ("Chats", .chat), ("Notes", .note), ("Shots", .screenshot)]
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.label) { option in
                let on = kind == option.value
                Button { withAnimation(LibMotion.small) { kind = option.value } } label: {
                    Text(option.label).font(.geist(12, .semibold)).foregroundStyle(on ? Ink.onSurface : Ink.onVariant)
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(on ? Ink.high : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show \(option.label)")
            }
        }
        .padding(2)
        .boxed(Ink.low, radius: Theme.Radius.chip)
    }
}


/// "Chat moved to the Bin · Undo".
struct UndoBar: View {
    let toast: LibraryState.Toast
    let onUndo: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Glyph(kind: .check, size: 14, color: Ink.onSurface)
            Text(toast.text).font(.mUI).foregroundStyle(Ink.onSurface).lineLimit(1)
            Spacer(minLength: 6)
            if !toast.undo.isEmpty {
                Button("Undo", action: onUndo)
                    .buttonStyle(.plain).font(.mUI.weight(.semibold)).foregroundStyle(Ink.onSurface)
                    .accessibilityLabel("Undo").probe("undo")
            }
            Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Ink.outline) }
                .buttonStyle(.plain).accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .boxed(Ink.high, radius: Theme.Radius.chip, border: Ink.strong)
    }
}


/// A small rectangular tag (radius 4): the sector with its glyph, an app, an outcome.
struct Chip: View {
    enum Tone { case primary, neutral }
    let text: String
    var tone: Tone = .neutral
    /// A sector name: its glyph leads the tag.
    var sector: String?

    var body: some View {
        HStack(spacing: 5) {
            if let sector { sectorGlyph(sector, size: 12) }
            Text(text).font(.geist(12, .semibold)).lineLimit(1)
        }
        .foregroundStyle(tone == .primary ? Ink.onSurface : Ink.onVariant)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .boxed(tone == .primary ? Ink.high : Ink.low, radius: Theme.Radius.chip)
    }
}

/// The highlighted passage: a 2px accent bar, the quote in Geist Italic, and a mono "SELECTION · App" label.
struct Callout: View {
    let text: String
    var app = ""
    /// (Kept for callers: the bar needs no sweep.)
    var sweep = false

    var body: some View {
        QuoteMark(text: text, label: app.isEmpty ? "Selection" : "Selection · \(app)", animated: false, lines: 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The box along the bottom of a page: type something and it starts a chat about this page.
struct PromptBar: View {
    let placeholder: String
    let onSend: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    private var ready: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func send() {
        guard ready else { return }
        onSend(text.trimmingCharacters(in: .whitespacesAndNewlines))
        text = ""
    }

    var body: some View {
        HStack(spacing: 8) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain).font(.mUI).foregroundStyle(Ink.onSurface)
                .focused($focused)
                .padding(.horizontal, 12).frame(height: 34)
                .libField(focused: focused)
                .onSubmit(send)
            Button(action: send) {
                HStack(spacing: 5) {
                    Text("Send")
                    Image(systemName: "arrow.up").font(.system(size: 10, weight: .semibold))
                }
                .font(.mUI.weight(.medium))
                .foregroundStyle(ready ? Ink.onAccent : Ink.outline)
                .padding(.horizontal, 12).frame(height: 34)
                .background {
                    // Ghost while empty (hairline only, two fills); accent fill once there is text.
                    ZStack {
                        RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(ready ? Ink.accent : Ink.edge)
                        RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(ready ? Ink.accent : Ink.lowest).padding(1)
                    }
                }
                .animation(Motion.animation(Motion.quick), value: ready)
            }
            .buttonStyle(.plain).disabled(!ready)
            .help("Starts a chat about this").accessibilityLabel("Send")
        }
        .padding(12)
        .background(Ink.lowest)
        .overlay(alignment: .top) { HLine() }
    }
}

/// A page's centered column.
struct Page<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) { content }
                .frame(maxWidth: 720, alignment: .leading)
                .padding(.horizontal, 24).padding(.vertical, 26)
                .frame(maxWidth: .infinity)
        }
    }
}


// MARK: - Details

/// One question and its answer: a mono "Q" in the margin, the question in medium, then the answer.
struct LibraryTurn: View {
    let question: String
    let answer: String
    let speech: SpeechStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(question).font(.geist(14, .semibold)).foregroundStyle(Ink.onSurface).textSelection(.enabled)
            }
            AnswerView(text: answer, streaming: false, speech: speech)
        }
    }
}

struct ChatDetail: View {
    let chat: ChatRecord
    var moveRequest = 0
    let onMove: (String) -> Void
    let onAsk: (_ selection: String, _ prompt: String) -> Void
    let onClear: () -> Void
    @State private var name = ""
    @State private var speech = SpeechStore()
    @FocusState private var titleFocused: Bool

    /// Saves what's typed as the chat's name (and stops Margin renaming it), if it's really different.
    private func commitName() {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t != chat.title else { name = chat.title; return }
        Library.shared.rename(chat.id, to: t)
    }

    var body: some View {
        VStack(spacing: 0) {
            DetailHeader(sector: chat.sector, app: chat.app, when: chat.created, moveRequest: moveRequest, onMove: onMove) {
                BarIconButton(symbol: chat.starred ? "star.fill" : "star", help: chat.starred ? "Unstar" : "Star (keeps it at the top and safe from delete)") {
                    Library.shared.setStarred(chat.id, !chat.starred)
                }
                BarIconButton(symbol: "questionmark.bubble", help: "Quiz me on this") { onAsk(digest, Prompts.quiz) }
                BarIconButton(symbol: "doc.on.doc", help: "Copy as Markdown") { copy() }
            } after: {
                Menu {
                    if chat.starred {
                        Button("Unstar to delete") { Library.shared.setStarred(chat.id, false) }
                    } else {
                        Button("Move to Bin", role: .destructive, action: onClear)
                    }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.outline)
                        .frame(width: 26, height: 26).contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("More").accessibilityLabel("More")
            }
            Page {
                HStack(spacing: 8) {
                    TextField("Title", text: $name)
                        .textFieldStyle(.plain).font(.mHeading).foregroundStyle(Ink.onSurface)
                        .focused($titleFocused)
                        .onSubmit { commitName() }
                        .onChange(of: titleFocused) { _, focused in if !focused { commitName() } }
                    if chat.titleLocked {
                        Button { Library.shared.unlockTitle(chat.id) } label: {
                            Image(systemName: "lock.fill").font(.mMeta).foregroundStyle(Ink.outline)
                        }
                        .buttonStyle(.plain)
                        .help("You named this chat, so Margin won't rename it. Click to let Margin name it again.")
                    }
                }
                if !chat.quote.isEmpty { Callout(text: chat.quote, app: chat.app) }
                ForEach(Array(chat.turns.enumerated()), id: \.offset) { _, turn in
                    LibraryTurn(question: turn.question, answer: turn.answer, speech: speech)
                }
                HStack(spacing: 8) {
                    Button { onAsk(digest, Prompts.quiz) } label: {
                        HStack(spacing: 6) { Image(systemName: "questionmark.circle").font(.system(size: 12)); Text("Quiz me") }.secondaryButtonLook(height: 28)
                    }.buttonStyle(LibPressStyle())
                    Button { copy() } label: {
                        HStack(spacing: 6) { Image(systemName: "doc.on.doc").font(.system(size: 12)); Text("Copy") }.secondaryButtonLook(height: 28)
                    }.buttonStyle(LibPressStyle())
                    Button { copyForClaude() } label: {
                        HStack(spacing: 6) { Image(systemName: "sparkles").font(.system(size: 12)); Text("Copy for Claude") }.secondaryButtonLook(height: 28)
                    }.buttonStyle(LibPressStyle()).help("Copies the whole chat as clean Markdown, ready to paste into Claude")
                }
                if !chat.quizzes.isEmpty {
                    HLine()
                    ForEach(Array(chat.quizzes.enumerated()), id: \.offset) { _, q in
                        Label("\(q.title): \(q.correct) of \(q.total) right · \(q.date.formatted(.dateTime.day().month(.abbreviated)))",
                              systemImage: "questionmark.circle").font(.geist(12, .medium)).foregroundStyle(Ink.onVariant)
                    }
                }
            }
            PromptBar(placeholder: "Ask something about this chat…") { onAsk(digest, $0) }
        }
        .onAppear { name = chat.title }
        .onChange(of: chat.title) { _, new in if !titleFocused { name = new } }
        .onChange(of: chat.id) { _, _ in name = chat.title }
    }

    /// A short version of the chat to quiz on in a fresh chat (so it costs one small call).
    private var digest: String {
        let text = chat.turns.map { "Q: \($0.question)\nA: \(Answer.plainText($0.answer))" }.joined(separator: "\n\n")
        return "\(chat.title)\n\n" + String(text.prefix(3500))
    }

    private func copyForClaude() {
        var md = "# \(chat.title)\n\n**Sector:** \(chat.sector)  \n**Date:** \(chat.created.formatted(date: .abbreviated, time: .shortened))\n"
        if !chat.quote.isEmpty { md += "\n> " + chat.quote.replacingOccurrences(of: "\n", with: "\n> ") + "\n" }
        for t in chat.turns { md += "\n## Q: \(t.question)\n\n\(Answer.plainText(t.answer))\n" }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(md, forType: .string)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("# \(chat.title)\n\n" + chat.transcript, forType: .string)
    }
}

struct NoteDetail: View {
    let note: Note
    var moveRequest = 0
    let onAsk: (_ selection: String, _ prompt: String) -> Void
    let onClear: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            DetailHeader(sector: note.sector, app: note.app, when: note.created, moveRequest: moveRequest, onMove: nil) {
                BarIconButton(symbol: "doc.on.doc", help: "Copy as Markdown") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Notebook.markdown(note), forType: .string)
                }
            } after: {
                BarIconButton(symbol: "trash", help: "Move to Bin (⌘⌫)", danger: true, action: onClear)
            }
            Page {
                Text(note.question).font(.mHeading).foregroundStyle(Ink.onSurface).textSelection(.enabled)
                if !note.quote.isEmpty { Callout(text: note.quote, app: note.app) }
                if note.kind == .missed { Chip(text: "Missed in a quiz") }
                MarkdownText(text: note.body, streaming: false)
            }
            PromptBar(placeholder: "Ask something about this note…") { onAsk("\(note.question)\n\n\(String(note.body.prefix(3500)))", $0) }
        }
    }
}

// MARK: - Screenshots

private let thumbnailCache = NSCache<NSString, NSImage>()

/// A small picture of a screenshot, read from the file in the background.
struct ScreenshotThumb: View {
    let url: URL
    var height: CGFloat = 44
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(Ink.high)
            if let image { Image(nsImage: image).resizable().scaledToFill() }
        }
        .frame(width: height * 1.5 - 2, height: height - 2)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
        .padding(1)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(Ink.strong))
        .task(id: url) {
            let key = url.path as NSString
            if let hit = thumbnailCache.object(forKey: key) { image = hit; return }
            let pixels = Int(height * 3)
            let loaded = await Task.detached(priority: .utility) { () -> NSImage? in
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: pixels,
                      ] as CFDictionary) else { return nil }
                return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }.value
            if let loaded { thumbnailCache.setObject(loaded, forKey: key) }
            image = loaded
        }
    }
}

struct ScreenshotDetail: View {
    let shot: ScreenshotRecord
    var moveRequest = 0
    let onMove: (String) -> Void
    let onAskImage: (_ jpeg: Data, _ appName: String) -> Void
    let onClear: () -> Void
    @State private var name = ""
    @State private var relabeling = false
    @State private var note: String?
    @FocusState private var titleFocused: Bool

    private var url: URL { Library.shared.imageURL(for: shot) }

    private func commitName() {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t != shot.title else { name = shot.title; return }
        Library.shared.rename(screenshot: shot.id, to: t)
    }

    var body: some View {
        VStack(spacing: 0) {
            DetailHeader(sector: shot.sector, app: shot.app, when: shot.created, moveRequest: moveRequest, onMove: onMove) {
                BarIconButton(symbol: "doc.on.doc", help: "Copy the picture") { copyImage() }
                BarIconButton(symbol: "folder.badge.gearshape", help: "Show Margin's copy in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                BarIconButton(symbol: "tag", help: Settings.shared.localMode && Settings.shared.localIsOnMac
                           ? "Re-label: Margin's model on this Mac labels it again (no Claude tokens)."
                           : "Re-label: Claude labels it again, a small call of about 400 tokens.") { if !relabeling { relabel() } }
            } after: {
                BarIconButton(symbol: "trash", help: "Move to Bin (⌘⌫)", danger: true, action: onClear)
            }
            Page {
                HStack(spacing: 8) {
                    TextField("Label", text: $name)
                        .textFieldStyle(.plain).font(.mHeading).foregroundStyle(Ink.onSurface)
                        .focused($titleFocused)
                        .onSubmit { commitName() }
                        .onChange(of: titleFocused) { _, focused in if !focused { commitName() } }
                    if shot.titleLocked {
                        Button { Library.shared.unlockTitle(screenshot: shot.id) } label: {
                            Image(systemName: "lock.fill").font(.mMeta).foregroundStyle(Ink.outline)
                        }
                        .buttonStyle(.plain)
                        .help("You named this screenshot, so Margin won't relabel it. Click to let Margin label it again.")
                    }
                }
                Text([shot.sourceLabel, shot.width > 0 ? "\(shot.width)×\(shot.height)" : ""].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.geist(12, .medium)).foregroundStyle(Ink.outline)
                if !shot.windowTitle.isEmpty, shot.windowTitle != shot.title {
                    Text(shot.windowTitle).font(.mUI).foregroundStyle(Ink.onVariant)
                }
                if let image = NSImage(contentsOf: url) {
                    Image(nsImage: image).resizable().scaledToFit()
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
                        .padding(1)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(Ink.edge))
                } else {
                    Label("The picture is missing.", systemImage: "exclamationmark.triangle").foregroundStyle(Ink.outline)
                }
                if !shot.text.isEmpty {
                    DisclosureGroup("Text found in it") {
                        Text(shot.text).font(.mUI).foregroundStyle(Ink.onVariant).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                    }
                    .foregroundStyle(Ink.onVariant)
                }
                if let note { Text(note).font(.geist(12, .medium)).foregroundStyle(Ink.outline) }
                Button { ask() } label: {
                    Label("Ask Margin about this", systemImage: "sparkles").primaryButtonLook(height: 28)
                }
                .buttonStyle(LibPressStyle()).help("Start a chat about this screenshot (it's sent to Claude).")
            }
        }
        .onAppear { name = shot.title }
        .onChange(of: shot.title) { _, new in if !titleFocused { name = new } }
    }

    private func copyImage() {
        guard let image = NSImage(contentsOf: url) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    /// A chat about it, sized for Claude like a snip is.
    private func ask() {
        guard let data = try? Data(contentsOf: url), let jpeg = Snipper.downscaledJPEG(data) else { return }
        onAskImage(jpeg, shot.app.isEmpty ? "your screen" : shot.app)
    }

    private func relabel() {
        relabeling = true
        note = nil
        ScreenshotInbox.shared.relabel(shot.id) { tokens in
            relabeling = false
            note = tokens > 0 ? "Claude used about \(tokens) tokens to label it." : nil
        }
    }
}

// MARK: - The Bin's page

/// A deleted thing, read-only, with the two things you can do: put it back, or delete it for good.
struct BinDetail: View {
    let item: BinItem
    let daysLeft: Int
    let onRestore: () -> Void
    let onForever: () -> Void
    @State private var speech = SpeechStore()

    var body: some View {
        VStack(spacing: 0) {
            DetailHeader(sector: item.sector, app: "", when: item.made, onMove: nil) {
                Button(action: onRestore) {
                    Label("Restore", systemImage: "arrow.uturn.backward").secondaryButtonLook(height: 24)
                }
                .buttonStyle(LibPressStyle()).help("Put it back where it was")
                .accessibilityLabel("Restore")
            } after: {
                BarIconButton(symbol: "xmark.bin", help: "Delete forever", danger: true, action: onForever)
            }
            Page {
                HStack(spacing: 10) {
                    Glyph(kind: .emptyVoid, size: 18, color: Ink.onVariant)
                    Text("Deleted \(item.deleted.formatted(.relative(presentation: .named))). \(daysLeft == Int.max ? "It stays until you empty the Bin" : "It's deleted for good in \(daysLeft) day\(daysLeft == 1 ? "" : "s")"), unless you restore it.")
                        .font(.mUI).foregroundStyle(Ink.onVariant)
                    Spacer(minLength: 0)
                }
                .padding(12)
                .boxed(Ink.low, radius: Theme.Radius.chip)
                preview
            }
        }
    }

    @ViewBuilder
    private var preview: some View {
        switch item.kind {
        case .chat:
            if let chat = item.chat {
                HStack(spacing: 8) {
                    Chip(text: chat.sector, tone: .primary, sector: chat.sector)
                    if !chat.app.isEmpty { Chip(text: chat.app) }
                }
                Text(chat.title).font(.mHeading).foregroundStyle(Ink.onSurface)
                if !chat.quote.isEmpty { Callout(text: chat.quote, app: chat.app) }
                ForEach(Array(chat.turns.enumerated()), id: \.offset) { _, turn in
                    LibraryTurn(question: turn.question, answer: turn.answer, speech: speech)
                }
            }
        case .note:
            if let note = item.note {
                HStack(spacing: 8) {
                    Chip(text: note.sector, tone: .primary, sector: note.sector)
                    if !note.app.isEmpty { Chip(text: note.app) }
                }
                Text(note.question).font(.mHeading).foregroundStyle(Ink.onSurface)
                if !note.quote.isEmpty { Callout(text: note.quote, app: note.app) }
                MarkdownText(text: note.body, streaming: false)
            }
        case .screenshot:
            if let shot = item.screenshot {
                HStack(spacing: 8) {
                    Chip(text: shot.sector, tone: .primary, sector: shot.sector)
                    if !shot.app.isEmpty { Chip(text: shot.app) }
                }
                Text(shot.title).font(.mHeading).foregroundStyle(Ink.onSurface)
                if let image = NSImage(contentsOf: Library.shared.imageURL(for: shot)) {
                    Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
                        .padding(1)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(Ink.edge))
                }
                if !shot.text.isEmpty {
                    Text(shot.text).font(.mUI).foregroundStyle(Ink.onVariant).textSelection(.enabled)
                }
            }
        }
    }
}

private extension View {
    /// A list row's hover highlight; the whole row stays clickable, not just its text.
    func rowHoverFill(_ hover: Bool) -> some View {
        background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(hover ? Ink.container : .clear))
            .contentShape(Rectangle())
    }
}
