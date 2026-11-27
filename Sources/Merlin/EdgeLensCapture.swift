import AppKit
import CoreMedia
import CoreVideo
import Metal
import ScreenCaptureKit
import os

// The lens glass (`EdgeGlassStyle.lens`): a live picture of what lies under the edge panel, bent at each glass edge by
// a Metal shader (`EdgeLensView.swift`). This file owns the picture: one ScreenCaptureKit stream of the panel's
// rectangle that leaves out only the panel window itself. Privacy: frames stay in memory as Metal textures, only the
// latest one is kept, and nothing is written, logged or sent anywhere.

/// When the stream may run and what the dock draws (pure: the tests check these).
enum EdgeLensPolicy {
    /// Why the lens is not drawn (the dock draws `clearTinted` instead).
    enum Fallback: Equatable {
        case permission, noDevice, shader(String), windowMissing, stream(String), noFrames

        /// The text after `lens: fallback (`.
        var text: String {
            switch self {
            case .permission: return "no Screen Recording permission"
            case .noDevice: return "no Metal device"
            case .shader(let e): return "shader did not compile: \(e)"
            case .windowMissing: return "the panel window is not in the shareable content"
            case .stream(let e): return "stream error: \(e)"
            case .noFrames: return "no frame within \(Int(EdgeLensPolicy.firstFrameTimeout * 1000)) ms"
            }
        }
    }

    /// `waiting`: the lens is drawn without a picture (its rim and band only) until the first frame.
    enum Decision: Equatable {
        case lens, waiting, fallback(Fallback)
        var drawsLens: Bool { if case .fallback = self { return false } else { return true } }
    }

    /// No frame this long after the dock showed: the system glass instead (until frames flow). The first real-screen run
    /// measured 588 ms from show to first frame; until the frame the lens draws its body dim and rim only.
    static let firstFrameTimeout: TimeInterval = 1.2
    /// About 20 frames a second (2026-11-27: 60 raised the compositor's load from about 15-25 % to 28 % with the dock
    /// open: its cost is per frame, not per pixel; Merlin asked for less glass tracking and less load).
    static let framesPerSecond = 20
    /// The stream's pixels per screen pixel: half (a quarter of the pixels; the frost hides the softer picture).
    static let captureScale: CGFloat = 0.5
    /// Room round the dock's own width when no card is open (the hover lift and the rim light).
    static let dockGlassPad: CGFloat = 16

    /// Where the glass is (screen coordinates): the whole panel window while a card is open, else only the dock at the
    /// window's right edge (the rest of the window is empty, so its pixels need no copy).
    static func glassRect(window: NSRect, cardOpen: Bool) -> NSRect {
        guard !cardOpen else { return window }
        let w = min(window.width, EdgePanelLayout.dockSize.width + dockGlassPad)
        return NSRect(x: window.maxX - w, y: window.minY, width: w, height: window.height)
    }
    /// The room round the panel's rectangle for the bend and the frost (at least `EdgeLensProfile.maxShiftLimit`).
    static let margin: CGFloat = 24

    /// The stream runs only in a normal launch and in `--edgeglasscheck` (never in `--unittest`, `--uishots`,
    /// `--sidebartest` or any other tool run).
    static func runAllowed(_ arguments: [String]) -> Bool {
        Migration.isNormalLaunch(arguments) || arguments.contains("--edgeglasscheck")
    }
    static let allowedHere = runAllowed(CommandLine.arguments)

    /// The lifetime rule: only while the dock shows in the `lens` style, off the flat path (Reduce Transparency,
    /// `Motion.still`, no glass), in a run that allows it.
    static func mayRun(requested: EdgeGlassStyle, shown: Bool, flat: Bool, runAllowed: Bool) -> Bool {
        requested == .lens && shown && !flat && runAllowed
    }

    /// The fallback table, first match wins. `windowFound` is nil until the shareable content is read. Frames that
    /// flow switch to the lens even after an earlier time-out.
    static func decide(permission: Bool, device: Bool, shaderError: String?, windowFound: Bool?, streamError: String?,
                       frames: Int, sinceShow: TimeInterval) -> Decision {
        if !permission { return .fallback(.permission) }
        if !device { return .fallback(.noDevice) }
        if let shaderError { return .fallback(.shader(shaderError)) }
        if windowFound == false { return .fallback(.windowMissing) }
        if let streamError { return .fallback(.stream(streamError)) }
        if frames > 0 { return .lens }
        if sinceShow >= firstFrameTimeout { return .fallback(.noFrames) }
        return .waiting
    }

