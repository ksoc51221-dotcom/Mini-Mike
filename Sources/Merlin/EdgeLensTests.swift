import AppKit
import Metal
import SwiftUI

/// The lens glass, headless: the shape list, the lens profile, the fallback table, the lifetime rule, that this run
/// makes no stream and no lens view, and the shader itself (compiled from source and drawn into an offscreen texture:
/// no window, no stream).
extension FeatureTests {
    @MainActor
    static func edgeLensChecks(_ check: (String, Bool) -> Void) {
        let L = EdgePanelLayout.self
        let w = L.windowSize
        let local = NSRect(origin: .zero, size: w)
        func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.01 }
        func near(_ a: CGPoint, _ b: CGPoint) -> Bool { near(a.x, b.x) && near(a.y, b.y) }
        /// An AppKit point (y up) in the window as y down.
        func down(_ p: NSPoint) -> CGPoint { CGPoint(x: p.x, y: w.height - p.y) }
        func mid(_ r: CGRect) -> CGPoint { CGPoint(x: r.midX, y: r.midY) }

        // The style switch.
        check("lens: MERLIN_EDGE_GLASS=lens picks it (D on the sheet); unset or unknown is the plain glass (E)",
              EdgeGlassStyle.from("lens") == .lens && EdgeGlassStyle.from("LENS") == .lens && EdgeGlassStyle.lens.letter == "D"
                && EdgeGlassStyle.from(nil) == .plain && EdgeGlassStyle.from("odd") == .plain && EdgeGlassStyle.plain.letter == "E"
                && EdgeGlassStyle.from("regular") == .regular && EdgeGlassStyle.lens.isClear && EdgeGlassStyle.plain.isClear)
        check("glass G2: the default style never starts the screen copy",
              !EdgeLensPolicy.mayRun(requested: EdgeGlassStyle.from(nil), shown: true, flat: false, runAllowed: true))
        check("lens: shape kinds from the SwiftUI shapes",
              EdgeLensShape.Kind(Circle()) == .circle && EdgeLensShape.Kind(Capsule()) == .capsule
                && EdgeLensShape.Kind(RoundedRectangle(cornerRadius: L.cardRadius, style: .continuous)) == .roundedRect(L.cardRadius)
                && EdgeLensShape.Kind.capsule.radius(in: CGSize(width: 60, height: 22)) == 11
                && EdgeLensShape.Kind.roundedRect(40).radius(in: CGSize(width: 60, height: 22)) == 11)

        // The shape list against the layout (checked through the AppKit-frame helpers, a second path).
        let cards: [(String, CGSize?)] = [("none", nil), ("chats", L.listSize(rows: 3, newNoteRow: false)),
                                          ("notes", L.listSize(rows: 8, newNoteRow: true)), ("spotify", L.spotifySize),
                                          ("apps", L.appsSize)]
        var shapesOK = true
        for count in 2...8 {
            for (_, card) in cards {
                let s = EdgeLensShapes.resting(items: count, card: card, searchOpen: false, timer: false)
                let disc = L.discFrame(window: local)
                var ok = s.count == 1 + 3 + 2 + (card == nil ? 0 : 1)
                ok = ok && s[0].kind == .circle && near(mid(s[0].rect), down(NSPoint(x: disc.maxX, y: disc.midY)))
                    && near(s[0].rect.width, L.discRadius * 2)
                let dock = L.dockFrame(window: local)
                for b in 0..<3 {
                    let c = L.discButtonCentre(b)
                    ok = ok && s[1 + b].kind == .circle && near(s[1 + b].rect.width, L.plusSize)
                        && near(mid(s[1 + b].rect), down(NSPoint(x: dock.minX + c.x, y: dock.maxY - c.y)))
                }
                for i in 0..<2 {
                    ok = ok && s[4 + i].kind == .circle && near(s[4 + i].rect.width, L.itemSize)
                        && near(mid(s[4 + i].rect), down(L.itemCentre(i, of: count, window: local)))
                }
                if let card {
                    let f = L.listFrame(window: local, card: card), c = s[6]
                    ok = ok && c.kind == .roundedRect(L.cardRadius) && near(c.rect.width, f.width) && near(c.rect.height, f.height)
                        && near(c.rect.minX, f.minX) && near(c.rect.minY, w.height - f.maxY)
                }
                shapesOK = shapesOK && ok
            }
        }
        check("lens: the SDF shapes match EdgePanelLayout for 2 to 8 items and each card", shapesOK)
        let open = EdgeLensShapes.resting(items: 4, card: nil, searchOpen: true, timer: true)
        let o = EdgeLensShapes.dockOrigin
        check("lens: search open: the field's capsule instead of the rim buttons; the timer chip's capsule",
              open.count == 1 + 1 + 1 + 2 && open[1] == EdgeLensShape(kind: .capsule, rect: L.searchFieldFrame.offsetBy(dx: o.x, dy: o.y))
                && open[2] == EdgeLensShape(kind: .capsule, rect: L.timerChipFrame.offsetBy(dx: o.x, dy: o.y)))

