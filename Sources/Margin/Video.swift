import AppKit

/// A video (or any audio) to summarize.
enum VideoSource: Equatable {
    case youtube(id: String)
    /// Whatever is playing on the Mac, transcribed live while it plays.
    case listen
    /// A downloaded video or audio file, transcribed on-device.
    case file(URL)

    var link: String? {
        if case .youtube(let id) = self { return "https://youtu.be/\(id)" }
        return nil
    }
}

/// How to write the summary of a non-English video. The user picks each time.
enum SummaryStyle: String, CaseIterable {
    case englishWithPhrases
    case english
    case practice // in the video's own language, for reading practice

    func label(language: String) -> String {
        switch self {
        case .englishWithPhrases: return "English + key \(language) phrases"
        case .english: return "English only"
        case .practice: return "\(language) (practice)"
        }
    }
}

/// A video's words with timestamps, from YouTube's captions or on-device transcription.
struct VideoTranscript {
    struct Segment: Equatable {
        let start: TimeInterval
        let text: String
    }

    var title: String
    var channel: String?
    var duration: TimeInterval?
    /// e.g. "en", "ru".
    var languageCode: String
    /// Where the words came from, for Claude (so it allows for recognition errors).
    var origin: String
    var segments: [Segment]

    var isEnglish: Bool { languageCode.lowercased().hasPrefix("en") }

    var languageName: String {
        let code = String(languageCode.prefix { $0 != "-" && $0 != "_" })
        return Locale(identifier: "en").localizedString(forLanguageCode: code)?.capitalized ?? languageCode
    }

    var wordCount: Int { segments.reduce(0) { $0 + $1.text.split(separator: " ").count } }

    /// "[mm:ss] text" paragraphs, one per ~30 seconds. Very long videos are trimmed at the end.
    func formatted(maxCharacters: Int = 400_000) -> String {
        var lines: [String] = []
        var blockStart: TimeInterval?
        var block: [String] = []
        func flush() {
            if let start = blockStart, !block.isEmpty {
                lines.append("[\(Self.clock(start))] " + block.joined(separator: " "))
            }
            block.removeAll()
        }
        for segment in segments {
            if let start = blockStart, segment.start - start >= 30 {
                flush()
                blockStart = segment.start
            }
            if blockStart == nil { blockStart = segment.start }
            block.append(segment.text)
        }
        flush()
        var out = lines.joined(separator: "\n")
        if out.count > maxCharacters {
            out = String(out.prefix(maxCharacters)) + "\n[…transcript trimmed: the video is very long]"
        }
        return out
    }