    /// What is captured: the panel window grown by `margin`, cut to its display. `global` is in AppKit screen
    /// coordinates (y up); `source` is ScreenCaptureKit's `sourceRect` (the display's own points, y down from its top).
    static func captureRect(window: NSRect, display: NSRect) -> (global: NSRect, source: CGRect)? {
        let g = window.insetBy(dx: -margin, dy: -margin).intersection(display)
        guard !g.isNull, g.width >= 1, g.height >= 1 else { return nil }
        return (g, CGRect(x: g.minX - display.minX, y: display.maxY - g.maxY, width: g.width, height: g.height))
    }

    /// The stream's size in pixels (`scale`: the display's pixel scale times `captureScale`).
    static func pixelSize(_ rect: NSRect, scale: CGFloat) -> (width: Int, height: Int) {
        (max(1, Int((rect.width * scale).rounded())), max(1, Int((rect.height * scale).rounded())))
    }
}

/// The one capture stream (main thread, except the sample handler on its own queue).
final class EdgeLensCapture: NSObject, ObservableObject, SCStreamOutput, SCStreamDelegate {
    static let shared = EdgeLensCapture()
    static let log = Logger(subsystem: "com.kien.merlin", category: "lens")

    /// Draw the lens (true) or the `clearTinted` system glass (false). Changes only with the decision, never per frame.
    @Published private(set) var live = false
    private(set) var decision: EdgeLensPolicy.Decision = .waiting

    /// The latest frame only (the older one is released as the new one lands).
    private(set) var texture: MTLTexture?
    private var latest: CVMetalTexture?
    /// The same frame's pixels, read (a coarse grid) at most 5 times a second for the ink.
    private var latestPixels: CVPixelBuffer?
    private var inkTimer: Timer?
    private var inkSampledFrame = -1
    /// What `texture` shows (AppKit screen coordinates, points).
    private(set) var captureRect: NSRect = .zero