        // The profile.
        let P = EdgeLensProfile.self
        var profileOK = true
        for band in [P.band(minHalf: 11), P.band(minHalf: 15), P.band(minHalf: 22), P.band(minHalf: 108)] {
            let m = P.maxShift(band: band)
            profileOK = profileOK && near(P.shift(depth: 0, band: band, maxShift: m), m) && P.shift(depth: band, band: band, maxShift: m) == 0
                && P.shift(depth: band * 3, band: band, maxShift: m) == 0 && m <= EdgeLensPolicy.margin
            var lastShift = CGFloat.infinity, lastDepth = -CGFloat.infinity
            for i in 0...200 {
                let t = band * 1.2 * CGFloat(i) / 200
                let sh = P.shift(depth: t, band: band, maxShift: m), d = P.sampleDepth(t, band: band, maxShift: m)
                profileOK = profileOK && sh <= lastShift && d > lastDepth && sh >= 0 && sh <= m
                lastShift = sh
                lastDepth = d
            }
        }
        check("lens: displacement is the max at the edge, 0 at the band's inner side, monotonic, never folds, within the margin",
              profileOK && P.maxShiftLimit <= EdgeLensPolicy.margin)
        check("lens: the band shrinks for small items (disc and cards 20 pt, Chats about 9, the chip about 5)",
              P.band(minHalf: 108) == 20 && P.band(minHalf: 22) < 10 && P.band(minHalf: 11) < 5 && P.band(minHalf: 1) == P.minBand)

        // The captured rectangle: the window plus the margin, cut to its display; sourceRect is display-local, y down.
        let display = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let win = L.windowFrame(screen: display)
        let cap = EdgeLensPolicy.captureRect(window: win, display: display)
        let second = NSRect(x: 1440, y: -200, width: 1920, height: 1080)
        let cap2 = EdgeLensPolicy.captureRect(window: L.windowFrame(screen: second), display: second)
        check("lens: the capture rect is the window plus the margin, cut at the screen edge; sourceRect is display-local y down",
              cap?.global == win.insetBy(dx: -EdgeLensPolicy.margin, dy: -EdgeLensPolicy.margin).intersection(display) && cap?.global.maxX == display.maxX
                && cap.map { near($0.source.minY, display.maxY - $0.global.maxY) && near($0.source.minX, $0.global.minX) } == true
                && cap2.map { near($0.source.minX, $0.global.minX - second.minX) && near($0.source.minY, second.maxY - $0.global.maxY)
                    && $0.source.maxX <= second.width + 0.01 } == true
                && EdgeLensPolicy.pixelSize(NSRect(x: 0, y: 0, width: 100.4, height: 50), scale: 2) == (201, 100))
        do {
            // 2026-11-27: the compositor load. Half-size frames at 20 a second, and with no card
            // open only the dock's strip is copied.
            let w = NSRect(x: 1000, y: 100, width: 741, height: 641)
            let dock = EdgeLensPolicy.glassRect(window: w, cardOpen: false), all = EdgeLensPolicy.glassRect(window: w, cardOpen: true)
            check("lens: 20 frames a second at half the screen's pixel scale (a sixth of the old pixel rate)",
                  EdgeLensPolicy.framesPerSecond == 20 && EdgeLensPolicy.captureScale == 0.5)
            check("lens: no card open -> only the dock's strip at the right edge is copied, full height (\(dock.width) of \(w.width) pt)",
                  dock.maxX == w.maxX && dock.minY == w.minY && dock.height == w.height
                  && dock.width == EdgePanelLayout.dockSize.width + EdgeLensPolicy.dockGlassPad && dock.width < w.width / 2)
            check("lens: a card open -> the whole window is copied", all == w)
        }
        // Every sample from any edge point of every surface stays in the captured rect (the disc's right half runs past
        // the screen edge: there the clamp holds it in, as the texture's clamp does on the GPU).
        var inside = true
        if let cap {
            for s in EdgeLensShapes.resting(items: 8, card: L.listSize(rows: 8, newNoteRow: true), searchOpen: false, timer: true) {
                let band = P.band(minHalf: min(s.rect.width, s.rect.height) / 2), m = P.maxShift(band: band)
                for k in 0..<64 {
                    let a = CGFloat(k) / 64 * 2 * .pi, n = CGPoint(x: cos(a), y: sin(a))
                    // The edge point on the shape's bounding ellipse (enough for the bound), in screen points (y up).
                    let e = CGPoint(x: s.rect.midX + n.x * s.rect.width / 2, y: s.rect.midY + n.y * s.rect.height / 2)
                    let screen = CGPoint(x: win.minX + e.x + n.x * m, y: win.maxY - e.y - n.y * m)
                    let p = P.clamp(screen, to: cap.global)
                    inside = inside && cap.global.insetBy(dx: -0.001, dy: -0.001).contains(p)
                        && (display.contains(screen) ? (abs(p.x - screen.x) < 0.001 && abs(p.y - screen.y) < 0.001) : true)
                }
            }
        }
        check("lens: no sample leaves the captured rect (on screen: unclamped; past the screen edge: clamped)", cap != nil && inside)

