import Foundation

/// Summarizing a video on this Mac. The model here has a small memory, so a long transcript is read in parts: each part is
/// boiled down to short timestamped notes, then the notes (not the transcript) are turned into the final summary. A short
/// video skips the first step. Nothing goes to Claude.
enum VideoDigest {
    /// About 3,000 tokens of transcript per part, which leaves room for the instructions and the notes coming back.
    static let chunkCharacters = 11_000

    /// The transcript as "[mm:ss] …" paragraphs, grouped into parts no longer than `limit` characters (a paragraph is never split).
    static func chunks(_ transcript: VideoTranscript, limit: Int = chunkCharacters) -> [String] {
        var out: [String] = []
        var current = ""
        for line in transcript.formatted().split(separator: "\n", omittingEmptySubsequences: true) {
            let piece = String(line.count > limit ? line.prefix(limit) : line)
            if !current.isEmpty, current.count + piece.count + 1 > limit {
                out.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : "\n") + piece
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    static let notesSystem = """
        You take notes on part of a video transcript. Reply with 5 to 8 terse bullets, each starting with the [mm:ss] where \
        it happens. Keep what matters: the main claims and arguments, steps or instructions, numbers, names, definitions, \
        memorable quotes, and any tools, books, people or studies mentioned. Use only what the transcript says. No intro, no closing line.
        """

    static func notesPrompt(part: Int, of count: Int, chunk: String) -> String {
        "This is part \(part) of \(count) of the transcript.\n\n\(chunk)"
    }

    /// What the model is asked for the final summary: the video's details, the transcript or the notes, then the request.
    static func finalPrompt(transcript: VideoTranscript, link: String?, notes: [String]?, request: String) -> String {
        var head = ["Video: \(transcript.title)"]
        if let channel = transcript.channel { head.append("Channel: \(channel)") }
        if let duration = transcript.duration { head.append("Length: \(VideoTranscript.clock(duration))") }
        if let link { head.append("Link: \(link)") }
        head.append("Transcript source: \(transcript.origin)")
        let body = notes.map { "Notes condensed from the whole transcript, in order (base your answer on these):\n" + $0.joined(separator: "\n\n") }
            ?? "Transcript:\n" + transcript.formatted()
        return head.joined(separator: "\n") + "\n\n" + body + "\n\n" + request
    }

    /// A small model gets links wrong, so it writes plain [m:ss] times and the links are made here, from the time itself.
    static func linkify(_ text: String, link: String) -> String {
        guard let re = try? NSRegularExpression(pattern: #"\[(?:(\d{1,2}):)?(\d{1,2}):(\d{2})\](?!\()"#) else { return text }
        let ns = text as NSString
        var out = text
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            func part(_ i: Int) -> Int { m.range(at: i).location == NSNotFound ? 0 : Int(ns.substring(with: m.range(at: i))) ?? 0 }
            let seconds = part(1) * 3600 + part(2) * 60 + part(3)
            let label = ns.substring(with: m.range)
            guard let r = Range(m.range, in: out) else { continue }
            out.replaceSubrange(r, with: "\(label)(\(link)?t=\(seconds))")
        }
        return out
    }

    /// The transcript cut into passages for finding the parts a follow-up question is about.
    static func index(_ transcript: VideoTranscript) -> DocIndex {
        DocIndex(title: transcript.title, kind: "video transcript", pageCount: nil,
                 passages: DocIndex.passages(from: transcript.formatted(), size: 900), note: nil)
    }

    /// A follow-up with the few transcript passages it's about, found here (no model call).
    static func followUp(_ question: String, index: DocIndex) -> String {
        let found = index.relevant(to: question, limit: 4)
        guard !found.isEmpty else { return question }
        return "Parts of the video's transcript that match this:\n\n" + DocIndex.render(found) + "\n\nQuestion: " + question
    }
}
