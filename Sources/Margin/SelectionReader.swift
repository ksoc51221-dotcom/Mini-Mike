import AppKit
import ApplicationServices

struct Selection {
    let text: String
    let appName: String
    /// Nearby text, resolved in the background so the ? icon can appear immediately.
    let context: ContextBox
    /// Where it came from, for the screenshot.
    let pid: pid_t
    let mouse: NSPoint
    /// The app it came from (to spot browsers, for "Summarize video").
    var bundleID: String? = nil
    /// Set for Tab+\ snips: a JPEG of the area the user boxed (then `text` is empty).
    var regionImage: Data? = nil
    /// Set for video agents: what to summarize.
    var video: VideoSource? = nil

    /// Opened with Option+Shift+Tab with nothing highlighted: a plain "ask anything" chat.
    var isBlank: Bool { text.isEmpty && regionImage == nil && video == nil }
}

/// A value computed off the main thread, read once when the popup opens.
final class ContextBox {
    private let lock = NSLock()
    private var value: String?
    private var resolved = false
    private let semaphore = DispatchSemaphore(value: 0)

    init() {}

    init(resolved value: String?) {
        self.value = value
        self.resolved = true
    }

    func fulfill(_ v: String?) {
        lock.lock()
        value = v
        resolved = true
        lock.unlock()
        semaphore.signal()
    }

