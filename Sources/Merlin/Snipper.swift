import AppKit

/// "Snip & Ask": the standard macOS region picker (same as ⌘⇧4) for things you can't highlight.
/// Drag a box, or press Space to pick a whole window, or Esc to cancel.
enum Snipper {
    private static var running = false
    private static var quietUntil = Date.distantPast

    /// True while the picker is up, and briefly after, so the selection watcher ignores the drag.
    static var isActive: Bool { running || Date() < quietUntil }

    /// `completion` gets a JPEG of the snipped area (sized for Claude), the full-size PNG, and where the mouse ended up. Not
    /// called on cancel. `finished` is called either way, first, when the picker is gone.
    /// `rect` (screen points, top-left origin) takes that area at once instead of showing the picker (point to ask).
    /// `afterHiding`: a window of Merlin's own (the point-to-ask trail) that must be off the screen before the picture is
    /// taken. The capture starts as soon as the window server no longer lists it, checked every 10 ms for at most 300 ms.
    static func run(rect: CGRect? = nil, afterHiding window: Int? = nil, finished: (() -> Void)? = nil,
                    completion: @escaping (_ jpeg: Data, _ png: Data, _ mouse: NSPoint) -> Void) {
        guard !running else { return }
        if let window {
            running = true // nothing else may start a snip while this one waits
            WindowGate.wait(until: { !WindowGate.isOnScreen(window) }) { waited, timedOut in
                // Kept in the log on purpose: it says whether the trail was still up when the picture was asked for.
                NSLog("Merlin point-to-ask: trail window %d %@ after %.0f ms", window,
                      timedOut ? "STILL ON SCREEN (taking the picture anyway)" : "off screen", waited * 1000)
                running = false
                run(rect: rect, afterHiding: nil, finished: finished, completion: completion)
            }
            return
        }
        let url = ClaudeSession.workingDirectory.appendingPathComponent("snip-\(UUID().uuidString).png")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        if let rect {
            let r = rect.integral
            p.arguments = ["-x", "-R\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(r.height))", url.path] // silent, that area
        } else {
            p.arguments = ["-i", "-x", "-o", url.path] // interactive, silent, no window shadow
        }
        p.terminationHandler = { _ in
            DispatchQueue.main.async {
                running = false
                quietUntil = Date().addingTimeInterval(0.6)
                defer { try? FileManager.default.removeItem(at: url) }
                finished?()
                guard let png = try? Data(contentsOf: url), let jpeg = downscaledJPEG(png) else { return }
                completion(jpeg, png, NSEvent.mouseLocation)
            }
        }
        do {
            try p.run()
            running = true
        } catch {
            running = false
            finished?()
        }
    }

    /// Re-encodes as JPEG, no bigger than Claude will actually look at.
    static func downscaledJPEG(_ data: Data, maxEdge: CGFloat = 1568) -> Data? {
        guard let rep = NSBitmapImageRep(data: data), let image = rep.cgImage else { return nil }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let s = min(1, maxEdge / max(w, h, 1))
        let width = max(1, Int((w * s).rounded())), height = max(1, Int((h * s).rounded()))
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(NSColor.white.cgColor) // transparent corners (window snips) become white, not black
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: scaled).representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }
}

/// Waits for something to become true without blocking the main thread (a blocked main thread couldn't finish hiding the
/// window being waited for). Checks at once, then every `tick`, and gives up at `limit`.
enum WindowGate {
    static let limit: TimeInterval = 0.3
    static let tick: TimeInterval = 0.01

    /// Is this window in the window server's on-screen list right now?
    static func isOnScreen(_ number: Int) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
        return list.contains { ($0[kCGWindowNumber as String] as? Int) == number }
    }

    /// Calls `then` on the main queue with how long it waited and whether it gave up (the condition never came true).
    static func wait(until done: @escaping () -> Bool, limit: TimeInterval = limit, tick: TimeInterval = tick,
                     now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                     then: @escaping (_ waited: TimeInterval, _ timedOut: Bool) -> Void) {
        let start = now()
        func check() {
            if done() { return then(now() - start, false) }
            if now() - start >= limit { return then(now() - start, true) }
            DispatchQueue.main.asyncAfter(deadline: .now() + tick, execute: check)
        }
        check()
    }
}
