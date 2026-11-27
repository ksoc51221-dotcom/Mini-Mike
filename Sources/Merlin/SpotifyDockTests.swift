import AppKit
import Combine
import SwiftUI

private final class FakeSpotify: SpotifyBackend, @unchecked Sendable {
    var running = true
    var result: SpotifyState = .stopped
    var sent: [SpotifyCommand] = []
    var fetches = 0
    func isRunning() -> Bool { running }
    func fetch() -> SpotifyState { fetches += 1; return result }
    func send(_ command: SpotifyCommand) { sent.append(command) }
}

private final class FakeFocus: SpotifyFocusKeeping {
    var calls = 0
    func keepFocus() { calls += 1 }
}

private struct FakeLoader: DockImageLoader {
    var image: NSImage?
    func load(_ url: URL, completion: @escaping (NSImage?) -> Void) { completion(image) }
}

private func solid(_ color: NSColor) -> NSImage {
    let img = NSImage(size: NSSize(width: 40, height: 40))
    img.lockFocus(); color.setFill(); NSRect(x: 0, y: 0, width: 40, height: 40).fill(); img.unlockFocus()
    return img
}

extension FeatureTests {
    @MainActor
    static func spotifyDockChecks(_ check: (String, Bool) -> Void) {
        func wait(_ limit: TimeInterval = 2, _ cond: () -> Bool) {
            let end = Date().addingTimeInterval(limit)
            while !cond() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        }
        // Every script must COMPILE. Compiling sends no event. It needs Spotify's dictionary, so it runs only while
        // Spotify is already open (a test never starts an app). The first poll script used `st`, an AppleScript
        // word, and never compiled: the fakes hid that, and no song ever showed in the real app.
        if LiveSpotifyBackend().isRunning() {
            var sources = [("poll", LiveSpotifyBackend.fetchSource)]
            let commands: [(String, SpotifyCommand)] = [
                ("play/pause", .playPause), ("play", .play), ("pause", .pause), ("next", .next), ("previous", .previous),
                ("stop", .stop), ("play track", .playTrack("spotify:track:5YBxGJYKJ7Se2Uq7S0pVOL")),
            ]
            for (name, command) in commands {
                if let s = LiveSpotifyBackend.source(for: command) { sources.append((name, s)) }
            }
            for (name, source) in sources {
                var error: NSDictionary?
                let ok = NSAppleScript(source: source)?.compileAndReturnError(&error) ?? false
                check("spotify script compiles: \(name)", ok && error == nil)
            }
        } else {
            print("  [skip] spotify script compile checks: Spotify is not open")
        }
        // The mini window controls Spotify in the background: no script may bring it forward or start it.
        let every: [SpotifyCommand] = [.playPause, .play, .pause, .next, .previous, .stop, .playTrack("spotify:track:5YBxGJYKJ7Se2Uq7S0pVOL")]
        let scripts = [LiveSpotifyBackend.fetchSource] + every.compactMap(LiveSpotifyBackend.source(for:))
        check("spotify scripts: none activates, opens a location or launches Spotify (\(scripts.count) scripts)",
              scripts.count == 8 && scripts.allSatisfy { s in
                  let l = s.lowercased()
                  return !l.contains("activate") && !l.contains("open location") && !l.contains("launch") && !l.contains("reopen")
              })

        let url = URL(string: "https://i.scdn.co/image/abc")
        let playing = SpotifyTrack(title: "T", artist: "A", artworkURL: url, isPlaying: true)

        // The focus guard: Spotify comes to the front on `play track`; Merlin gives the front back.
        do {
            typealias G = SpotifyFocusGuard
            let finder: pid_t = 501
            let fromApp = G.Before(front: finder, spotifyWasFront: false)
            check("spotify focus: Spotify jumps in front of another app -> Spotify is hidden and that app gets the front back",
                  G.repair(fromApp, activatedIsSpotify: true) == .giveBack(to: finder))
            check("spotify focus: no app was in front -> Spotify is still hidden",
                  G.repair(G.Before(front: nil, spotifyWasFront: false), activatedIsSpotify: true) == .giveBack(to: nil))
            check("spotify focus: Spotify was already in front -> nothing changes",
                  G.repair(G.Before(front: 7, spotifyWasFront: true), activatedIsSpotify: true) == .none)
            check("spotify focus: another app comes to the front (the user's own click) -> nothing changes",
                  G.repair(fromApp, activatedIsSpotify: false) == .none)
            check("spotify focus: a late second jump is repaired too (at most 3 repairs, the log notes 0.1, 0.5 and 1.5 s)",
                  G.maxRepairs == 3 && G.checkpoints == [0.1, 0.5, 1.5])
            check("spotify focus: the guard listens for 2 s at most", G.window == 2)

            let player = FakeSpotify(), focus = FakeFocus()
            let guarded = SpotifyService(backend: player, loader: FakeLoader(image: nil), focus: focus)
            guarded.play("spotify:track:4uLU6hMCjMI75M1A2tKUQC")
            wait { player.sent.count == 1 }
            check("spotify focus: a saved song arms the guard once and sends one play track",
                  focus.calls == 1 && player.sent == [.playTrack("spotify:track:4uLU6hMCjMI75M1A2tKUQC")])
            for c: SpotifyCommand in [.playPause, .play, .pause, .next, .previous, .stop] { guarded.send(c) }
            wait { player.sent.count == 7 }
            check("spotify focus: play/pause, next, previous and stop never arm it", focus.calls == 1 && player.sent.count == 7)
            guarded.play("not a uri")
            check("spotify focus: a bad URI arms nothing and sends nothing", focus.calls == 1)
            player.running = false
            guarded.play("spotify:track:4uLU6hMCjMI75M1A2tKUQC")
            wait(0.4) { player.sent.count > 7 }
            check("spotify focus: Spotify closed -> the guard arms, and no play track goes out while Spotify is not running",
                  focus.calls == 2 && player.sent.count == 7)
        }

        let fake = FakeSpotify()
        let svc = SpotifyService(backend: fake, loader: FakeLoader(image: solid(.red)))
        check("spotify: starts notRunning + emerald", svc.state == .notRunning && svc.palette == .standard && svc.cover == nil)

        fake.result = .track(playing)
        svc.refresh()
        wait { svc.cover != nil }
        check("spotify: playing track maps through the service", svc.state == .track(playing))
        check("spotify: cover loaded and palette changed", svc.cover != nil && svc.palette != .standard)

        var paused = playing; paused.isPlaying = false
        fake.result = .track(paused)
        svc.refresh()
        wait { svc.state == .track(paused) }
        check("spotify: paused keeps the cover's palette", svc.state == .track(paused) && svc.palette != .standard
              && svc.palette == DockPalette.from(image: solid(.red)))

        fake.result = .denied
        svc.refresh()
        wait { svc.state == .denied }
        check("spotify: denied maps and has no cover", svc.state == .denied && svc.cover == nil && svc.palette == .standard)

        fake.running = false
        svc.refresh()
        wait { svc.state == .notRunning }
        check("spotify: not running -> no cover, emerald", svc.state == .notRunning && svc.cover == nil && svc.palette == .standard)

        fake.running = true
        fake.result = .stopped
        let before = fake.fetches
        svc.send(.next)
        wait { svc.state == .stopped }
        check("spotify: send calls backend then refreshes", fake.sent == [.next] && fake.fetches > before && svc.state == .stopped)

        fake.running = false
        fake.sent = []
        svc.send(.playPause)
        wait { fake.fetches > before + 1 || svc.state == .notRunning }
        check("spotify: service does not send when not running", fake.sent.isEmpty || fake.sent == [])

        // Palette.
        let red = DockPalette.from(image: solid(NSColor(srgbRed: 0.9, green: 0.1, blue: 0.1, alpha: 1)))
        let ra = red.accent.usingColorSpace(.sRGB)!
        check("spotify: red cover gives reddish accent", ra.redComponent > ra.greenComponent && ra.redComponent > ra.blueComponent)
        check("spotify: red palette contrast", DockPalette.contrast(red.ink, red.base) >= 7 && DockPalette.contrast(red.accent, red.base) >= 3)
        let grey = DockPalette.from(image: solid(NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)))
        check("spotify: grey palette contrast", DockPalette.contrast(grey.ink, grey.base) >= 7 && DockPalette.contrast(grey.accent, grey.base) >= 3)
        let e = DockPalette.standard
        check("spotify: emerald contrast", DockPalette.contrast(e.ink, e.base) >= 7 && DockPalette.contrast(e.accent, e.base) >= 3)

