import AppKit
import Combine
import SwiftUI
import WebKit

/// One messaging service with a mini window. A fixed table: Merlin opens no other site in a card.
struct MessagingService: Equatable {
    let name: String
    /// The Mac app: its ring icon opens the card, and "Open app" opens it.
    let bundleID: String
    let url: URL
    /// Names the service's own saved web data. Never change it: a new value signs Merlin's user out.
    let storeID: UUID

    // "/a/" is Telegram's own web app that lays out at card width.
    static let telegram = MessagingService(name: "Telegram", bundleID: "ru.keepcoder.Telegram",
                                           url: URL(string: "https://web.telegram.org/a/")!,
                                           storeID: UUID(uuidString: "6E1F3B52-7C0A-4C9E-9B0D-2A5E8F41C701")!)
    static let all = [telegram]

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

/// Shows and closes the mini window. The dock decides when it hides; the card follows with no exit animation.
final class MessagingCardController {
    static let shared = MessagingCardController()
    /// A web view with a closed card for this long is freed (the sign-in stays on disk).
    static let idleLimit: TimeInterval = 10 * 60

    private var panel: MessagingPanel?
    private var webs: [String: MessagingWebView] = [:]
    private var idle: [String: Timer] = [:]
    private(set) var open: MessagingService?
    private weak var model: EdgePanelModel?
    private var subscriptions: Set<AnyCancellable> = []

    /// The app only (never a test): a click on a service's ring icon now opens its card.
    func attach(_ model: EdgePanelModel, dockWindow: @escaping () -> NSRect) {
        self.model = model
        model.onChat = { [weak self] service in self?.toggle(service, dockWindow: dockWindow()) }
        // The dock hides (Esc, a click outside, a snip, point to ask) or shows another card: the chat goes at once.
        model.$shown.sink { [weak self] shown in if !shown { self?.close() } }.store(in: &subscriptions)
        model.$section.sink { [weak self] section in if section != nil { self?.close() } }.store(in: &subscriptions)
    }

    /// The dock stays while a card is open, wherever the pointer goes.
    var holdsDock: Bool { open != nil }

    /// True when the dock must ignore this event: anything while the file picker is up, or a click in the card.
    func keeps(_ e: NSEvent) -> Bool {
        guard let open, let panel else { return false }
        if webs[open.bundleID]?.pickerOpen == true { return true }
        return e.type != .keyDown && panel.frame.contains(NSEvent.mouseLocation)
    }

    func toggle(_ service: MessagingService, dockWindow: NSRect) {
        if open == service { return close() }
        close()
        model?.section = nil
        open = service
        idle.removeValue(forKey: service.bundleID)?.invalidate()
        let web = webs[service.bundleID] ?? MessagingWebView(service: service)
        webs[service.bundleID] = web
        web.onPickerClosed = { [weak self, weak web] in
            guard let self, let web, self.open == web.service else { return }
            self.panel?.makeKey()
        }
        let panel = self.panel ?? MessagingPanel()
        self.panel = panel
        let card = MessagingCard(service: service, web: web, palette: model?.palette ?? .standard,
                                 openApp: { [weak self] in
                                     self?.model?.apps.open(DockApp(bundleID: service.bundleID, name: service.name))
                                     self?.model?.onOpenApp?(DockApp(bundleID: service.bundleID, name: service.name))
                                 },
                                 close: { [weak self] in self?.close() })
        panel.contentView = NSHostingView(rootView: card)
        panel.setFrame(EdgePanelLayout.listFrame(window: dockWindow, card: MessagingPanel.cardSize), display: true)
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(web.view)
    }

    func close() {
        guard let service = open else { return }
        open = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        idle[service.bundleID] = Timer.scheduledTimer(withTimeInterval: Self.idleLimit, repeats: false) { [weak self] _ in
            self?.webs[service.bundleID] = nil
            self?.idle[service.bundleID] = nil
        }
    }
}

private struct MessagingCard: View {
    let service: MessagingService
    let web: MessagingWebView
    let palette: DockPalette
    let openApp: () -> Void
    let close: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: EdgePanelLayout.cardRadius, style: .continuous)
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Text(service.name).font(.geist(13, .medium))
                Spacer()
                button("arrow.clockwise", "Reload") { web.reload() }
                button("arrow.up.forward.app", "Open the \(service.name) app", openApp)
                button("xmark", "Close", close)
            }
            .foregroundStyle(palette.inkColor)
            .padding(.horizontal, 14)
            .frame(height: EdgePanelLayout.headerHeight)
            MessagingWebHost(view: web.view)
        }
        .background(palette.baseDarkColor)
        .clipShape(shape)
        .overlay(shape.strokeBorder(palette.rimTintColor.opacity(0.3), lineWidth: 1))
    }

    private func button(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 24, height: 24).contentShape(Rectangle()) }
            .buttonStyle(EdgePressStyle())
            .help(help)
            .accessibilityLabel(help)
    }
}

/// Puts the kept web view into the card.
private struct MessagingWebHost: NSViewRepresentable {
    let view: WKWebView
    func makeNSView(context: Context) -> NSView {
        let box = NSView()
        view.frame = box.bounds
        view.autoresizingMask = [.width, .height]
        box.addSubview(view)
        DispatchQueue.main.async { [weak view] in view?.window?.makeFirstResponder(view) }
        return box
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