    static func clock(_ t: TimeInterval) -> String {
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - YouTube

enum YouTube {
    enum Failure: LocalizedError {
        case unavailable(String)
        case noCaptions

        var errorDescription: String? {
            switch self {
            case .unavailable(let why): return "YouTube didn't return this video (\(why))."
            case .noCaptions: return "This video has no captions to read."
            }
        }
    }

    private static let idPattern = try! NSRegularExpression(
        pattern: #"(?:youtube\.com/(?:watch\?(?:[^\s]*?&)?v=|shorts/|live/|embed/|v/)|youtu\.be/)([A-Za-z0-9_-]{11})"#,
        options: .caseInsensitive)

    /// The video ID in a link (or in any text containing one).
    static func videoID(in text: String) -> String? {
        let ns = text as NSString
        guard let m = idPattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    static func thumbnailURL(_ id: String) -> URL? { URL(string: "https://i.ytimg.com/vi/\(id)/mqdefault.jpg") }

    /// YouTube's app API hands out caption links that work without a browser token (the web page's don't).
    private static let clients: [(name: String, version: String, extra: [String: Any], agent: String)] = [
        ("ANDROID", "20.10.38", ["androidSdkVersion": 34],
         "com.google.android.youtube/20.10.38 (Linux; U; Android 14) gzip"),
        ("IOS", "20.10.4", ["deviceModel": "iPhone16,2"],
         "com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3 like Mac OS X)"),
    ]

    static func transcript(for id: String) async throws -> VideoTranscript {
        var lastError: Error = Failure.noCaptions
        for client in clients {
            do {
                let player = try await playerResponse(id: id, client: client)
                let status = (player["playabilityStatus"] as? [String: Any])?["status"] as? String
                guard status == "OK" else {
                    let reason = (player["playabilityStatus"] as? [String: Any])?["reason"] as? String
                    throw Failure.unavailable(reason ?? status ?? "unknown reason")
                }
                let details = player["videoDetails"] as? [String: Any] ?? [:]
                guard let (track, autoGenerated) = chooseTrack(player),
                      let base = track["baseUrl"] as? String, let url = URL(string: base) else {
                    throw Failure.noCaptions
                }
                let (data, _) = try await URLSession.shared.data(from: url)
                let segments = parseCaptions(String(decoding: data, as: UTF8.self))
                guard !segments.isEmpty else { throw Failure.noCaptions }
                return VideoTranscript(
                    title: details["title"] as? String ?? "YouTube video",
                    channel: details["author"] as? String,
                    duration: (details["lengthSeconds"] as? String).flatMap(TimeInterval.init),
                    languageCode: track["languageCode"] as? String ?? "en",
                    origin: autoGenerated ? "YouTube's auto-generated captions (may have recognition errors)"
                                          : "YouTube's captions",
                    segments: segments)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private static func playerResponse(id: String, client: (name: String, version: String, extra: [String: Any], agent: String)) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(client.agent, forHTTPHeaderField: "User-Agent")
        var ctx: [String: Any] = ["clientName": client.name, "clientVersion": client.version, "hl": "en"]
        ctx.merge(client.extra) { a, _ in a }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["context": ["client": ctx], "videoId": id])
        let (data, _) = try await URLSession.shared.data(for: request)
        // YouTube's JSON can contain raw control characters inside strings; make them plain spaces.
        let cleaned = String(decoding: data, as: UTF8.self).unicodeScalars
            .map { $0.value < 0x20 ? " " : String($0) }.joined()
        guard let obj = try JSONSerialization.jsonObject(with: Data(cleaned.utf8)) as? [String: Any] else {
            throw Failure.unavailable("unreadable response")
        }
        return obj
    }

    /// Prefer captions in the language actually spoken. YouTube's auto-captions are always in the spoken
    /// language, so: human captions in that language, else the auto-captions themselves; with no
    /// auto-captions, the video's default caption track, then English, then anything.
    private static func chooseTrack(_ player: [String: Any]) -> ([String: Any], autoGenerated: Bool)? {
        let renderer = (player["captions"] as? [String: Any])?["playerCaptionsTracklistRenderer"] as? [String: Any]
        let tracks = renderer?["captionTracks"] as? [[String: Any]] ?? []
        guard !tracks.isEmpty else { return nil }
        func isAuto(_ t: [String: Any]) -> Bool { t["kind"] as? String == "asr" }
        func lang(_ t: [String: Any]) -> String { t["languageCode"] as? String ?? "" }

        if let auto = tracks.first(where: isAuto) {
            if let human = tracks.first(where: { !isAuto($0) && lang($0) == lang(auto) }) { return (human, false) }
            return (auto, true)
        }
        if let audio = (renderer?["audioTracks"] as? [[String: Any]])?.first,
           let index = audio["defaultCaptionTrackIndex"] as? Int, tracks.indices.contains(index) {
            return (tracks[index], false)
        }
        return (tracks.first { lang($0).hasPrefix("en") } ?? tracks[0], false)
    }

    /// Handles both YouTube caption formats: `<text start="1.2">` (seconds) and `<p t="1200">` (ms).
    static func parseCaptions(_ xml: String) -> [VideoTranscript.Segment] {
        let patterns: [(String, Double)] = [
            (#"<text[^>]*?start="([\d.]+)"[^>]*>(.*?)</text>"#, 1),
            (#"<p[^>]*?\bt="(\d+)"[^>]*>(.*?)</p>"#, 0.001),
        ]
        let ns = xml as NSString
        for (pattern, scale) in patterns {
            let regex = try! NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators)
            let segments = regex.matches(in: xml, range: NSRange(location: 0, length: ns.length)).compactMap { m -> VideoTranscript.Segment? in
                guard let start = Double(ns.substring(with: m.range(at: 1))) else { return nil }
                let text = decodeEntities(ns.substring(with: m.range(at: 2))
                    .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression))
                    .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
                return text.isEmpty ? nil : VideoTranscript.Segment(start: start * scale, text: text)
            }
            if !segments.isEmpty { return segments }
        }
        return []
    }

    /// HTML entities, decoded twice because YouTube sometimes double-encodes (&amp;#39;).
    static func decodeEntities(_ s: String) -> String {
        var out = s
        for _ in 0..<2 {
            out = out.replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&#39;", with: "'")
                .replacingOccurrences(of: "&nbsp;", with: " ")
            let numeric = try! NSRegularExpression(pattern: "&#(\\d+);")
            let ns = out as NSString
            var result = ""
            var cursor = 0
            for m in numeric.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
                result += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
                if let code = UInt32(ns.substring(with: m.range(at: 1))), let scalar = Unicode.Scalar(code) {
                    result.unicodeScalars.append(scalar)
                }
                cursor = m.range.location + m.range.length
            }
            out = result + ns.substring(from: cursor)
        }
        return out
    }
}

// MARK: - Browser

/// Reads the address of the front tab in common browsers (asks the user once per browser).
enum BrowserTab {
    private static let chromium: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary", "company.thebrowser.Browser",
        "com.brave.Browser", "com.microsoft.edgemac", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
        "org.chromium.Chromium",
    ]
    private static let safari: Set<String> = ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]

    static func isBrowser(_ bundleID: String?) -> Bool {
        guard let id = bundleID else { return false }
        return chromium.contains(id) || safari.contains(id)
    }

    /// Runs on main (AppleScript isn't thread-safe). The first time, macOS asks to allow Margin
    /// to read the browser; after that it's silent.
    static func currentURL(bundleID: String) -> String? { probe(bundleID: bundleID).url }

    /// The front tab's address, and whether macOS refused to let Margin ask (error -1743: not allowed under Automation).
    static func probe(bundleID: String) -> (url: String?, denied: Bool) {
        let source: String
        if safari.contains(bundleID) {
            source = "tell application id \"\(bundleID)\" to return URL of front document"
        } else if chromium.contains(bundleID) {
            source = "tell application id \"\(bundleID)\" to return URL of active tab of front window"
        } else {
            return (nil, false)
        }
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue
        let code = (error?[NSAppleScript.errorNumber] as? NSNumber)?.intValue
        return (result, code == -1743)
    }
}

// MARK: - What the popup shows

struct VideoState: Equatable {
    enum Stage: Equatable {
        case fetching                                        // reading YouTube's transcript
        case chooseLanguage                                  // listen/file: which language is spoken?
        case preparingModel(Double)                          // first use: downloading Apple's speech model
        case listening(elapsed: TimeInterval, caption: String)
        case transcribing(Double)                            // a file, 0…1
        case finishing
        case chooseStyle(language: String)                   // non-English: how to summarize?
        case ready                                           // summary requested; the thread takes over
        case failed(String)
    }

    var icon: String
    var title: String
    var subtitle: String?
    var thumbnail: URL?
    var stage: Stage

    /// Work is happening (keeps the popup from fading, and click-away minimizes instead of closing).
    var isBusy: Bool {
        switch stage {
        case .fetching, .preparingModel, .listening, .transcribing, .finishing: return true
        default: return false
        }
    }
}
