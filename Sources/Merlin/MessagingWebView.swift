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

    /// The unread count in the page's title, such as "(3) WhatsApp" or "Telegram (3)". Only the number is kept; the
    /// title is never stored or logged (it can name a chat).
    static func unreadCount(inTitle title: String?) -> Int? {
        guard let title, let r = title.range(of: #"\((\d{1,4})\)"#, options: .regularExpression) else { return nil }
        return Int(title[r].dropFirst().dropLast())
    }

    /// A fixed check, run by Merlin itself (no agent tool reaches it): can the page keep a secret key, as WhatsApp Web
    /// must? WebKit keeps such keys with "Merlin WebCrypto Master Key" in the keychain; a Deny there makes this fail.
    /// It reads nothing of the page.
    static let keyCheckScript = """
    const k = await crypto.subtle.generateKey({name: "AES-GCM", length: 128}, false, ["encrypt"]);
    return await new Promise((ok) => {
      const open = indexedDB.open("merlin-keycheck", 1);
      open.onupgradeneeded = () => open.result.createObjectStore("k");
      open.onerror = () => ok("no-db");
      open.onsuccess = () => {
        const db = open.result;
        const tx = db.transaction("k", "readwrite");
        try { tx.objectStore("k").put(k, "k"); } catch (e) { db.close(); indexedDB.deleteDatabase("merlin-keycheck"); return ok("refused"); }
        tx.oncomplete = () => { db.close(); indexedDB.deleteDatabase("merlin-keycheck"); ok("ok"); };
        tx.onerror = () => { db.close(); indexedDB.deleteDatabase("merlin-keycheck"); ok("refused"); };
      };
    });
    """

    /// The unread count changed (nil: none shown in the title).
    var onUnread: ((Int?) -> Void)?
    /// False when the page could not keep its keys (see `keyCheckScript`).
    private(set) var keysOK = true
    var onKeysChanged: (() -> Void)?
    private var titleWatch: NSKeyValueObservation?

    init(service: MessagingService) {
        self.service = service
        view = FirstClickWebView(frame: .zero, configuration: Self.configuration(for: service))
        super.init()
        view.navigationDelegate = self
        view.uiDelegate = self
        titleWatch = view.observe(\.title, options: [.new]) { [weak self] web, _ in
            let n = Self.unreadCount(inTitle: web.title)
            DispatchQueue.main.async { self?.onUnread?(n) }
        }
        MessagingLog.note(service, "load start")
        view.load(URLRequest(url: service.url))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MessagingLog.note(service, "load finished")
        guard service.checksKeys else { return }
        webView.callAsyncJavaScript(Self.keyCheckScript, arguments: [:], in: nil, in: .defaultClient) { [weak self] result in
            guard let self else { return }
            let answer = (try? result.get()) as? String ?? "error"
            MessagingLog.note(self.service, "key storage: \(answer)")
            let ok = answer == "ok"
            if ok != self.keysOK { self.keysOK = ok; self.onKeysChanged?() }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MessagingLog.note(service, "load failed \((error as NSError).code)")
    }

    /// A closed card plays nothing: a video or voice message stops, and the page cannot start one.
    func setShown(_ shown: Bool) { view.setAllMediaPlaybackSuspended(!shown, completionHandler: nil) }

    private var failed = false
    func reload() {
        failed = false
        view.load(URLRequest(url: service.url))
    }
    /// A load that never arrived (no network at launch) is tried again at the next click. Nothing else reloads there.
    func retryIfFailed() { if failed { reload() } }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MessagingLog.note(service, "load failed early \((error as NSError).code)")
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

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        MessagingLog.note(service, "web process ended; loading again")
        reload()
    }

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
        let front = NSWorkspace.shared.frontmostApplication
        NSApp.activate()
        panel.begin { [weak self] answer in
            completionHandler(answer == .OK ? panel.urls : nil)
            // The click that closed the picker must still count as the picker's.
            DispatchQueue.main.async {
                self?.pickerOpen = false
                // The picker made Merlin the active app; the app you were in gets that back.
                if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { front?.activate() }
                self?.onPickerClosed?()
            }
        }
    }
}

/// The first click acts at once, also while another app is active.
private final class FirstClickWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Events of the cards, for a fault report: ~/Library/Logs/Merlin/messaging.log. Service names and events only; never an
/// address, a title or any page text.
enum MessagingLog {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Merlin/messaging.log")
    static var enabled = true
    static func note(_ service: MessagingService, _ event: String) {
        guard enabled else { return }
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(service.name): \(event)\n"
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? Data(line.utf8).write(to: url) }
    }
}