        // The fallback table.
        func d(_ permission: Bool = true, device: Bool = true, shader: String? = nil, window: Bool? = true, stream: String? = nil,
               frames: Int = 0, since: TimeInterval = 0) -> EdgeLensPolicy.Decision {
            EdgeLensPolicy.decide(permission: permission, device: device, shaderError: shader, windowFound: window,
                                  streamError: stream, frames: frames, sinceShow: since)
        }
        check("lens: fallback table",
              d(false, frames: 5) == .fallback(.permission) && d(device: false) == .fallback(.noDevice)
                && d(shader: "x") == .fallback(.shader("x")) && d(window: false) == .fallback(.windowMissing)
                && d(stream: "gone", frames: 9) == .fallback(.stream("gone"))
                && d(window: nil, since: 0.2) == .waiting && d(since: 0.6) == .waiting && d(since: 1.19) == .waiting
                && d(since: 1.2) == .fallback(.noFrames)
                && d(frames: 1, since: 3) == .lens && d(frames: 1) == .lens
                && EdgeLensPolicy.Decision.waiting.drawsLens && !EdgeLensPolicy.Decision.fallback(.noFrames).drawsLens)
        check("lens: fallback reasons read as log text",
              EdgeLensPolicy.Fallback.noFrames.text == "no frame within 1200 ms"
                && EdgeLensPolicy.Fallback.permission.text == "no Screen Recording permission")

        // The lifetime rule.
        let M = EdgeLensPolicy.self
        check("lens: the stream may run only while the lens dock shows, off the flat path, in an allowed run",
              M.mayRun(requested: .lens, shown: true, flat: false, runAllowed: true)
                && !M.mayRun(requested: .lens, shown: false, flat: false, runAllowed: true)
                && !M.mayRun(requested: .lens, shown: true, flat: true, runAllowed: true)
                && !M.mayRun(requested: .lens, shown: true, flat: false, runAllowed: false)
                && EdgeGlassStyle.allCases.filter { $0 != .lens }.allSatisfy { !M.mayRun(requested: $0, shown: true, flat: false, runAllowed: true) })
        check("lens: allowed in a normal launch and --edgeglasscheck; never in --unittest, --uishots, --sidebartest",
              M.runAllowed(["/x/Merlin"]) && M.runAllowed(["/x/Merlin", "--edgeglasscheck", "/tmp/a"])
                && !M.runAllowed(["/x/Merlin", "--unittest"]) && !M.runAllowed(["/x/Merlin", "--uishots", "/tmp/a"])
                && !M.runAllowed(["/x/Merlin", "--sidebartest"]) && !M.allowedHere)
        EdgeLensCapture.shared.sync(requested: .lens, shown: true, window: nil)
        check("lens: this test run starts no stream and makes no lens view (the panel and the picture tests ran first)",
              EdgeLensCapture.streamsStarted == 0 && EdgeLensNSView.made == 0 && EdgeLensCapture.shared.texture == nil
                && !EdgeLensCapture.shared.live)

