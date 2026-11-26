import AppKit

/// Records the URLs the songs card would open (never opens one).
private final class FakeURLOpener: URLOpening {
    private(set) var opened: [URL] = []
    func open(_ url: URL) { opened.append(url) }
}

/// "My songs" (B2): the store in a temp folder only, the track URI rule against hostile values, the `play track` script
/// through the fixture backend, the card's model (heart, rows, star filter) and the songs field's keyboard path.
/// No real Apple Event, network, app launch, file or defaults of the user.
extension FeatureTests {
    @MainActor
    static func spotifySongsChecks(_ check: (String, Bool) -> Void) {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("merlin-songs-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: folder) }
        let file = folder.appendingPathComponent(SpotifySongs.fileName)
        let real = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].path
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        func uri(_ n: Int) -> String { "spotify:track:" + String(format: "%022d", n) }
        func track(_ n: Int, _ name: String = "Song", _ artist: String = "Artist", playing: Bool = true) -> SpotifyTrack {
            SpotifyTrack(title: name, artist: artist, artworkURL: nil, isPlaying: playing, uri: uri(n))
        }

        // MARK: Spotify's own search URL (no web API; nothing is opened here)
        func search(_ q: String) -> String? { SpotifySearch.url(for: q)?.absoluteString }
        check("search url: plain text", search("Midnight") == "spotify:search:Midnight")
        check("search url: spaces (trimmed at the ends, %20 inside)", search("  Art House ") == "spotify:search:Art%20House")
        check("search url: quotes", search("\"Hey\" 'you'") == "spotify:search:%22Hey%22%20%27you%27")
        check("search url: & # / : ? are encoded", search("a&b#c/d:e?f") == "spotify:search:a%26b%23c%2Fd%3Ae%3Ff")
        check("search url: unreserved - . _ ~ stay", search("a-b.c_d~e") == "spotify:search:a-b.c_d~e")
        check("search url: non-ASCII as UTF-8 bytes", search("Sigur Rós замок") == "spotify:search:Sigur%20R%C3%B3s%20%D0%B7%D0%B0%D0%BC%D0%BE%D0%BA")
        let long = search(String(repeating: "ab", count: 150))
        check("search url: a 300-character query is cut to 100", long == "spotify:search:" + String(repeating: "ab", count: 50))
        check("search url: an empty or blank query gives none", search("") == nil && search("   \n") == nil)
        check("search url: only unreserved characters and %XX after the prefix",
              search("x <>%\\{}|^`[]@!$()*+,;=") .map { s in
                  s.dropFirst(SpotifySearch.prefix.count).allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-._~%".contains($0)) }
              } == true)
        check("search url: the test run never opens a URL through the live opener", LiveURLOpener.blocked)
        // A paused poll still is a song: title, artist, cover and URI stay (only the waves and the spin stop).
        let paused = LiveSpotifyBackend.parse(["paused", "Art House", "Malcolm Todd", "https://i.scdn.co/image/ab67",
                                               "spotify:track:5YBxGJYKJ7Se2Uq7S0pVOL"].joined(separator: LiveSpotifyBackend.delimiter))
        check("spotify poll: a paused song keeps its title, artist, cover and URI",
              paused == .track(SpotifyTrack(title: "Art House", artist: "Malcolm Todd", artworkURL: URL(string: "https://i.scdn.co/image/ab67"),
                                            isPlaying: false, uri: "spotify:track:5YBxGJYKJ7Se2Uq7S0pVOL")))

        // MARK: Store
        let store = SpotifySongs(folder: folder)
        check("songs: the test store uses a temp folder, never Application Support",
              store.fileURL?.path.hasPrefix(fm.temporaryDirectory.path) == true && !(store.fileURL?.path.hasPrefix(real) ?? true))
        check("songs: a new store starts empty and makes no folder", store.songs.isEmpty && !fm.fileExists(atPath: folder.path))
        store.saw(track(1, "Midnight City", "M83"), now: t0)
        store.flush()
        check("songs: a song seen playing is saved once, with its fields",
              store.songs.count == 1 && store.songs[0] == SpotifySong(uri: uri(1), name: "Midnight City", artist: "M83",
                                                                      artworkURL: nil, lastPlayed: t0, starred: false)
              && fm.fileExists(atPath: file.path))
        store.saw(track(1, "Midnight City", "M83"), now: t0.addingTimeInterval(60))
        store.flush()
        check("songs: seeing it again updates the date, no second copy",
              store.songs.count == 1 && store.songs[0].lastPlayed == t0.addingTimeInterval(60))
        store.toggleStar(track(1))
        store.flush()
        let reloaded = SpotifySongs(folder: folder)
        check("songs: the list (star included) reads back from the JSON file", reloaded.songs == store.songs && reloaded.isStarred(uri(1)))
        store.toggleStar(track(1))
        check("songs: the heart toggles the star off again", !store.isStarred(uri(1)))
        store.toggleStar(track(2, "New"), now: t0)
        check("songs: starring a song not yet saved adds it starred", store.song(uri(2))?.starred == true && store.songs.count == 2)

        // Cap at 500: the oldest song without a star goes first; if every song has a star, the oldest goes.
        let capped = SpotifySongs(folder: nil)
        for n in 0..<SpotifySongs.limit { capped.saw(track(100 + n), now: t0.addingTimeInterval(Double(n))) }
        capped.toggleStar(track(100)) // the oldest, starred
        capped.saw(track(900), now: t0.addingTimeInterval(10_000))
        check("songs: at 500 a new song removes the oldest song without a star",
              capped.songs.count == 500 && capped.song(uri(100)) != nil && capped.song(uri(101)) == nil && capped.song(uri(900)) != nil)
        let allStarred = SpotifySongs(folder: nil)
        for n in 0..<SpotifySongs.limit {
            allStarred.toggleStar(track(2000 + n), now: t0.addingTimeInterval(Double(n)))
        }
        allStarred.saw(track(3000), now: t0.addingTimeInterval(10_000))
        check("songs: when all 500 have a star, the oldest goes (and the new song stays)",
              allStarred.songs.count == 500 && allStarred.song(uri(2000)) == nil && allStarred.song(uri(3000)) != nil)

        // Filter: name or artist, case-insensitive, newest first; the star filter.
        let rows = [SpotifySong(uri: uri(1), name: "Midnight City", artist: "M83", artworkURL: nil, lastPlayed: t0, starred: false),
                    SpotifySong(uri: uri(2), name: "Paper Harbour", artist: "Mira Vale", artworkURL: nil,
                                lastPlayed: t0.addingTimeInterval(5), starred: true),
                    SpotifySong(uri: uri(3), name: "Low Tide", artist: "Someone", artworkURL: nil, lastPlayed: t0, starred: false)]
        check("songs filter: name or artist, case-insensitive, newest first",
              SpotifySongs.filter(rows, query: "MI", starredOnly: false).map(\.uri) == [uri(2), uri(1)])
        check("songs filter: artist only matches", SpotifySongs.filter(rows, query: "m83", starredOnly: false).map(\.uri) == [uri(1)])
        check("songs filter: the star filter keeps starred songs only",
              SpotifySongs.filter(rows, query: "", starredOnly: true).map(\.uri) == [uri(2)]
              && SpotifySongs.filter(rows, query: "city", starredOnly: true).isEmpty)
        check("songs filter: no match gives no rows", SpotifySongs.filter(rows, query: "zzz", starredOnly: false).isEmpty)

        // A corrupt file loads as an empty list and stays on disk (a copy is kept before the next save replaces it).
        let bad = Data("{not json".utf8)
        try? bad.write(to: file, options: .atomic)
        let corrupt = SpotifySongs(folder: folder)
        check("songs: a corrupt file loads as an empty list and is not deleted",
              corrupt.songs.isEmpty && (try? Data(contentsOf: file)) == bad
              && (try? Data(contentsOf: file.appendingPathExtension("corrupt"))) == bad)
        // A file with a hostile URI: that entry is dropped on load.
        let tampered = "[{\"uri\":\"spotify:track:\\\" & (do shell script \\\"id\\\") & \\\"\",\"name\":\"x\",\"artist\":\"y\",\"lastPlayed\":0,\"starred\":true},"
            + "{\"uri\":\"\(uri(7))\",\"name\":\"ok\",\"artist\":\"z\",\"lastPlayed\":0,\"starred\":false}]"
        try? Data(tampered.utf8).write(to: file, options: .atomic)
        check("songs: an entry with a bad URI in the file is dropped on load", SpotifySongs(folder: folder).songs.map(\.uri) == [uri(7)])
        let memory = SpotifySongs(folder: nil)
        memory.saw(track(1))
        memory.flush()
        check("songs: a memory store keeps songs and has no file", memory.songs.count == 1 && memory.fileURL == nil)

        // MARK: The URI rule
        let good = "spotify:track:6GyFP1nfCDB8lbD2bG0Hq9"
        check("songs uri: a real-format track URI passes", SpotifyTrackURI.isValid(good))
        let hostile = [
            "spotify:track:6GyFP1nfCDB8lbD2bG0Hq\"",                 // a quote (right length)
            "spotify:track:6GyFP1nfCDB8lbD2bG0Hq9\n",                // a trailing newline
            "spotify:track:6GyFP1nfCDB8lbD\nbG0Hq9",                 // a newline inside
            "\" & (do shell script \"touch /tmp/merlin-pwn\") & \"", // script injection
            "spotify:track:\" & (do shell script \"id\") & \"",
            "https://open.spotify.com/track/6GyFP1nfCDB8lbD2bG0Hq9", // another scheme
            "file:///etc/passwd",
            "spotify:album:6GyFP1nfCDB8lbD2bG0Hq9",
            "spotify:local:Artist:Album:Title:200",
            "spotify:track:6GyFP1nfCDB8lbD2bG0Hq9A",                 // too long
            "spotify:track:6GyFP1nfCDB8lbD2bG0Hq9" + String(repeating: "A", count: 500),
            "spotify:track:6GyFP1nfCDB8lbD2bG0Hq",                   // too short
            "spotify:track:6GyFP1nfCDB8lbD2bG0H\u{0661}",            // an Arabic digit (same byte length)
            "spotify:track:\u{FF16}GyFP1nfCDB8lbD2bG0Hq",            // a full-width digit
            "SPOTIFY:TRACK:6GyFP1nfCDB8lbD2bG0Hq9",
            " spotify:track:6GyFP1nfCDB8lbD2bG0Hq",
            "",
        ]
        check("songs uri: every hostile value fails the rule", hostile.allSatisfy { !SpotifyTrackURI.isValid($0) })
        check("songs uri: no play script is built for a hostile value",
              hostile.allSatisfy { LiveSpotifyBackend.source(for: .playTrack($0)) == nil })
        let guarded = SpotifySongs(folder: nil)
        for h in hostile {
            guarded.saw(SpotifyTrack(title: "x", artist: "y", artworkURL: nil, isPlaying: true, uri: h))
            guarded.toggleStar(SpotifyTrack(title: "x", artist: "y", artworkURL: nil, isPlaying: true, uri: h))
        }
        check("songs uri: a hostile value is never saved (seen or starred)", guarded.songs.isEmpty)
        let d = LiveSpotifyBackend.delimiter
        check("songs uri: parse keeps a valid spotify url and drops a hostile one",
              LiveSpotifyBackend.parse("playing\(d)T\(d)A\(d)https://i.scdn.co/a\(d)\(good)") ==
                .track(SpotifyTrack(title: "T", artist: "A", artworkURL: URL(string: "https://i.scdn.co/a"), isPlaying: true, uri: good))
              && hostile.allSatisfy {
                  if case .track(let t) = LiveSpotifyBackend.parse("playing\(d)T\(d)A\(d)x\(d)\($0)") { return t.uri == nil }
                  return false
              })
        let hostileBackend = FixtureSpotifyBackend(.track(EdgeDockFixtures.track))
        let hostileService = EdgeDockFixtures.spotify(hostileBackend)
        hostile.forEach { hostileService.play($0) }
        hostileService.send(.playTrack(hostile[3])) // straight to the backend: it builds no script either
        EdgeDockFixtures.waitUntil(0.3) { !hostileBackend.sent.isEmpty }
        check("songs uri: the service sends nothing for a hostile value, and the backend builds no script",
              hostileBackend.sent == [.playTrack(hostile[3])] && hostileBackend.scripts.isEmpty)

        // MARK: The card's model
        let (defaults, name) = EdgeDockFixtures.defaults()
        defer { EdgeDockFixtures.forget(name) }
        let apps = EdgeDockFixtures.appStore(FixtureDockWorkspace(), defaults: defaults)
        let backend = FixtureSpotifyBackend(.track(EdgeDockFixtures.track))
        let music = EdgeDockFixtures.spotify(backend)
        let m = EdgePanelModel(apps: apps, spotify: music, songs: SpotifySongs(folder: nil))
        let opener = FakeURLOpener()
        m.urlOpener = opener
        let current = EdgeDockFixtures.track.uri!
        check("songs card: the song playing is recorded", m.songs.songs.map(\.uri) == [current])
        let firstDate = m.songs.songs.first?.lastPlayed
        music.refresh(); music.refresh()
        EdgeDockFixtures.waitUntil(0.2) { false }
        check("songs card: the poll does not record the same song again", m.songs.songs.first?.lastPlayed == firstDate)
        check("songs card: no query and no filter shows the player", !m.songsListShown)
        check("songs card: the heart is on for a song with a URI, unstarred", m.canStarCurrent && !m.currentStarred)
        m.tapHeart()
        check("songs card: the heart stars the current song in Merlin's list only",
              m.currentStarred && m.songs.isStarred(current) && backend.sent.isEmpty)
        m.tapHeart()
        check("songs card: a second click unstars it", !m.currentStarred && !m.songs.isStarred(current))
        let noURI = EdgePanelModel(apps: apps, spotify: EdgeDockFixtures.spotify(FixtureSpotifyBackend(.track(
            SpotifyTrack(title: "Ad", artist: "", artworkURL: nil, isPlaying: true)))), songs: SpotifySongs(folder: nil))
        noURI.tapHeart()
        check("songs card: a song without a URI: heart off, nothing saved", !noURI.canStarCurrent && noURI.songs.songs.isEmpty)
        let stopped = EdgePanelModel(apps: apps, spotify: EdgeDockFixtures.spotify(FixtureSpotifyBackend(.stopped)),
                                     songs: SpotifySongs(folder: nil))
        check("songs card: no song: heart off", !stopped.canStarCurrent)

        m.songs.saw(track(42, "Paper Harbour", "Mira Vale"))
        m.songsQuery = "harb"
        check("songs card: a query shows the list with the matches", m.songsListShown && m.songsVisible.map(\.uri) == [uri(42)])
        m.tapSong(m.songsVisible[0])
        EdgeDockFixtures.waitUntil { backend.sent.count == 1 }
        check("songs card: a row plays that song with the exact play track script",
              backend.sent == [.playTrack(uri(42))]
              && backend.scripts == ["tell application id \"com.spotify.client\" to play track \"\(uri(42))\""])
        check("songs card: a row click clears the query, so the player shows the new song", m.songsQuery.isEmpty && !m.songsListShown)
        m.songsQuery = "city"
        check("songs card: a query ends the list with the Spotify search row", m.songsSearchRowShown)
        m.submitSongsSearch()
        EdgeDockFixtures.waitUntil { backend.sent.count == 2 }
        check("songs card: Return plays the first result", backend.sent.last == .playTrack(current))
        check("songs card: Return with a match opens no search and clears the query", opener.opened.isEmpty && m.songsQuery.isEmpty)
        m.songsQuery = "zzz"
        m.submitSongsSearch()
        EdgeDockFixtures.waitUntil(0.2) { backend.sent.count > 2 }
        check("songs card: no match: Return plays nothing, opens nothing and says \"Not in your songs yet.\"",
              m.songsVisible.isEmpty && backend.sent.count == 2 && opener.opened.isEmpty
              && m.songsNotice == EdgePanelModel.notInSongs && m.songsQuery == "zzz")
        m.songsQuery = "  Art House  "
        m.searchSpotify()
        check("songs card: only the search row's click opens Spotify's search for the trimmed query, once",
              opener.opened.map(\.absoluteString) == ["spotify:search:Art%20House"] && backend.sent.count == 2)
        m.songsQuery = "   "
        m.submitSongsSearch(); m.searchSpotify()
        check("songs card: a blank query shows no search row and opens nothing", !m.songsSearchRowShown && opener.opened.count == 1)
        m.songsQuery = ""
        m.tapSongsStarFilter()
        check("songs card: the star filter shows starred songs only (none yet)", m.songsListShown && m.songsVisible.isEmpty)
        m.submitSongsSearch()
        check("songs card: the star filter with no query: no search row, Return opens nothing",
              !m.songsSearchRowShown && opener.opened.count == 1)
        m.tapSongsStarFilter()
        check("songs card: the filter toggles off", !m.songsStarredOnly && !m.songsListShown)

        let closedBackend = FixtureSpotifyBackend(.notRunning)
        let closed = EdgePanelModel(apps: apps, spotify: EdgeDockFixtures.spotify(closedBackend), songs: EdgeDockFixtures.songs())
        closed.urlOpener = FakeURLOpener()
        closed.songsQuery = "m"
        closed.tapSong(closed.songsVisible[0])
        closed.submitSongsSearch()
        EdgeDockFixtures.waitUntil(0.3) { !closedBackend.sent.isEmpty }
        check("songs card: Spotify not open: a row sends nothing and says so",
              closedBackend.sent.isEmpty && closedBackend.scripts.isEmpty && closed.songsNotice == "Spotify is not open.")

        // MARK: The keyboard (three fields, one at a time)
        let edge = EdgePanelController(apps: apps, spotify: EdgeDockFixtures.spotify(FixtureSpotifyBackend(.track(EdgeDockFixtures.track))))
        let k = edge.model
        var told: [Bool] = []
        k.onSearchChange = { told.append($0) }
        edge.debugRevealWithoutWindow()
        k.tapSpotify()
        check("songs keys: the card opening does not take the keyboard",
              k.section == .spotify && !k.songsSearchActive && !k.wantsKeyboard && told.isEmpty)
        k.activateSongsSearch()
        check("songs keys: a click on the field takes the keyboard", k.songsSearchActive && k.wantsKeyboard && told == [true])
        k.songsQuery = "mid"
        k.escapeSongsSearch()
        check("songs keys: Esc clears the query and keeps the field", k.songsQuery.isEmpty && k.songsSearchActive && told == [true])
        k.escapeSongsSearch()
        check("songs keys: a second Esc lets go of the keyboard, the card stays",
              !k.songsSearchActive && !k.wantsKeyboard && k.section == .spotify && told == [true, false])
        k.activateSongsSearch()
        let before = told.count
        k.openSearch()
        check("songs keys: the disc's search takes over, the keyboard stays",
              k.searchOpen && !k.songsSearchActive && !k.appsSearchActive && told.count == before)
        k.tapSpotify()
        k.activateSongsSearch()
        check("songs keys: the songs field takes over from the disc's search, the keyboard stays",
              k.songsSearchActive && !k.searchOpen && !k.appsSearchActive && told.count == before)
        k.songsQuery = "x"
        k.tapManageApps()
        check("songs keys: the apps card takes over, the songs query clears, the keyboard stays",
              k.appsSearchActive && !k.songsSearchActive && !k.searchOpen && k.songsQuery.isEmpty && told.count == before)
        k.tapSpotify()
        k.activateSongsSearch()
        k.songsQuery = "mid"
        k.tapSongsStarFilter()
        k.toggle(.spotify)
        check("songs keys: the card closing clears the query and the filter and lets go",
              k.section == nil && k.songsQuery.isEmpty && !k.songsStarredOnly && !k.songsSearchActive && told.last == false)
        k.tapSpotify()
        k.activateSongsSearch()
        k.songsQuery = "mid"
        k.releaseKeyboard()
        check("songs keys: loss of the keyboard clears the query and lets go (the card stays)",
              k.songsQuery.isEmpty && !k.songsSearchActive && k.section == .spotify && told.last == false)
        k.activateSongsSearch()
        k.songsQuery = "mid"
        k.tapApp(FixtureDockWorkspace.sample[0])
        check("songs keys: an app opening clears the query and lets go", k.songsQuery.isEmpty && !k.songsSearchActive && told.last == false)
        edge.debugRevealWithoutWindow()
        k.choose(.spotify)
        k.activateSongsSearch()
        k.songsQuery = "mid"
        check("songs keys: the field is active again before the dock hides",
              k.section == .spotify && k.songsSearchActive && told.last == true)
        edge.hide(leaveZoneFirst: true)
        check("songs keys: the dock hiding clears the query and lets go",
              !edge.isVisible && k.songsQuery.isEmpty && !k.songsSearchActive && told.last == false)
        let panel = EdgePanelWindow()
        let off = !panel.canBecomeKey
        panel.songsSearchOpen = true
        check("songs keys: the window may be key while the songs field is active (and not before)", off && panel.canBecomeKey)
        panel.songsSearchOpen = false
        withExtendedLifetime(edge) {}
    }
}
