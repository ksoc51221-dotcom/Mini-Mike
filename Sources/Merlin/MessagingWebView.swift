import AppKit
import WebKit

/// The web view of one messaging service. Merlin only shows it: nothing here reads the page, runs a script in it, or logs
/// an address or a title (they can hold chat names).
final class MessagingWebView: NSObject, WKNavigationDelegate, WKUIDelegate {
    enum LinkAction: Equatable { case stay, browser, block }

    /// A clicked link to another site opens in the default browser. Only web links leave the card; other schemes from a
    /// page are blocked. Loads that are not a click (redirects, frames) stay in the page.
    static func linkAction(_ url: URL, clicked: Bool, service: MessagingService) -> LinkAction {
        switch url.scheme?.lowercased() {
        case "https", "http":
            guard clicked else { return .stay }
            return url.host?.lowercased() == service.url.host ? .stay : .browser
        case "about", "blob", "data": return .stay
        default: return .block
        }
    }

    /// Camera and microphone: refused in version 1.
    static let mediaDecision = WKPermissionDecision.deny

    /// One saved store for each service: the sign-in stays between launches, and services share no cookies.
    static func configuration(for service: MessagingService) -> WKWebViewConfiguration {
        let c = WKWebViewConfiguration()
        c.websiteDataStore = WKWebsiteDataStore(forIdentifier: service.storeID)
        if let suffix = service.agentSuffix { c.applicationNameForUserAgent = suffix }
        // Never suspend the page fully (as WebKit may with a view outside any window), so it is up to date at a click.
        c.preferences.inactiveSchedulingPolicy = .throttle
        return c
    }

    let service: MessagingService
    let view: WKWebView
    /// A file picker is open: a click or Esc in it must not hide the dock.
    private(set) var pickerOpen = false
    var onPickerClosed: (() -> Void)?

    init(service: MessagingService) {
        self.service = service
        view = FirstClickWebView(frame: .zero, configuration: Self.configuration(for: service))
        super.init()
        view.navigationDelegate = self
        view.uiDelegate = self
        view.load(URLRequest(url: service.url))
    }

    private var failed = false
    func reload() {
        failed = false
        view.load(URLRequest(url: service.url))
    }
    /// A load that never arrived (no network at launch) is tried again at the next click. Nothing else reloads there.
    func retryIfFailed() { if failed { reload() } }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { failed = true }
    }

    private func openOutside(_ url: URL) {
        if url.scheme == "https" || url.scheme == "http" { NSWorkspace.shared.open(url) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { return decisionHandler(.cancel) }
        // A link for a new window goes to `createWebViewWith`.
        guard action.targetFrame != nil else { return decisionHandler(.allow) }
        switch Self.linkAction(url, clicked: action.navigationType == .linkActivated, service: service) {
        case .stay: decisionHandler(.allow)
        case .browser:
            openOutside(url)
            decisionHandler(.cancel)
        case .block: decisionHandler(.cancel)
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { reload() }

    /// A new window (target="_blank"): never a second web view. The link opens in the browser.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url { openOutside(url) }
        return nil
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
        decisionHandler(Self.mediaDecision)
    }

    /// Attachments.
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1) // above the dock
        pickerOpen = true
        NSApp.activate()
        panel.begin { [weak self] answer in
            completionHandler(answer == .OK ? panel.urls : nil)
            // The click that closed the picker must still count as the picker's.
            DispatchQueue.main.async {
                self?.pickerOpen = false
                self?.onPickerClosed?()
            }
        }
    }
}

/// The first click acts at once, also while another app is active.
private final class FirstClickWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