    /// A fingerprint of the latest frame under `on` (screen points, grown by the bend's `margin`): a 20 x 20 grid of pixels.
    /// Equal fingerprints: the picture under that surface did not change, so it need not redraw (2026-11-27: every frame
    /// redrew all six glass surfaces, 120 Metal frames a second, though the backdrop under most of them was still).
    func fingerprint(under on: NSRect) -> UInt64? {
        guard let pixels = latestPixels, captureRect.width > 0 else { return nil }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels) else { return nil }
        let w = CVPixelBufferGetWidth(pixels), h = CVPixelBufferGetHeight(pixels), row = CVPixelBufferGetBytesPerRow(pixels)
        let k = CGFloat(w) / captureRect.width
        let r = on.insetBy(dx: -EdgeLensPolicy.margin, dy: -EdgeLensPolicy.margin)
        let x0 = (r.minX - captureRect.minX) * k, y0 = (captureRect.maxY - r.maxY) * k
        let n = 20
        var hash: UInt64 = 0xcbf29ce484222325
        for j in 0..<n {
            let y = Int(y0 + (CGFloat(j) + 0.5) * r.height * k / CGFloat(n))
            guard y >= 0, y < h else { continue }
            let line = base.advanced(by: y * row).assumingMemoryBound(to: UInt32.self)
            for i in 0..<n {
                let x = Int(x0 + (CGFloat(i) + 0.5) * r.width * k / CGFloat(n))
                guard x >= 0, x < w else { continue }
                hash = (hash ^ UInt64(line[x])) &* 0x100000001b3
            }
        }
        return hash
    }

    // For the capture tool and the tests.
    private(set) var frames = 0
    /// The display time of the latest frame (`CACurrentMediaTime` seconds).
    private(set) var lastFrameTime: CFTimeInterval = 0
    private(set) var permission = false
    private(set) var startToFirstFrame: TimeInterval?
    private(set) var firstPresentDelay: TimeInterval?
    private var delaySum: TimeInterval = 0
    private var delayCount = 0
    var meanPresentDelay: TimeInterval? { delayCount == 0 ? nil : delaySum / Double(delayCount) }
    /// How many streams this process started (the tests check it stays 0 in a test run).
    private(set) static var streamsStarted = 0
    /// The picture everywhere (default: the body's frost, colour and lift need the captured pixels in the centre; the
    /// measured delay is about 25 ms), or in the rim band only with the real screen in the centre
    /// (`MERLIN_EDGE_LENS_SPLIT=rim`, for a comparison).
    static let rimOnly = ProcessInfo.processInfo.environment["MERLIN_EDGE_LENS_SPLIT"]?.lowercased() == "rim"

    /// When the first frame of this show landed (the picture fades in over `EdgeLensProfile.fadeIn`).
    private var firstFrameAt: CFTimeInterval?
    /// 0 before the first frame, then up to 1 over the fade (1 at once under Reduce Motion).
    var pictureFade: CGFloat {
        guard let t = firstFrameAt else { return 0 }
        if Motion.reduceMotion { return 1 }
        return CGFloat(min(1, max(0, (CACurrentMediaTime() - t) / EdgeLensProfile.fadeIn)))
    }
    /// The panel window and its display as ScreenCaptureKit last listed them: the same window on a later show skips the
    /// listing (most of the show-to-first-frame wait). Nothing is captured while hidden.
    private var listed: (window: CGWindowID, display: CGDirectDisplayID, scWindow: SCWindow, scDisplay: SCDisplay)?

    private struct Key: Equatable { let window: Int; let frame: NSRect; let display: CGDirectDisplayID; var region: NSRect }
    /// What each stream size shows: a frame's pixel size says which rectangle it is (the region changes live, by
    /// `updateConfiguration`, and the old size's frames may still land after it).
    private var rectBySize: [String: NSRect] = [:]
    private var config: SCStreamConfiguration?
    private static func sizeKey(_ w: Int, _ h: Int) -> String { "\(w)x\(h)" }
    private var key: Key?
    private var token: UUID?
    private var stream: SCStream?
    private var shownAt: CFTimeInterval = 0
    private var windowFound: Bool?
    private var streamError: String?
    private var shaderError: String?
    private var hasDevice = false
    private var loggedActive = false
    private var loggedFallback: EdgeLensPolicy.Fallback?
    private var lastRecordedFrame: CFTimeInterval = -1

    private let queue = DispatchQueue(label: "com.kien.merlin.lens", qos: .userInteractive)
    private let lock = NSLock()
    private var cache: CVMetalTextureCache?

    private static let ticksToSeconds: Double = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return Double(tb.numer) / Double(tb.denom) / 1e9
    }()

    // MARK: Lifetime

    /// The controller calls this on show, on hide (after the fade) and when the style changes: starts, keeps, restarts
    /// (another display or rectangle) or stops the stream.
    func sync(requested: EdgeGlassStyle, shown: Bool, window: NSWindow?, cardOpen: Bool = true) {
        guard EdgeLensPolicy.mayRun(requested: requested, shown: shown, flat: EdgeDockArt.flat, runAllowed: EdgeLensPolicy.allowedHere),
              let window, let screen = window.screen ?? NSScreen.main, let display = screen.displayID else { return stop() }
        let k = Key(window: window.windowNumber, frame: window.frame, display: display,
                    region: EdgeLensPolicy.glassRect(window: window.frame, cardOpen: cardOpen))
        if k == key, token != nil { return }
        // Only the region changed (a card opened or closed): the running stream copies the new rectangle.
        if var old = key, token != nil, stream != nil, let config, old.window == k.window, old.frame == k.frame,
           old.display == k.display {
            old.region = k.region
            if old == k, retarget(region: k.region, screen: screen, config: config, window: window, display: display, key: k) {
                key = k
                return
            }
        }
        stop()
        start(window: window, screen: screen, display: display, key: k)
    }

    /// Points the running stream at a new region. False: no stream or no rectangle (the caller restarts).
    private func retarget(region: NSRect, screen: NSScreen, config: SCStreamConfiguration, window: NSWindow,
                          display: CGDirectDisplayID, key k: Key) -> Bool {
        guard let s = stream, let rect = EdgeLensPolicy.captureRect(window: region, display: screen.frame) else { return false }
        let size = EdgeLensPolicy.pixelSize(rect.global, scale: screen.backingScaleFactor * EdgeLensPolicy.captureScale)
        rectBySize[Self.sizeKey(size.width, size.height)] = rect.global
        config.sourceRect = rect.source
        config.width = size.width
        config.height = size.height
        let token = self.token
        Task { @MainActor [weak self] in
            do { try await s.updateConfiguration(config) } catch {
                guard let self, self.token == token else { return }
                self.stop() // the next sync starts afresh
            }
        }
        // A shrink (a card closed): the wide picture still covers the dock, so it stays until a new frame lands.
        if captureRect.contains(rect.global) { return true }
        // A widen: a still backdrop may send no new frame; none of the new size soon -> restart on the new region.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self, weak window] in
            guard let self, let window, self.token == token, self.key == k, self.captureRect != rect.global else { return }
            self.stop()
            self.start(window: window, screen: screen, display: display, key: k)
        }
        return true
    }

    private func start(window: NSWindow, screen: NSScreen, display: CGDirectDisplayID, key k: Key) {
        key = k
        let token = UUID()
        self.token = token
        shownAt = CACurrentMediaTime()
        frames = 0
        firstFrameAt = nil
        windowFound = nil
        streamError = nil
        startToFirstFrame = nil
        firstPresentDelay = nil
        delaySum = 0
        delayCount = 0
        loggedActive = false
        loggedFallback = nil
        // Never prompts: the dock only reads the permission (a later settings button may ask for it).
        permission = CGPreflightScreenCaptureAccess()
        let renderer = EdgeLensRenderer.shared
        shaderError = renderer.prepare()
        hasDevice = renderer.device != nil
        evaluate()
        guard decision.drawsLens, let device = renderer.device,
              let rect = EdgeLensPolicy.captureRect(window: k.region, display: screen.frame) else { return }
        captureRect = rect.global
        // The views kept from the last show drop its picture now, and follow the slide-in (an ancestor moves them, which
        // they do not hear about) until the first frames land.
        EdgeLensRenderer.shared.redrawAll()
        // The ink: a new show measures afresh; then 5 times a second (a new frame is sampled, the smoothing steps on).
        EdgeLensInk.shared.restart()
        inkSampledFrame = -1
        let ink = Timer(timeInterval: EdgeLensInk.period, repeats: true) { [weak self] _ in
            guard let self, self.token == token else { return }
            if let pixels = self.latestPixels, self.frames != self.inkSampledFrame {
                self.inkSampledFrame = self.frames
                EdgeLensRenderer.shared.sampleInk(pixels, capture: self.captureRect)
            }
            EdgeLensInk.shared.tick()
        }
        RunLoop.main.add(ink, forMode: .common)
        inkTimer = ink
        for delay in [0.15, 0.3, 0.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard self?.token == token else { return }
                EdgeLensRenderer.shared.redrawAll()
            }
        }
        if cache == nil {
            var c: CVMetalTextureCache?
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &c)
            lock.lock(); cache = c; lock.unlock()
        }
        let size = EdgeLensPolicy.pixelSize(rect.global, scale: screen.backingScaleFactor * EdgeLensPolicy.captureScale)
        rectBySize = [Self.sizeKey(size.width, size.height): rect.global]
        let windowID = CGWindowID(window.windowNumber)
        DispatchQueue.main.asyncAfter(deadline: .now() + EdgeLensPolicy.firstFrameTimeout + 0.01) { [weak self] in
            guard let self, self.token == token else { return }
            self.evaluate()
        }
        Task { @MainActor [weak self] in
            do {
                let scDisplay: SCDisplay, own: SCWindow
                if let l = self?.listed, l.window == windowID, l.display == display {
                    (scDisplay, own) = (l.scDisplay, l.scWindow)
                } else {
                    // Read only after the permission check above (this call may itself raise the system prompt).
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                    guard let self, self.token == token else { return }
                    guard let d = content.displays.first(where: { $0.displayID == display }),
                          let w = content.windows.first(where: { $0.windowID == windowID }) else {
                        // Never an unfiltered stream: the lens would see itself.
                        self.windowFound = false
                        return self.evaluate()
                    }
                    (scDisplay, own) = (d, w)
                    self.listed = (windowID, display, w, d)
                }
                guard let self, self.token == token else { return }
                self.windowFound = true
                // The whole display minus the panel window only: other Merlin windows (and the tool's backdrop) stay.
                let filter = SCContentFilter(display: scDisplay, excludingWindows: [own])
                let config = SCStreamConfiguration()
                config.sourceRect = rect.source
                config.width = size.width
                config.height = size.height
                config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(EdgeLensPolicy.framesPerSecond))
                config.showsCursor = false
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.colorSpaceName = CGColorSpace.sRGB
                config.queueDepth = 3
                self.config = config
                let s = SCStream(filter: filter, configuration: config, delegate: self)
                try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
                self.stream = s
                Self.streamsStarted += 1
                try await s.startCapture()
                if self.token != token { try? await s.stopCapture() } // hidden while it started
            } catch {
                guard let self, self.token == token else { return }
                self.listed = nil // list afresh next time
                self.streamError = error.localizedDescription
                self.evaluate()
            }
        }
    }

    /// Stops the stream and drops the picture. `live` stays as it was, so a fading dock keeps its look.
    func stop() {
        token = nil
        key = nil
        config = nil
        if let s = stream {
            stream = nil
            Task { try? await s.stopCapture() }
        }
        latest = nil
        latestPixels = nil
        texture = nil
        inkTimer?.invalidate()
        inkTimer = nil
        lock.lock()
        if let cache { CVMetalTextureCacheFlush(cache, 0) }
        lock.unlock()
        EdgeLensRenderer.shared.redrawAll() // a view still on screen lets go of the old picture
    }

    private func evaluate() {
        let d = EdgeLensPolicy.decide(permission: permission, device: hasDevice, shaderError: shaderError, windowFound: windowFound,
                                      streamError: streamError, frames: frames, sinceShow: CACurrentMediaTime() - shownAt)
        decision = d
        if live != d.drawsLens { live = d.drawsLens }
        switch d {
        case .fallback(let reason) where loggedFallback != reason:
            loggedFallback = reason
            Self.log.notice("lens: fallback (\(reason.text, privacy: .public))")
        case .lens where !loggedActive:
            loggedActive = true
            let w = texture?.width ?? 0, h = texture?.height ?? 0
            Self.log.notice("lens: active (\(w, privacy: .public)x\(h, privacy: .public) px, \(EdgeLensPolicy.framesPerSecond, privacy: .public) fps)")
        default:
            break
        }
    }

    // MARK: Frames

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let infos = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = infos.first, let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pixels = sampleBuffer.imageBuffer else { return } // idle frames (nothing changed) carry no picture
        let ticks = (info[.displayTime] as? UInt64) ?? mach_absolute_time()
        let time = Double(ticks) * Self.ticksToSeconds
        lock.lock()
        let cache = self.cache
        lock.unlock()
        guard let cache else { return }
        var made: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pixels, nil, .bgra8Unorm,
                                                  CVPixelBufferGetWidth(pixels), CVPixelBufferGetHeight(pixels), 0, &made)
        guard let made else { return }
        let sizeKey = Self.sizeKey(CVPixelBufferGetWidth(pixels), CVPixelBufferGetHeight(pixels))
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stream === stream, self.token != nil else { return }
            // The rectangle this frame shows (it changes when a card opens or closes).
            guard let shows = self.rectBySize[sizeKey] else { return }
            self.captureRect = shows
            DockPerf.tick("lensFrame")
            self.latest = made
            self.latestPixels = pixels
            self.texture = CVMetalTextureGetTexture(made)
            self.frames += 1
            self.lastFrameTime = time
            if self.startToFirstFrame == nil {
                self.startToFirstFrame = CACurrentMediaTime() - self.shownAt
                self.firstFrameAt = CACurrentMediaTime()
                // The fade-in: a redraw each 60th of a second until it is done (a static backdrop sends no more frames).
                let token = self.token
                for i in 1...Int(EdgeLensProfile.fadeIn * 60) + 1 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) / 60) { [weak self] in
                        guard self?.token == token else { return }
                        EdgeLensRenderer.shared.redrawAll()
                    }
                }
            }
            self.evaluate()
            EdgeLensRenderer.shared.frameArrived(time)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stream === stream else { return }
            self.streamError = error.localizedDescription
            self.stream = nil
            self.latest = nil
            self.latestPixels = nil
            self.texture = nil
            self.evaluate()
        }
    }

    /// From the first lens view that showed a frame: the delay from the frame's display time to its presentation.
    func recordPresented(frame: CFTimeInterval, at presented: CFTimeInterval) {
        guard presented > 0, frame != lastRecordedFrame else { return }
        lastRecordedFrame = frame
        let d = max(0, presented - frame)
        if firstPresentDelay == nil { firstPresentDelay = d }
        delaySum += d
        delayCount += 1
    }
}