        // Guards: every kind of cover keeps the ink at 4.5:1 on the flat path's solid base, the accent at 3:1 on the base,
        // the text on an accent fill at 4.5:1, and two accents that differ (hue gap or tone gap). Text on the glass is not
        // here: the system picks it (hierarchical styles), checked only on a real screen.
        let covers: [(String, NSImage)] = [
            ("bright pastel", EdgeDockFixtures.coverBright()), ("bright yellow", solid(NSColor(srgbRed: 1, green: 1, blue: 0.2, alpha: 1))),
            ("white", solid(.white)), ("dark", EdgeDockFixtures.coverDark()), ("black", solid(.black)),
            ("grey", EdgeDockFixtures.coverGrey()), ("pale grey", solid(NSColor(srgbRed: 0.52, green: 0.5, blue: 0.5, alpha: 1))),
            ("one colour", EdgeDockFixtures.coverSingle()), ("one blue", solid(NSColor(srgbRed: 0.1, green: 0.2, blue: 0.9, alpha: 1))),
            ("blue", EdgeDockFixtures.coverBlue()),
        ]
        var worstInk = CGFloat.infinity, worstAccent = CGFloat.infinity, failed: [String] = []
        for (name, image) in covers {
            let p = DockPalette.from(image: image)
            let ink = DockPalette.contrast(p.ink, p.base)
            let acc = min(DockPalette.contrast(p.accent, p.base), DockPalette.contrast(p.accent2, p.base))
            worstInk = min(worstInk, ink); worstAccent = min(worstAccent, acc)
            if ink < DockPalette.minInkContrast || acc < 3 || !DockPalette.accentsDiffer(p.accent, p.accent2) { failed.append(name) }
        }
        check("spotify: every cover kind keeps flat ink 4.5:1 (worst \(String(format: "%.2f", worstInk))), accents 3:1 (worst \(String(format: "%.2f", worstAccent))) and two different accents (failed: \(failed))",
              failed.isEmpty)
        // Text on an accent fill (play-pause, Done, Add): emerald, every cover kind above, and solid covers at 12 hues x
        // 3 saturations x 3 brightnesses plus greys.
        var fills: [(String, DockPalette)] = [("standard", .standard)] + covers.map { ($0.0, DockPalette.from(image: $0.1)) }
        for h in 0..<12 { for s in [0.3, 0.65, 1.0] { for b in [0.35, 0.7, 1.0] {
            fills.append(("h\(h) s\(s) b\(b)", DockPalette.from(image: solid(NSColor(hue: CGFloat(h) / 12, saturation: CGFloat(s),
                                                                                     brightness: CGFloat(b), alpha: 1)))))
        } } }
        for g in [0.0, 0.25, 0.5, 0.75, 1.0] {
            fills.append(("grey \(g)", DockPalette.from(image: solid(NSColor(srgbRed: g, green: g, blue: g, alpha: 1)))))
        }
        let onAccent = fills.map { ($0.0, DockPalette.contrast($0.1.onAccent, $0.1.accent)) }
        let worstFill = onAccent.min { $0.1 < $1.1 }!
        check("spotify: text on the accent fill keeps 4.5:1 for \(fills.count) palettes (worst \(String(format: "%.2f", worstFill.1)) at \(worstFill.0))",
              worstFill.1 >= DockPalette.minInkContrast)
        check("spotify: text on a fill is black on a light fill, white on a dark one",
              DockPalette.onFill(.white) == NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
              && DockPalette.onFill(NSColor(srgbRed: 0.05, green: 0.1, blue: 0.6, alpha: 1)) == NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        let greyP = DockPalette.from(image: EdgeDockFixtures.coverGrey())
        let blueP = DockPalette.from(image: EdgeDockFixtures.coverBlue())
        check("spotify: the grey cover gets a tone gap of \(String(format: "%.2f", DockPalette.contrast(greyP.accent, greyP.accent2))) between its accents",
              DockPalette.contrast(greyP.accent, greyP.accent2) >= DockPalette.minToneContrast)
        // One accent per cover (2026-11-26): the second colour is a near-grey of the same hue, told apart by tone.
        let single = DockPalette.from(image: EdgeDockFixtures.coverSingle())
        check("spotify: the single colour cover's second colour is a grey told apart by tone (\(String(format: "%.2f", DockPalette.contrast(single.accent, single.accent2))):1)",
              DockPalette.accentsDiffer(single.accent, single.accent2) && DockPalette.contrast(single.accent, single.accent2) >= DockPalette.minToneContrast)
        check("spotify: a blue cover gives a bluish palette, a grey cover a neutral one",
              blueP.base.usingColorSpace(.sRGB)!.blueComponent > blueP.base.usingColorSpace(.sRGB)!.redComponent
              && abs(greyP.base.usingColorSpace(.sRGB)!.redComponent - greyP.base.usingColorSpace(.sRGB)!.blueComponent) < 0.01)

        // No flash between two songs: the shown palette stays until the next cover has loaded, and when it never loads.
        final class HeldLoader: DockImageLoader {
            var held: [(URL, (NSImage?) -> Void)] = []
            func load(_ url: URL, completion: @escaping (NSImage?) -> Void) { held.append((url, completion)) }
        }
        let held = HeldLoader()
        let songA = SpotifyTrack(title: "A", artist: "x", artworkURL: URL(string: "https://i.scdn.co/image/a"), isPlaying: true)
        let songB = SpotifyTrack(title: "B", artist: "x", artworkURL: URL(string: "https://i.scdn.co/image/b"), isPlaying: true)
        let songC = SpotifyTrack(title: "C", artist: "x", artworkURL: URL(string: "https://i.scdn.co/image/c"), isPlaying: true)
        let fb = FakeSpotify()
        let flip = SpotifyService(backend: fb, loader: held)
        var seen: [DockPalette] = []
        let watch = flip.$palette.sink { seen.append($0) }
        func settle(_ track: SpotifyTrack, loads: Int) {
            fb.result = .track(track)
            flip.refresh()
            wait { flip.state == .track(track) && held.held.count == loads }
        }
        settle(songA, loads: 1)
        held.held[0].1(solid(NSColor(srgbRed: 0.9, green: 0.1, blue: 0.1, alpha: 1)))
        let paletteA = flip.palette
        check("spotify: song A's cover sets its palette", paletteA != .standard)
        seen = []
        settle(songB, loads: 2)
        check("spotify: while song B's cover loads the palette stays A's", flip.palette == paletteA && !seen.contains(.standard))
        held.held[1].1(solid(NSColor(srgbRed: 0.1, green: 0.2, blue: 0.9, alpha: 1)))
        let paletteB = flip.palette
        check("spotify: song B's cover then replaces it in one step, never through emerald",
              paletteB != paletteA && paletteB != .standard && !seen.contains(.standard) && seen == [paletteB])
        seen = []
        settle(songC, loads: 3)
        held.held[2].1(nil)
        check("spotify: a cover that fails to load keeps the previous palette", flip.palette == paletteB && !seen.contains(.standard))
        fb.result = .track(SpotifyTrack(title: "C", artist: "x", artworkURL: songC.artworkURL, isPlaying: false))
        flip.refresh()
        wait { flip.state == .track(SpotifyTrack(title: "C", artist: "x", artworkURL: songC.artworkURL, isPlaying: false)) }
        check("spotify: paused keeps the palette shown (no reset)", flip.palette == paletteB)
        fb.running = false
        flip.refresh()
        wait { flip.palette == .standard }
        check("spotify: Spotify closed returns exactly the default palette", flip.palette == .standard)
        watch.cancel()
        check("spotify: the palette crossfade is one 0.4 s token", Motion.edgePalette == Animation.easeInOut(duration: 0.4))

        // Loader and parsing.
        check("spotify: loader accepts spotify https hosts",
              LiveDockImageLoader.isAllowed(URL(string: "https://i.scdn.co/x")!) && LiveDockImageLoader.isAllowed(URL(string: "https://a.spotifycdn.com/x")!))
        check("spotify: loader rejects other host and http",
              !LiveDockImageLoader.isAllowed(URL(string: "https://evil.com/x")!) && !LiveDockImageLoader.isAllowed(URL(string: "https://evilscdn.co/x")!)
              && !LiveDockImageLoader.isAllowed(URL(string: "http://i.scdn.co/x")!))
        let d = LiveSpotifyBackend.delimiter
        check("spotify: parse playing", LiveSpotifyBackend.parse("playing\(d)T\(d)A\(d)https://i.scdn.co/a") ==
              .track(SpotifyTrack(title: "T", artist: "A", artworkURL: URL(string: "https://i.scdn.co/a"), isPlaying: true)))
        check("spotify: parse stopped", LiveSpotifyBackend.parse("stopped") == .stopped)
    }
}
