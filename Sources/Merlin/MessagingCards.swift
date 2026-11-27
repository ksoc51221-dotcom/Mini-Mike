import AppKit
import Combine
import SwiftUI

/// One messaging service with a mini window. A fixed table: Merlin opens no other site in a card.
struct MessagingService: Equatable {
    let name: String
    /// The Mac app: its ring icon opens the card, and "Open app" opens it.
    let bundleID: String
    let url: URL
    /// Names the service's own saved web data. Never change it: a new value signs Merlin's user out.
    let storeID: UUID
    /// Added to the web view's user agent. Only for a site that refuses the plain web view: the ending Safari itself sends
    /// (the engine is Safari's).
    var agentSuffix: String? = nil

    // "/a/" is Telegram's own web app that lays out at card width.
    static let telegram = MessagingService(name: "Telegram", bundleID: "ru.keepcoder.Telegram",
                                           url: URL(string: "https://web.telegram.org/a/")!,
                                           storeID: UUID(uuidString: "6E1F3B52-7C0A-4C9E-9B0D-2A5E8F41C701")!)
    static let whatsApp = MessagingService(name: "WhatsApp", bundleID: "net.whatsapp.WhatsApp",
                                           url: URL(string: "https://web.whatsapp.com/")!,
                                           storeID: UUID(uuidString: "6E1F3B52-7C0A-4C9E-9B0D-2A5E8F41C702")!,
                                           agentSuffix: "Version/26.3 Safari/605.1.15")
    static let all = [telegram, whatsApp]

    /// The services loaded ahead of a click: only those on the ring.
    static func toPreload(pinned: [DockApp]) -> [MessagingService] { all.filter { s in pinned.contains { $0.bundleID == s.bundleID } } }

    static func of(bundleID: String) -> MessagingService? { all.first { $0.bundleID == bundleID } }
}

/// The mini window's own panel (the dock's window is too small for it). Non-activating, so the front app stays active.
final class MessagingPanel: FloatingPanel {
    static let cardSize = CGSize(width: 420, height: 560)

    init() {
        super.init(size: Self.cardSize, canKey: true)
        // Keeps the chat out of other programs' pictures of the screen, where macOS obeys it.
        sharingType = .none
    }

    /// Cut, copy, paste, select all and undo, also while Merlin is not the active app.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard flags == .command || flags == [.command, .shift], let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        let action: Selector
        switch (key, flags.contains(.shift)) {
        case ("x", false): action = #selector(NSText.cut(_:))
        case ("c", false): action = #selector(NSText.copy(_:))
        case ("v", false): action = #selector(NSText.paste(_:))
        case ("a", false): action = #selector(NSText.selectAll(_:))
        case ("z", false): action = Selector(("undo:"))
        case ("z", true): action = Selector(("redo:"))
        default: return false
        }
        return NSApp.sendAction(action, to: nil, from: self)
    }
}

/// Shows and closes the mini windows. A service on the ring is loaded a few seconds after launch and kept alive in its own
/// hidden panel, so a click only shows it: nothing loads or reloads at a click. The dock decides when a card hides.
final class MessagingCardController {
    static let shared = MessagingCardController()
    /// After launch (or after an app is added to the ring), so the load does not slow the launch.
    static let preloadDelay: TimeInterval = 3

    private struct Card {
        let panel: MessagingPanel
        let web: MessagingWebView
        let header: NSHostingView<MessagingHeader>
    }
    private var cards: [String: Card] = [:]
    private(set) var open: MessagingService?
    private weak var model: EdgePanelModel?
    private var subscriptions: Set<AnyCancellable> = []
    private var memoryWarning: DispatchSourceMemoryPressure?

    /// The app only (never a test): a click on a service's ring icon now opens its card.
    func attach(_ model: EdgePanelModel, dockWindow: @escaping () -> NSRect) {
        self.model = model
        model.onChat = { [weak self] service in self?.toggle(service, dockWindow: dockWindow()) }
        // The Mac is critically short of memory: closed cards go (the sign-in stays on disk; the next click loads again).
        let warning = DispatchSource.makeMemoryPressureSource(eventMask: .critical, queue: .main)
        warning.setEventHandler { [weak self] in
            guard let self else { return }
            self.cards = self.cards.filter { $0.key == self.open?.bundleID }
        }
        warning.activate()
        memoryWarning = warning
        // The dock hides (Esc, a click outside, a snip, point to ask) or shows another card: the chat goes at once.
        model.$shown.sink { [weak self] shown in if !shown { self?.close() } }.store(in: &subscriptions)
        model.$section.sink { [weak self] section in if section != nil { self?.close() } }.store(in: &subscriptions)
        model.apps.$pinned
            .delay(for: .seconds(Self.preloadDelay), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.syncWithRing() }
            .store(in: &subscriptions)
    }

