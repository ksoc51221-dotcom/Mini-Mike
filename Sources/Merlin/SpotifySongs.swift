import Foundation
import Combine

/// The only track id Merlin keeps or puts into a script: `spotify:track:` and exactly 22 ASCII letters or digits.
/// Checked byte by byte (no regular expression: `$` also matches before a final newline; no `isLetter`: it accepts
/// letters from every script).
enum SpotifyTrackURI {
    static let prefix = "spotify:track:"
    static let idLength = 22

    static func isValid(_ value: String?) -> Bool {
        guard let value else { return false }
        let bytes = Array(value.utf8)
        let head = Array(prefix.utf8)
        guard bytes.count == head.count + idLength, Array(bytes.prefix(head.count)) == head else { return false }
        return bytes.dropFirst(head.count).allSatisfy { b in
            (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
        }
    }
}

/// One song Merlin saw playing.
struct SpotifySong: Codable, Equatable, Identifiable {
    var uri: String
    var name: String
    var artist: String
    var artworkURL: String?
    var lastPlayed: Date
    var starred: Bool
    var id: String { uri }
}

/// "My songs": every song Merlin sees playing in Spotify, once each (by its track URI), newest first. At most `limit`;
/// when full, the oldest song without a star goes first (the oldest of all if every song has a star).
/// Kept as JSON in `folder` (nil: memory only, as in the tests and pictures). The folder is made on the first write only.
final class SpotifySongs: ObservableObject {
    static let limit = 500
    static let fileName = "spotify-songs.json"

    /// The app's own list: Application Support/Merlin, as the app's other files.
    static let shared = SpotifySongs(folder: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Merlin", isDirectory: true))

    @Published private(set) var songs: [SpotifySong] = []
    let folder: URL?
    var fileURL: URL? { folder?.appendingPathComponent(Self.fileName) }
    private let writer = DispatchQueue(label: "merlin.spotify-songs", qos: .utility)

    init(folder: URL?) {
        self.folder = folder
        load()
    }

    /// A missing file is an empty list; a file that can't be read is an empty list too, and stays on disk as
    /// `spotify-songs.json.corrupt` (a copy) so the next save does not lose it. Entries with a bad URI are dropped.
    private func load() {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return }
        guard let list = try? JSONDecoder().decode([SpotifySong].self, from: data) else {
            let copy = url.appendingPathExtension("corrupt")
            if !FileManager.default.fileExists(atPath: copy.path) { try? data.write(to: copy, options: .atomic) }
            return
        }
        var seen = Set<String>()
        songs = list.filter { SpotifyTrackURI.isValid($0.uri) && seen.insert($0.uri).inserted }
        sort()
    }

    private func sort() { songs.sort { $0.lastPlayed > $1.lastPlayed } }

    /// Writes on a background queue, atomically. Only the data and the address cross the queue.
    private func save() {
        guard let folder, let url = fileURL, let data = try? JSONEncoder().encode(songs) else { return }
        writer.async {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Waits for the writes so far (tests).
    func flush() { writer.sync {} }

    func song(_ uri: String?) -> SpotifySong? { songs.first { $0.uri == uri } }
    func isStarred(_ uri: String?) -> Bool { song(uri)?.starred == true }

    /// A song seen playing: added once, or its date moved to `now`. A track without a valid URI is never saved.
    func saw(_ track: SpotifyTrack, now: Date = Date()) {
        guard let uri = track.uri, SpotifyTrackURI.isValid(uri) else { return }
        if let i = songs.firstIndex(where: { $0.uri == uri }) {
            songs[i].lastPlayed = now
            songs[i].name = track.title
            songs[i].artist = track.artist
            if let art = track.artworkURL?.absoluteString { songs[i].artworkURL = art }
        } else {
            songs.append(SpotifySong(uri: uri, name: track.title, artist: track.artist,
                                     artworkURL: track.artworkURL?.absoluteString, lastPlayed: now, starred: false))
        }
        trim(keeping: uri)
        sort()
        save()
    }

    /// The heart: stars or unstars `track` in this list only (it is added first if it is not there yet).
    func toggleStar(_ track: SpotifyTrack, now: Date = Date()) {
        guard let uri = track.uri, SpotifyTrackURI.isValid(uri) else { return }
        if song(uri) == nil {
            songs.append(SpotifySong(uri: uri, name: track.title, artist: track.artist,
                                     artworkURL: track.artworkURL?.absoluteString, lastPlayed: now, starred: true))
            trim(keeping: uri)
            sort()
        } else if let i = songs.firstIndex(where: { $0.uri == uri }) {
            songs[i].starred.toggle()
        }
        save()
    }

    /// Over the limit: the oldest song without a star goes, else the oldest; never `keep` (the song just added).
    private func trim(keeping keep: String) {
        while songs.count > Self.limit {
            let others = songs.indices.filter { songs[$0].uri != keep }
            let pool = others.filter { !songs[$0].starred }
            let candidates = pool.isEmpty ? others : pool
            guard let oldest = candidates.min(by: { songs[$0].lastPlayed < songs[$1].lastPlayed }) else { return }
            songs.remove(at: oldest)
        }
    }

    /// The rows for a query (name or artist, case-insensitive) and the star filter, newest first.
    static func filter(_ songs: [SpotifySong], query: String, starredOnly: Bool) -> [SpotifySong] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return songs.filter { s in
            (!starredOnly || s.starred)
                && (q.isEmpty || s.name.localizedCaseInsensitiveContains(q) || s.artist.localizedCaseInsensitiveContains(q))
        }
        .sorted { $0.lastPlayed > $1.lastPlayed }
    }
}
