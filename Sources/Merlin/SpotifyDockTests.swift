import AppKit

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
