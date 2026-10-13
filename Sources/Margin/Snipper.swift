import AppKit

/// "Snip & Ask": the standard macOS region picker (same as ⌘⇧4) for things you can't highlight.
/// Drag a box, or press Space to pick a whole window, or Esc to cancel.
enum Snipper {
    private static var running = false
    private static var quietUntil = Date.distantPast

    /// True while the picker is up, and briefly after, so the selection watcher ignores the drag.
    static var isActive: Bool { running || Date() < quietUntil }

    /// `completion` gets a JPEG of the snipped area and where the mouse ended up. Not called on cancel.
    static func run(completion: @escaping (_ jpeg: Data, _ mouse: NSPoint) -> Void) {
        guard !running else { return }
        let url = ClaudeSession.workingDirectory.appendingPathComponent("snip-\(UUID().uuidString).png")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-i", "-x", "-o", url.path] // interactive, silent, no window shadow
        p.terminationHandler = { _ in
            DispatchQueue.main.async {
                running = false
                quietUntil = Date().addingTimeInterval(0.6)
                defer { try? FileManager.default.removeItem(at: url) }
                guard let png = try? Data(contentsOf: url), let jpeg = downscaledJPEG(png) else { return }
                completion(jpeg, NSEvent.mouseLocation)
            }
        }
        do {
            try p.run()
            running = true
        } catch {
            running = false
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
