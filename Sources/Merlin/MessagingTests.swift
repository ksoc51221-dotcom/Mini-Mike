import AppKit
import WebKit

private final class FakeChatWorkspace: DockWorkspace {
    var opened: [URL] = []
    func url(forBundleID id: String) -> URL? { URL(fileURLWithPath: "/Applications/\(id).app") }
    func open(_ url: URL) { opened.append(url) }
    func installedApps() -> [DockApp] { [] }
    func icon(for url: URL) -> NSImage { NSImage(size: NSSize(width: 1, height: 1)) }
}

extension FeatureTests {
    /// The messaging mini windows. No page is loaded and no window is shown.
    static func messagingChecks(_ check: (String, Bool) -> Void) {
        let all = MessagingService.all
        check("chat cards: the table holds Telegram and WhatsApp, on https", all.map(\.name) == ["Telegram", "WhatsApp"] && all.allSatisfy { $0.url.scheme == "https" })
        check("chat cards: each service has its own data store",
              Set(all.map(\.storeID)).count == all.count
                  && MessagingWebView.configuration(for: .telegram).websiteDataStore.identifier == MessagingService.telegram.storeID)

        check("chat cards: only WhatsApp gets Safari's user agent ending",
              MessagingService.telegram.agentSuffix == nil
                  && MessagingWebView.configuration(for: .whatsApp).applicationNameForUserAgent == MessagingService.whatsApp.agentSuffix)
        check("chat cards: only a service on the ring is loaded ahead",
              MessagingService.toPreload(pinned: []).isEmpty
                  && MessagingService.toPreload(pinned: [DockApp(bundleID: MessagingService.whatsApp.bundleID, name: "WhatsApp")]) == [.whatsApp])

        func link(_ s: String, clicked: Bool = true) -> MessagingWebView.LinkAction {
            MessagingWebView.linkAction(URL(string: s)!, clicked: clicked, service: .telegram)
        }
        check("chat cards: a link to another site opens in the browser", link("https://example.com/a") == .browser)
        check("chat cards: a link inside the service stays in the card", link("https://web.telegram.org/a/#1") == .stay)
        check("chat cards: other schemes from a page are blocked", link("file:///etc/hosts") == .block && link("tg://x", clicked: false) == .block)
        check("chat cards: camera and microphone are refused", MessagingWebView.mediaDecision == .deny)
        check("chat cards: the card asks to be left out of screen pictures", MessagingPanel().sharingType == .none)
        check("chat cards: no tool of the agent reaches a web view",
              !AgentTools.names.contains { n in ["web_view", "webview", "telegram", "chat", "javascript"].contains { n.contains($0) } })

        let suite = "merlin.messaging.test"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let ws = FakeChatWorkspace()
        let model = EdgePanelModel(apps: DockAppStore(defaults: defaults, workspace: ws), spotify: .shared)
        let telegram = DockApp(bundleID: MessagingService.telegram.bundleID, name: "Telegram")
        var asked: [MessagingService] = []
        model.onChat = { asked.append($0) }
        model.tapApp(telegram)
        check("chat cards: the Telegram icon opens the card, not the app", asked == [.telegram] && ws.opened.isEmpty)
        model.tapApp(DockApp(bundleID: "com.example.other", name: "Other"))
        check("chat cards: any other icon opens its app", asked.count == 1 && ws.opened.count == 1)
    }
}