    /// Loads the services on the ring and frees those taken off it. Reads the ring as it is now.
    private func syncWithRing() {
        guard let model else { return }
        let wanted = MessagingService.toPreload(pinned: model.apps.pinned)
        wanted.forEach { _ = card(for: $0) }
        for id in cards.keys where !wanted.contains(where: { $0.bundleID == id }) && open?.bundleID != id { cards[id] = nil }
    }

    /// The kept card, or a new one that starts to load now.
    private func card(for service: MessagingService) -> Card {
        if let card = cards[service.bundleID] { return card }
        let panel = MessagingPanel()
        let web = MessagingWebView(service: service)
        let size = MessagingPanel.cardSize, top = EdgePanelLayout.headerHeight
        let box = NSView(frame: NSRect(origin: .zero, size: size))
        box.wantsLayer = true
        box.layer?.cornerRadius = EdgePanelLayout.cardRadius
        box.layer?.cornerCurve = .continuous
        box.layer?.masksToBounds = true
        box.layer?.borderWidth = 1
        web.view.frame = NSRect(x: 0, y: 0, width: size.width, height: size.height - top)
        let header = NSHostingView(rootView: header(for: service, web: web))
        header.frame = NSRect(x: 0, y: size.height - top, width: size.width, height: top)
        box.addSubview(web.view)
        box.addSubview(header)
        panel.contentView = box
        web.setShown(false)
        web.onPickerClosed = { [weak self] in
            guard let self, self.open == service else { return }
            self.cards[service.bundleID]?.panel.makeKey()
        }
        let card = Card(panel: panel, web: web, header: header)
        cards[service.bundleID] = card
        return card
    }

    private func header(for service: MessagingService, web: MessagingWebView) -> MessagingHeader {
        MessagingHeader(name: service.name, palette: model?.palette ?? .standard,
                        reload: { [weak web] in web?.reload() },
                        openApp: { [weak self] in
                            let app = DockApp(bundleID: service.bundleID, name: service.name)
                            self?.model?.apps.open(app)
                            self?.model?.onOpenApp?(app)
                        },
                        close: { [weak self] in self?.close() })
    }

    /// The dock stays while a card is open, wherever the pointer goes.
    var holdsDock: Bool { open != nil }

    /// True when the dock must ignore this event: anything while the file picker is up, or a click in the card.
    func keeps(_ e: NSEvent) -> Bool {
        guard let open, let card = cards[open.bundleID] else { return false }
        if card.web.pickerOpen { return true }
        return e.type != .keyDown && card.panel.frame.contains(NSEvent.mouseLocation)
    }

    func toggle(_ service: MessagingService, dockWindow: NSRect) {
        if open == service { return close() }
        close()
        model?.section = nil
        let card = card(for: service)
        open = service
        card.web.retryIfFailed()
        card.web.setShown(true)
        let palette = model?.palette ?? .standard // the dock's colours now
        card.header.rootView = header(for: service, web: card.web)
        card.panel.contentView?.layer?.backgroundColor = palette.baseDark.cgColor
        card.panel.contentView?.layer?.borderColor = palette.rimTint.withAlphaComponent(0.3).cgColor
        card.panel.setFrame(EdgePanelLayout.listFrame(window: dockWindow, card: MessagingPanel.cardSize), display: true)
        card.panel.orderFrontRegardless()
        card.panel.makeKey()
        card.panel.makeFirstResponder(card.web.view)
    }

    func close() {
        guard let service = open else { return }
        open = nil
        cards[service.bundleID]?.panel.orderOut(nil)
        cards[service.bundleID]?.web.setShown(false)
    }
}

private struct MessagingHeader: View {
    let name: String
    let palette: DockPalette
    let reload: () -> Void
    let openApp: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Text(name).font(.geist(13, .medium))
            Spacer()
            button("arrow.clockwise", "Reload", reload)
            button("arrow.up.forward.app", "Open the \(name) app", openApp)
            button("xmark", "Close", close)
        }
        .foregroundStyle(palette.inkColor)
        .padding(.horizontal, 14)
        .frame(height: EdgePanelLayout.headerHeight)
    }

    private func button(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 24, height: 24).contentShape(Rectangle()) }
            .buttonStyle(EdgePressStyle())
            .help(help)
            .accessibilityLabel(help)
    }
}
