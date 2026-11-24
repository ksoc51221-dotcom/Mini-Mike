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
        func wait(_ cond: () -> Bool) {
            let end = Date().addingTimeInterval(2)
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
        let url = URL(string: "https://i.scdn.co/image/abc")
        let playing = SpotifyTrack(title: "T", artist: "A", artworkURL: url, isPlaying: true)

        let fake = FakeSpotify()
        let svc = SpotifyService(backend: fake, loader: FakeLoader(image: solid(.red)))
        check("spotify: starts notRunning + emerald", svc.state == .notRunning && svc.palette == .emerald && svc.cover == nil)

        fake.result = .track(playing)
        svc.refresh()
        wait { svc.cover != nil }
        check("spotify: playing track maps through the service", svc.state == .track(playing))
        check("spotify: cover loaded and palette changed", svc.cover != nil && svc.palette != .emerald)

        var paused = playing; paused.isPlaying = false
        fake.result = .track(paused)
        svc.refresh()
        wait { svc.state == .track(paused) }
        check("spotify: paused returns emerald", svc.state == .track(paused) && svc.palette == .emerald)

        fake.result = .denied
        svc.refresh()
        wait { svc.state == .denied }
        check("spotify: denied maps and has no cover", svc.state == .denied && svc.cover == nil && svc.palette == .emerald)

        fake.running = false
        svc.refresh()
        wait { svc.state == .notRunning }
        check("spotify: not running -> no cover, emerald", svc.state == .notRunning && svc.cover == nil && svc.palette == .emerald)

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
        let e = DockPalette.emerald
        check("spotify: emerald contrast", DockPalette.contrast(e.ink, e.base) >= 7 && DockPalette.contrast(e.accent, e.base) >= 3)

        // Guards: every kind of cover keeps the ink at 4.5:1 on the tinted dock glass over white and black, the accent at 3:1
        // on the base, and two accents that differ (hue gap or tone gap).
        let white = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1), black = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
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
            let ink = [white, black].map { DockPalette.contrast(p.ink, EdgeGlass.surface(base: p.base, dim: EdgeGlass.dockDim, over: $0)) }.min()!
            let acc = min(DockPalette.contrast(p.accent, p.base), DockPalette.contrast(p.accent2, p.base))
            worstInk = min(worstInk, ink); worstAccent = min(worstAccent, acc)
            if ink < DockPalette.minInkContrast || acc < 3 || !DockPalette.accentsDiffer(p.accent, p.accent2) { failed.append(name) }
        }
        check("spotify: every cover kind keeps ink 4.5:1 (worst \(String(format: "%.2f", worstInk))), accents 3:1 (worst \(String(format: "%.2f", worstAccent))) and two different accents (failed: \(failed))",
              failed.isEmpty)
        let greyP = DockPalette.from(image: EdgeDockFixtures.coverGrey())
        let blueP = DockPalette.from(image: EdgeDockFixtures.coverBlue())
        check("spotify: the grey cover gets a tone gap of \(String(format: "%.2f", DockPalette.contrast(greyP.accent, greyP.accent2))) between its accents",
              DockPalette.contrast(greyP.accent, greyP.accent2) >= DockPalette.minToneContrast)
        check("spotify: the single colour cover gets a hue gap of \(String(format: "%.3f", DockPalette.hueGap(DockPalette.from(image: EdgeDockFixtures.coverSingle()).accent, DockPalette.from(image: EdgeDockFixtures.coverSingle()).accent2))) between its accents",
              DockPalette.hueGap(DockPalette.from(image: EdgeDockFixtures.coverSingle()).accent, DockPalette.from(image: EdgeDockFixtures.coverSingle()).accent2) >= DockPalette.minHueGap)
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
        check("spotify: song A's cover sets its palette", paletteA != .emerald)
        seen = []
        settle(songB, loads: 2)
        check("spotify: while song B's cover loads the palette stays A's", flip.palette == paletteA && !seen.contains(.emerald))
        held.held[1].1(solid(NSColor(srgbRed: 0.1, green: 0.2, blue: 0.9, alpha: 1)))
        let paletteB = flip.palette
        check("spotify: song B's cover then replaces it in one step, never through emerald",
              paletteB != paletteA && paletteB != .emerald && !seen.contains(.emerald) && seen == [paletteB])
        seen = []
        settle(songC, loads: 3)
        held.held[2].1(nil)
        check("spotify: a cover that fails to load keeps the previous palette", flip.palette == paletteB && !seen.contains(.emerald))
        fb.result = .track(SpotifyTrack(title: "C", artist: "x", artworkURL: songC.artworkURL, isPlaying: false))
        flip.refresh()
        wait { flip.palette == .emerald }
        check("spotify: paused returns exactly emerald", flip.palette == .emerald)
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