    func get(waitingUpTo timeout: TimeInterval) -> String? {
        lock.lock()
        if resolved { defer { lock.unlock() }; return value }
        lock.unlock()
        _ = semaphore.wait(timeout: .now() + timeout)
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Reads the current text selection in the frontmost app.
/// Order: Accessibility API (with nearby context) → ⌘C fallback that restores the clipboard.
enum SelectionReader {
    /// AX calls are blocking IPC, so they run here instead of on the main thread.
    private static let queue = DispatchQueue(label: "margin.selection", qos: .userInitiated)
    private static var manualAXEnabledPIDs = Set<pid_t>() // only touched on `queue`

    /// Set while a synthetic ⌘C is in flight so the watcher can ignore it.
    static var syntheticCopyUntil = Date.distantPast

    static func configure() {
        // Never let an unresponsive app stall us for long.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.3)
    }

    /// `mouse` is in Cocoa screen coordinates (bottom-left origin). Completion runs on main.
    /// `allowCopy: false` skips the ⌘C fallback (for the keyboard shortcut, where nothing may be selected).
    static func read(app: NSRunningApplication, mouse: NSPoint, allowCopy: Bool = true,
                     completion: @escaping (Selection?) -> Void) {
        let appName = app.localizedName ?? "an app"
        let pid = app.processIdentifier
        let bundleID = app.bundleIdentifier
        let skipCopy = !allowCopy || Settings.shared.noCopyFallbackBundleIDs.contains(app.bundleIdentifier ?? "")
        // AX uses top-left-origin coordinates.
        let axPoint = CGPoint(x: mouse.x, y: (NSScreen.screens.first?.frame.height ?? 0) - mouse.y)

        queue.async {
            let found = axSelection(pid: pid)
            DispatchQueue.main.async {
                if let (text, element) = found {
                    let box = ContextBox()
                    completion(Selection(text: text, appName: appName, context: box, pid: pid, mouse: mouse, bundleID: bundleID))
                    queue.async {
                        box.fulfill(contextAroundSelection(in: element, selection: text)
                            ?? paragraphAt(axPoint, pid: pid).flatMap { cleanContext($0, selection: text) })
                    }
                    return
                }
                guard !skipCopy else { return completion(nil) }
                copyFallback { text in
                    guard let text else { return completion(nil) }
                    let box = ContextBox()
                    completion(Selection(text: text, appName: appName, context: box, pid: pid, mouse: mouse, bundleID: bundleID))
                    queue.async {
                        box.fulfill(paragraphAt(axPoint, pid: pid).flatMap { cleanContext($0, selection: text) })
                    }
                }
            }
        }
    }

    // MARK: - Accessibility path

    private static func axSelection(pid: pid_t) -> (String, AXUIElement)? {
        let appElement = AXUIElementCreateApplication(pid)

        // Electron apps (Claude.app, VS Code, Slack…) only build their accessibility tree when asked.
        if !manualAXEnabledPIDs.contains(pid) {
            AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            manualAXEnabledPIDs.insert(pid)
        }

        guard let focused = elementAttribute(appElement, kAXFocusedUIElementAttribute),
              let raw: String = attribute(focused, kAXSelectedTextAttribute) else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : (text, focused)
    }

    /// Text near the selection inside the focused element (text views, terminals, native apps).
    private static func contextAroundSelection(in element: AXUIElement, selection: String) -> String? {
        let radius = 800

        if let range = rangeAttribute(element, kAXSelectedTextRangeAttribute),
           let total: Int = attribute(element, kAXNumberOfCharactersAttribute) {
            let start = max(0, range.location - radius)
            let end = min(total, range.location + range.length + radius)
            var wide = CFRange(location: start, length: max(0, end - start))
            var out: CFTypeRef?
            if let wideValue = AXValueCreate(.cfRange, &wide),
               AXUIElementCopyParameterizedAttributeValue(
                   element, kAXStringForRangeParameterizedAttribute as CFString, wideValue, &out) == .success,
               let s = out as? String {
                let trimmed = trimToParagraphs(s, selection: selection, cutStart: start > 0, cutEnd: end < total)
                if let c = cleanContext(trimmed, selection: selection) { return c }
            }
        }

        if let value: String = attribute(element, kAXValueAttribute) {
            return contextWindow(in: value, around: selection, radius: radius)
        }
        return nil
    }

    /// Best effort for web content: the paragraph-ish block under the mouse.
    private static func paragraphAt(_ point: CGPoint, pid: pid_t) -> String? {
        let appElement = AXUIElementCreateApplication(pid)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(appElement, Float(point.x), Float(point.y), &hit) == .success,
              var node = hit else { return nil }

        if (attribute(node, kAXRoleAttribute) as String?) == (kAXStaticTextRole as String),
           let parent = elementAttribute(node, kAXParentAttribute) {
            node = parent
        }
        var text = collectText(node, budget: 80)
        if text.count < 160, let parent = elementAttribute(node, kAXParentAttribute) {
            text = collectText(parent, budget: 120)
        }
        return text.isEmpty ? nil : String(text.prefix(Prompts.maxContext))
    }

    private static func collectText(_ root: AXUIElement, budget: Int) -> String {
        var remaining = budget
        var pieces: [String] = []
        func walk(_ el: AXUIElement, depth: Int) {
            guard remaining > 0, depth < 8 else { return }
            remaining -= 1
            let role: String? = attribute(el, kAXRoleAttribute)
            if role == kAXStaticTextRole as String, let v: String = attribute(el, kAXValueAttribute) {
                pieces.append(v)
                return
            }
            if let children: [AXUIElement] = attribute(el, kAXChildrenAttribute) {
                for child in children { walk(child, depth: depth + 1) }
            }
        }
        walk(root, depth: 0)
        return pieces.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// For bridged values (String, Int, [AXUIElement]).
    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else { return nil }
        return value as? T
    }

    private static func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func rangeAttribute(_ element: AXUIElement, _ name: String) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(value as! AXValue, .cfRange, &range) ? range : nil
    }

    // MARK: - Context helpers (pure, unit-tested in --unittest)

    static func contextWindow(in full: String, around selection: String, radius: Int) -> String? {
        guard let r = full.range(of: selection) else { return nil }
        let start = full.index(r.lowerBound, offsetBy: -radius, limitedBy: full.startIndex) ?? full.startIndex
        let end = full.index(r.upperBound, offsetBy: radius, limitedBy: full.endIndex) ?? full.endIndex
        let slice = String(full[start..<end])
        let trimmed = trimToParagraphs(slice, selection: selection,
                                       cutStart: start > full.startIndex, cutEnd: end < full.endIndex)
        return cleanContext(trimmed, selection: selection)
    }

    /// If the window was cut mid-paragraph, drop the partial paragraph at that edge
    /// (but never cut into the selection itself).
    static func trimToParagraphs(_ s: String, selection: String, cutStart: Bool, cutEnd: Bool) -> String {
        guard let r = s.range(of: selection) else { return s }
        var lower = s.startIndex, upper = s.endIndex
        if cutStart, let nl = s[s.startIndex..<r.lowerBound].firstIndex(of: "\n") {
            lower = s.index(after: nl)
        }
        if cutEnd, let nl = s[r.upperBound..<s.endIndex].lastIndex(of: "\n") {
            upper = nl
        }
        return String(s[lower..<upper])
    }

    /// Returns nil when the "context" adds nothing beyond the selection.
    static func cleanContext(_ s: String, selection: String) -> String? {
        let c = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard c.count > selection.count + 20 else { return nil }
        return c
    }

    // MARK: - ⌘C fallback

    private static func copyFallback(completion: @escaping (String?) -> Void) {
        let pb = NSPasteboard.general
        let snapshot = PasteboardSnapshot.take(pb)
        let before = pb.changeCount

        syntheticCopyUntil = Date().addingTimeInterval(0.5)
        postCommandC()

        let deadline = Date().addingTimeInterval(0.25)
        func poll() {
            if pb.changeCount != before {
                let isFiles = pb.types?.contains(.fileURL) ?? false
                let text = isFiles ? nil : pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines)
                snapshot.restore(to: pb)
                completion(text?.isEmpty == false ? text : nil)
            } else if Date() < deadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: poll)
            } else {
                completion(nil) // nothing was selected; clipboard untouched
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: poll)
    }

    private static func postCommandC() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let cKey: CGKeyCode = 0x08 // kVK_ANSI_C
        let down = CGEvent(keyboardEventSource: source, virtualKey: cKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: cKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

/// A full copy of the pasteboard (every item, every type) so it can be put back exactly.
struct PasteboardSnapshot {
    private let items: [[(NSPasteboard.PasteboardType, Data)]]

    static func take(_ pb: NSPasteboard) -> PasteboardSnapshot {
        let items = (pb.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        return PasteboardSnapshot(items: items)
    }

    func restore(to pb: NSPasteboard) {
        pb.clearContents()
        let restored = items.map { pairs -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in pairs { item.setData(data, forType: type) }
            return item
        }
        if !restored.isEmpty { pb.writeObjects(restored) }
    }
}
