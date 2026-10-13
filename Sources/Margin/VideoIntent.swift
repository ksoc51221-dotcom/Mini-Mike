import AppKit

/// "Summarize this video" typed in a chat, spoken, or typed in the agent box: understood here, on this Mac, by rules (no
/// Claude call), and handed to the video summarizer that the menu's Summarize Video also uses.
enum VideoIntent: Equatable {
    /// A YouTube video: the one in the words (a pasted link), or, with nil, the one in the front browser tab.
    case youtube(id: String?)
    /// Whatever is playing on this Mac, summarized as it's heard (the menu's Listen Along).
    case listenAlong

    // MARK: Reading the words

    private static func has(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static let action = #"(?:summari[sz]e|summari[sz]ing|summary|summarise|tl;?\s?dr|recap|sum (?:it |this |that )?up|break (?:it |this )?down|key points|main points|the gist|give me the (?:gist|highlights)|notes (?:on|from|for)|what(?:'s| is| was)(?: this| the| that)?(?: \w+){0,2} about|what does (?:it|this|the \w+) say)"#
    private static let videoNoun = #"(?:video|youtube|clip|lecture|tutorial|talk|vlog|documentary|interview|episode|stream|livestream|youtube tab)"#
    private static let demonstrative = #"(?:this|the|that|current|open|front|my)"#

    /// nil when the words aren't about a video.
    static func parse(_ raw: String) -> VideoIntent? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // Whatever is playing (anything that isn't a YouTube tab).
        if has(#"\blisten[- ]along\b"#, text)
            || has(action + #".*\b(?:what(?:'s| is) playing|what i(?:'m| am) (?:watching|listening to)|what you (?:can )?hear|the (?:audio|sound))\b"#, text)
            || has(action + #".*\b\#(demonstrative) (?:podcast|audio|call|meeting|recording|webinar|zoom|song|broadcast|show|presentation|class)\b"#, text)
            || has(#"\blisten to (?:this|the|that) (?:video|podcast|audio|call|meeting|stream|recording)\b"#, text) {
            return .listenAlong
        }

        // A pasted YouTube link: a summary if the words ask for one, or if the link is all there is.
        if let id = YouTube.videoID(in: text) {
            let withoutLink = text.replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if has(action, text) || withoutLink.isEmpty || has(#"\b(?:watch|explain|transcribe|what happens in)\b"#, text) {
                return .youtube(id: id)
            }
            return nil
        }

        // "this video", "the youtube video", "the lecture I'm watching".
        if has(action + #".*\b\#(demonstrative) (?:\w+ ){0,2}\#(videoNoun)\b"#, text)
            || has(action + #".*\b(?:video|youtube)\b.*\b(?:tab|open|watching|playing|front)\b"#, text)
            || has(#"\b(?:youtube|video)\b.*\b(?:summar|recap|tl;?dr)"#, text)
            || has(#"\bwhat(?:'s| is| was)\s+\#(demonstrative)\s+(?:\w+\s+){0,2}\#(videoNoun)\s+(?:about|saying)\b"#, text) {
            return .youtube(id: nil)
        }
        return nil
    }

    // MARK: Finding the video

    enum Found: Equatable {
        case video(String)
        /// The front window isn't a browser Margin can read.
        case noBrowser
        /// It is a browser, but the front tab isn't a YouTube video.
        case notAVideo
        /// macOS hasn't let Margin read that browser (Settings → Privacy & Security → Automation).
        case needsPermission(String)
    }

    /// The YouTube video in the front browser tab. `alsoTry` is a browser the chat was opened from, in case the front app
    /// isn't one. Runs on the main thread (it uses AppleScript).
    static func locate(alsoTry bundleID: String? = nil) -> Found {
        var candidates: [(bundleID: String, pid: pid_t)] = []
        if let front = NSWorkspace.shared.frontmostApplication, let id = front.bundleIdentifier, BrowserTab.isBrowser(id) {
            candidates.append((id, front.processIdentifier))
        }
        if let id = bundleID, BrowserTab.isBrowser(id), !candidates.contains(where: { $0.bundleID == id }),
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
            candidates.append((id, app.processIdentifier))
        }
        var sawBrowser = false
        for c in candidates {
            sawBrowser = true
            let probe = BrowserTab.probe(bundleID: c.bundleID)
            if let url = probe.url, let id = YouTube.videoID(in: url) { return .video(id) }
            if probe.denied { return .needsPermission(NSRunningApplication(processIdentifier: c.pid)?.localizedName ?? "your browser") }
            // Not scriptable (or no URL): the window's own document address, if the browser shares it.
            if let doc = PageReader.documentURL(pid: c.pid), let id = YouTube.videoID(in: doc.absoluteString) { return .video(id) }
        }
        // A browser that isn't Safari or Chrome-like (Firefox): read its front window's address through accessibility.
        if !sawBrowser, let front = NSWorkspace.shared.frontmostApplication,
           let doc = PageReader.documentURL(pid: front.processIdentifier), doc.scheme?.hasPrefix("http") == true {
            if let id = YouTube.videoID(in: doc.absoluteString) { return .video(id) }
            return .notAVideo
        }
        return sawBrowser ? .notAVideo : .noBrowser
    }

    /// What to tell the person when no video was found.
    static func explain(_ found: Found) -> String {
        switch found {
        case .video: return ""
        case .noBrowser:
            return "I couldn't see a video. Open the YouTube video in Safari or Chrome (as the front window) and ask again, or say “listen along” and I'll summarize whatever is playing."
        case .notAVideo:
            return "The front tab isn't a YouTube video. Open the video and ask again, or say “listen along” and I'll summarize whatever is playing."
        case .needsPermission(let browser):
            return "Margin needs your OK to read \(browser)'s address bar. Allow it under System Settings → Privacy & Security → Automation, then ask again."
        }
    }
}