        // No box: `.primary` ink in the dark scheme (the label colour, not opaque white) on a white backdrop under the
        // card's body (dim 0.2, lift 0.06) and the two glyph shadows right beside a letter (a model: 70% of the near
        // shadow and 60% of the far one reach there; the tool measures the real pixels).
        let body = (1 - EdgeLensProfile.bodyDim) * (1 - 0.06) + 0.06 * (1 - EdgeLensProfile.bodyDim)
        let g = body * (1 - EdgeGlass.lensGlyphShadow.near * 0.7) * (1 - EdgeGlass.lensGlyphShadow.far * 0.6)
        let ground = NSColor(srgbRed: g, green: g, blue: g, alpha: 1)
        var label = NSColor.white
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            label = NSColor.labelColor.usingColorSpace(.sRGB) ?? .white
        }
        let ink = EdgeGlass.over(label.withAlphaComponent(1), label.alphaComponent, ground)
        check(String(format: "lens: body dim and glyph shadows give .primary text 4.5:1 over pure white (model; label alpha %.2f: %.2f:1)",
                     label.alphaComponent, DockPalette.contrast(ink, ground)),
              DockPalette.contrast(ink, ground) >= 4.5)
        check("lens: the uniforms are six float4s (the MSL layout)", MemoryLayout<EdgeLensUniforms>.stride == 96)
        check("lens: cards and the disc bend over 20 pt, controls get the stronger dim, the limit is 1.2 s, full is the default",
              P.band(minHalf: 128) == 20 && P.dim(minHalf: 128) == P.bodyDim && P.dim(minHalf: 15) == P.controlDim
                && EdgeLensPolicy.firstFrameTimeout == 1.2 && !EdgeLensCapture.rimOnly
                && EdgeLensCapture.shared.pictureFade == 0)

        lensInkChecks(check)
        lensShaderChecks(check)
    }

    /// The adaptive ink: the luminance, the smoothing, the hysteresis and the contrast of both inks (models).
    @MainActor
    private static func lensInkChecks(_ check: (String, Bool) -> Void) {
        typealias I = EdgeLensInk
        check("lens ink: hysteresis: dark above 0.55, light again only below 0.42",
              !I.decide(dark: false, luma: 0.5) && I.decide(dark: false, luma: 0.56) && I.decide(dark: true, luma: 0.5)
                && I.decide(dark: true, luma: 0.43) && !I.decide(dark: true, luma: 0.41))
        var flips = 0
        for start in [false, true] {
            var d = start
            for i in 0..<200 {
                let next = I.decide(dark: d, luma: 0.48 + 0.05 * sin(Double(i)))
                if next != d { flips += 1 }
                d = next
            }
        }
        check("lens ink: no flicker while the luminance wavers between the thresholds", flips == 0)
        let s = I.smooth(0, toward: 1, dt: 0.3)
        check("lens ink: smoothing over 0.3 s (63% after 0.3 s, none after 0 s)",
              abs(s - (1 - exp(-1))) < 0.001 && I.smooth(0.2, toward: 1, dt: 0) == 0.2)
        check("lens ink: a white backdrop gives dark ink, black and mid blue give light",
              I.effective(1) > I.toDark && I.effective(0) < I.toLight && I.effective(0.2) < I.toLight)

        // Synthetic BGRA frames.
        func frame(_ w: Int, _ h: Int, _ grey: (Int, Int) -> UInt8) -> [UInt8] {
            var b = [UInt8](repeating: 255, count: w * h * 4)
            for y in 0..<h { for x in 0..<w { let g = grey(x, y), i = (y * w + x) * 4; b[i] = g; b[i + 1] = g; b[i + 2] = g } }
            return b
        }
        func mean(_ b: [UInt8], _ w: Int, _ h: Int, round: Bool = false, region: EdgeLensRegion = .disc) -> Double? {
            b.withUnsafeBytes { I.meanLuminance($0.baseAddress!, width: w, height: h, bytesPerRow: w * 4,
                                                 rect: CGRect(x: 0, y: 0, width: w, height: h), round: round, region: region, step: 2) }
        }
        let white = frame(60, 60) { _, _ in 255 }, black = frame(60, 60) { _, _ in 0 }
        let halves = frame(60, 60) { x, _ in x < 30 ? 255 : 0 }
        let topWhite = frame(60, 60) { _, y in y < 12 ? 255 : 0 }
        let corners = frame(60, 60) { x, y in (x - 30) * (x - 30) + (y - 30) * (y - 30) > 900 ? 255 : 0 }
        check("lens ink: mean luminance on synthetic frames (white 1, black 0, half and half 0.5)",
              abs((mean(white, 60, 60) ?? 0) - 1) < 0.001 && (mean(black, 60, 60) ?? 1) < 0.001
                && abs((mean(halves, 60, 60) ?? 0) - 0.5) < 0.01)
        check("lens ink: the card weights its text rows; a round surface reads inside its circle only",
              (mean(topWhite, 60, 60, region: .card) ?? 0) > (mean(topWhite, 60, 60) ?? 1) + 0.05
                && (mean(corners, 60, 60, round: true) ?? 1) < 0.02 && (mean(corners, 60, 60) ?? 0) > 0.15)

        // The model: with the glyph halo or shadow, dark ink on a white-backdrop body and light ink on a black one.
        var dark = NSColor.black, light = NSColor.white
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance { dark = NSColor.labelColor.usingColorSpace(.sRGB) ?? .black }
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance { light = NSColor.labelColor.usingColorSpace(.sRGB) ?? .white }
        let bright = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1) // white, lifted: white
        let v = (0.0 * 0.94 + 0.06) * (1 - Double(EdgeLensProfile.bodyDim)) // black, lifted, dimmed
        let deep = NSColor(srgbRed: v, green: v, blue: v, alpha: 1)
        let onBright = EdgeGlass.over(dark.withAlphaComponent(1), dark.alphaComponent, bright)
        let onDeep = EdgeGlass.over(light.withAlphaComponent(1), light.alphaComponent, deep)
        check(String(format: "lens ink: dark ink on a white backdrop %.1f:1, light ink on a black backdrop %.1f:1 (model, at least 4.5)",
                     DockPalette.contrast(onBright, bright), DockPalette.contrast(onDeep, deep)),
              DockPalette.contrast(onBright, bright) >= 4.5 && DockPalette.contrast(onDeep, deep) >= 4.5)

        // The store: the first sample of a show sets the ink at once; then smoothing and hysteresis.
        let ink = I.shared
        ink.restart()
        ink.feed(.card, I.effective(1))
        let first = ink.dark[.card] == true
        var t: CFTimeInterval = 100
        ink.tick(now: t)
        for _ in 0..<5 { ink.feed(.card, 0.5); t += 0.2; ink.tick(now: t) } // between the thresholds: stays dark
        let held = ink.dark[.card] == true
        for _ in 0..<10 { ink.feed(.card, I.effective(0)); t += 0.2; ink.tick(now: t) }
        check("lens ink: the store sets the first sample at once, holds between the thresholds, turns light on a dark backdrop",
              first && held && ink.dark[.card] == false)
        ink.restart()
    }

    /// Compiles the shader and draws one rounded rect (100 × 60 pt, radius 15, at 1x) over a picture whose red is x and
    /// whose green and blue are y (so each pixel says where it sampled), into an offscreen texture.
    @MainActor
    private static func lensShaderChecks(_ check: (String, Bool) -> Void) {
        let renderer = EdgeLensRenderer.shared
        let error = renderer.prepare()
        guard let device = renderer.device, let queue = renderer.queue else {
            check("lens: the shader compiles from source (\(error ?? "no Metal device"))", false)
            return
        }
        check("lens: the shader compiles from source at run time", error == nil)
        let cw = 140, ch = 100, vw = 100, vh = 60
        let pd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: cw, height: ch, mipmapped: false)
        guard let picture = device.makeTexture(descriptor: pd) else { return check("lens: picture texture", false) }
        var bytes = [UInt8](repeating: 255, count: cw * ch * 4)
        for y in 0..<ch { for x in 0..<cw {
            let i = (y * cw + x) * 4
            bytes[i] = UInt8(y); bytes[i + 1] = UInt8(y); bytes[i + 2] = UInt8(x) // B, G, R
        } }
        picture.replace(region: MTLRegionMake2D(0, 0, cw, ch), mipmapLevel: 0, withBytes: bytes, bytesPerRow: cw * 4)

        /// `body` false and dim 0: the geometry alone (no frost, colour, lift, dim or inner shadow).
        func render(rimOnly: Bool, picture: MTLTexture?, body: Bool = false, fade: CGFloat = 1) -> [UInt8]? {
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: EdgeLensRenderer.pixelFormat, width: vw, height: vh, mipmapped: false)
            td.usage = [.renderTarget, .shaderRead]
            td.storageMode = device.hasUnifiedMemory ? .shared : .managed
            guard let target = device.makeTexture(descriptor: td), let cb = queue.makeCommandBuffer() else { return nil }
            let u = EdgeLensUniforms.make(kind: .roundedRect(15), size: CGSize(width: vw, height: vh), scale: 1,
                                          offset: CGPoint(x: 20, y: 20), capture: CGSize(width: cw, height: ch),
                                          hasPicture: picture != nil, rimOnly: rimOnly, dim: body ? nil : 0, fade: fade, body: body)
            renderer.encode(cb, target: target, uniforms: u, picture: picture)
            if !device.hasUnifiedMemory, let blit = cb.makeBlitCommandEncoder() { blit.synchronize(resource: target); blit.endEncoding() }
            cb.commit()
            cb.waitUntilCompleted()
            var out = [UInt8](repeating: 0, count: vw * vh * 4)
            target.getBytes(&out, bytesPerRow: vw * 4, from: MTLRegionMake2D(0, 0, vw, vh), mipmapLevel: 0)
            return out
        }
        guard let full = render(rimOnly: false, picture: picture), let rim = render(rimOnly: true, picture: picture),
              let none = render(rimOnly: true, picture: nil), let bodied = render(rimOnly: false, picture: picture, body: true),
              let waiting = render(rimOnly: false, picture: nil, body: true),
              let unfaded = render(rimOnly: false, picture: picture, body: true, fade: 0) else { return check("lens: offscreen render", false) }
        func px(_ b: [UInt8], _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
            let i = (y * vw + x) * 4
            return (Int(b[i + 2]), Int(b[i + 1]), Int(b[i]), Int(b[i + 3]))
        }
        let centre = px(full, 50, 30), lower = px(full, 50, 45), top = px(full, 50, 1), corner = px(full, 0, 0)
        check("lens shader: the centre is sharp and unbent (it samples the same screen point)",
              abs(centre.r - 70) <= 1 && abs(centre.g - 50) <= 1 && centre.a == 255)
        check("lens shader: the picture is the right way up", lower.g > centre.g && abs(lower.g - 65) <= 1)
        check("lens shader: the rim bends (the top edge samples from beyond the edge) with a colour split",
              top.g <= 17 && top.a == 255 && top.b > top.g && abs(top.r - 70) <= 1)
        check("lens shader: alpha 0 outside the shape (the rounded corner)", corner == (0, 0, 0, 0))
        check("lens shader: rim only: the centre is transparent (the real screen shows), the rim still drawn",
              px(rim, 50, 30).a == 0 && px(rim, 50, 1).a == 255 && abs(px(rim, 50, 1).g - top.g) <= 1)
        check("lens shader: no picture and no body: the centre transparent",
              px(none, 50, 30).a == 0 && px(none, 50, 1).a == 0)
        // The body (a 100 × 60 surface counts as a control: dim 0.35).
        let b = px(bodied, 50, 30), wait = px(waiting, 50, 30), dimA = Int((EdgeLensProfile.controlDim * 255).rounded())
        let expectR = (70.0 * 0.94 + 255 * 0.06) * (1 - EdgeLensProfile.controlDim) // the lift, then the dim (red is the saturated channel)
        check("lens shader: the body is opaque over the picture, dimmed and lifted",
              b.a == 255 && b.r < centre.r && Double(b.r) > expectR - 12 && Double(b.r) < expectR + 12)
        check("lens shader: before the first frame: the body dim only (the real screen shows through it)",
              abs(wait.a - dimA) <= 1 && wait.r == 0 && px(unfaded, 50, 30) == wait)
        check("lens shader: the 1 pt rim is brighter at the top-left than at the bottom-right",
              px(waiting, 0, 30).g > px(waiting, 99, 30).g + 40)
        // Drawing used no window and no stream.
        check("lens shader: offscreen only (no lens view, no stream)", EdgeLensNSView.made == 0 && EdgeLensCapture.streamsStarted == 0)
    }
}
