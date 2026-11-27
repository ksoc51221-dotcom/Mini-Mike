import AppKit
import CoreVideo
import Metal
import QuartzCore
import SwiftUI

// The lens glass's drawing: one small Metal view under each glass surface (the disc, Chats and Notes, the three rim
// buttons, the timer chip, the cards, the search fields), never hit-testable. The shader is compiled from source at run
// time (`makeLibrary(source:)`: SwiftPM builds no .metal files and this Mac has no Metal compiler).

/// One glass surface as a signed-distance shape.
struct EdgeLensShape: Equatable {
    enum Kind: Equatable {
        case circle
        case roundedRect(CGFloat)
        case capsule

        init<S: Shape>(_ shape: S) {
            if let r = shape as? RoundedRectangle { self = .roundedRect(r.cornerSize.width) }
            else if shape is Capsule { self = .capsule }
            else { self = .circle }
        }

        /// The corner radius in a `size` frame (a circle: half the short side).
        func radius(in size: CGSize) -> CGFloat {
            let half = min(size.width, size.height) / 2
            switch self {
            case .circle, .capsule: return half
            case .roundedRect(let r): return min(r, half)
            }
        }
    }

    let kind: Kind
    /// In the panel window's coordinates (points, y down from its top-left).
    let rect: CGRect
}

/// Where the glass surfaces are when nothing moves, from `EdgePanelLayout` (the tests check it against the layout).
enum EdgeLensShapes {
    /// The dock's top-left in the window (y down).
    static var dockOrigin: CGPoint {
        let w = EdgePanelLayout.windowSize, d = EdgePanelLayout.dockSize
        return CGPoint(x: w.width - d.width, y: w.height / 2 - d.height / 2)
    }

    /// `items` ring items (Chats and Notes are glass; pinned apps are bare icons), the three rim buttons (not while the
    /// disc's search is open; its field then), the timer chip when one runs, and the card when one is open.
    static func resting(items: Int, card: CGSize?, searchOpen: Bool, timer: Bool) -> [EdgeLensShape] {
        let L = EdgePanelLayout.self, w = L.windowSize, o = dockOrigin
        func moved(_ r: CGRect) -> CGRect { r.offsetBy(dx: o.x, dy: o.y) }
        func circle(_ c: CGPoint, _ d: CGFloat) -> EdgeLensShape {
            EdgeLensShape(kind: .circle, rect: CGRect(x: o.x + c.x - d / 2, y: o.y + c.y - d / 2, width: d, height: d))
        }
        let r = L.discRadius
        var out = [EdgeLensShape(kind: .circle, rect: CGRect(x: w.width - r, y: w.height / 2 - r, width: r * 2, height: r * 2))]
        if searchOpen {
            out.append(EdgeLensShape(kind: .capsule, rect: moved(L.searchFieldFrame)))
        } else {
            out += (0..<3).map { circle(L.discButtonCentre($0), L.plusSize) }
        }
        if timer { out.append(EdgeLensShape(kind: .capsule, rect: moved(L.timerChipFrame))) }
        out += L.itemCentres(count: items).prefix(2).map { circle($0, L.itemSize) }
        if let card {
            out.append(EdgeLensShape(kind: .roundedRect(L.cardRadius),
                                     rect: CGRect(x: w.width - L.listInset - card.width, y: w.height / 2 - card.height / 2,
                                                  width: card.width, height: card.height)))
        }
        return out
    }
}

/// The lens profile, the same numbers as the shader (the tests check these; the GPU test checks the shader).
enum EdgeLensProfile {
    /// The rim band at most (big surfaces) and at least (the chip).
    static let maxBand: CGFloat = 20
    static let minBand: CGFloat = 3
    /// The largest displacement, as a share of the band.
    static let shiftShare: CGFloat = 0.85
    /// The frost: the blur ring's radius in points (2.5 px at 2x).
    static let frost: CGFloat = 1.25
    /// The largest displacement anywhere plus the frost (`maxBand * shiftShare + frost`); the capture margin covers it.
    static var maxShiftLimit: CGFloat { maxBand * shiftShare + frost }
    /// The colour split: red moves this much more, blue this much less, at the top and bottom edges.
    static let fringe: CGFloat = 0.16
    /// The body's dim: the disc and the cards, and the small controls that are their own shapes (search fields, round
    /// buttons, the rim buttons, the timer chip), a little stronger.
    static let bodyDim: CGFloat = 0.2
    static let controlDim: CGFloat = 0.35
    /// How much of the theme's accent washes the glass body (the rim fringe takes it in full).
    static let tintStrength: CGFloat = 0.14
    /// The picture's fade-in after the first frame.
    static let fadeIn: TimeInterval = 0.15

    /// The band for a surface whose short side is `2 * minHalf` (cards and the disc 20 pt, scaled down for small items).
    static func band(minHalf: CGFloat) -> CGFloat { min(maxBand, max(minBand, minHalf * 0.42)) }
    /// A control (short side under 80 pt) gets the stronger dim.
    static func dim(minHalf: CGFloat) -> CGFloat { minHalf < 40 ? controlDim : bodyDim }
    static func maxShift(band: CGFloat) -> CGFloat { band * shiftShare }

    /// How far outward the sample moves at depth `t` inside the edge: `maxShift` at the edge, 0 at the band's inner side
    /// and beyond, falling smoothly ((1 - x)², flat where it meets the centre).
    static func shift(depth t: CGFloat, band: CGFloat, maxShift: CGFloat) -> CGFloat {
        let x = min(max(t / band, 0), 1)
        return maxShift * (1 - x) * (1 - x)
    }

    /// The sample's depth inside the edge (negative: beyond the edge). Increases with `t` (no fold), equals `t` from
    /// the band's inner side on.
    static func sampleDepth(_ t: CGFloat, band: CGFloat, maxShift: CGFloat) -> CGFloat {
        t - shift(depth: t, band: band, maxShift: maxShift)
    }

    /// A sample point kept inside the captured rectangle (the texture's clamp does the same on the GPU).
    static func clamp(_ p: CGPoint, to capture: CGRect) -> CGPoint {
        CGPoint(x: min(max(p.x, capture.minX), capture.maxX), y: min(max(p.y, capture.minY), capture.maxY))
    }
}

/// The shader's uniforms: six float4s, the same layout in Swift and MSL.
struct EdgeLensUniforms {
    /// (width pt, height pt, pixel scale, kind: 0 circle, 1 rounded rect)
    var a: SIMD4<Float>
    /// (corner radius, band, max shift, has picture)
    var b: SIMD4<Float>
    /// (view's top-left inside the capture, x and y in points; capture width and height in points)
    var c: SIMD4<Float>
    /// (rim only, fringe, body dim, picture fade-in 0...1)
    var d: SIMD4<Float>
    /// (body: colour, lift, inner shadow and left band on (1) or off (0, the geometry tests); frost radius pt; ink 0 light
    /// ... 1 dark; dark ink's lift)
    var e: SIMD4<Float>
    /// (the theme tint: rgb, body wash)
    var f: SIMD4<Float> = SIMD4(0, 0, 0, 0)

    /// `dim` nil: from the size (`EdgeLensProfile.dim`).
    static func make(kind: EdgeLensShape.Kind, size: CGSize, scale: CGFloat, offset: CGPoint, capture: CGSize,
                     hasPicture: Bool, rimOnly: Bool, dim: CGFloat? = nil, fade: CGFloat = 1, body: Bool = true,
                     ink: CGFloat = 0, tint: SIMD4<Float> = SIMD4(0, 0, 0, 0)) -> EdgeLensUniforms {
        let half = min(size.width, size.height) / 2
        let band = EdgeLensProfile.band(minHalf: half)
        let isCircle: Bool = { if case .circle = kind { return true } else { return false } }()
        return EdgeLensUniforms(
            a: SIMD4(Float(size.width), Float(size.height), Float(scale), isCircle ? 0 : 1),
            b: SIMD4(Float(kind.radius(in: size)), Float(band), Float(EdgeLensProfile.maxShift(band: band)), hasPicture ? 1 : 0),
            c: SIMD4(Float(offset.x), Float(offset.y), Float(max(capture.width, 1)), Float(max(capture.height, 1))),
            d: SIMD4(rimOnly ? 1 : 0, Float(EdgeLensProfile.fringe), Float(dim ?? EdgeLensProfile.dim(minHalf: half)),
                     Float(min(max(fade, 0), 1))),
            e: SIMD4(body ? 1 : 0, body ? Float(EdgeLensProfile.frost) : 0, Float(min(max(ink, 0), 1)), Float(EdgeLensInk.darkLift)),
            f: tint)
    }
}

/// The device, the compiled pipeline, and the views to redraw when a frame lands.
final class EdgeLensRenderer {
    static let shared = EdgeLensRenderer()
    static let pixelFormat = MTLPixelFormat.bgra8Unorm

    private(set) var device: MTLDevice?
    private(set) var queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var blank: MTLTexture?
    private var prepared = false
    private(set) var compileError: String?
    private let views = NSHashTable<EdgeLensNSView>.weakObjects()

    /// Compiles once. nil: ready (or no device: see `device`); else the compile error.
    @discardableResult
    func prepare() -> String? {
        if prepared { return compileError }
        prepared = true
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        do {
            let library = try device.makeLibrary(source: Self.source, options: nil)
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: "lensVertex")
            d.fragmentFunction = library.makeFunction(name: "lensFragment")
            d.colorAttachments[0].pixelFormat = Self.pixelFormat
            pipeline = try device.makeRenderPipelineState(descriptor: d)
            queue = device.makeCommandQueue()
            let t = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.pixelFormat, width: 1, height: 1, mipmapped: false)
            blank = device.makeTexture(descriptor: t)
            self.device = device
        } catch {
            compileError = String(describing: error).replacingOccurrences(of: "\n", with: " ").prefix(240).description
        }
        return compileError
    }

    /// Draws one surface into `target` (cleared first): premultiplied, alpha 0 outside the shape.
    func encode(_ commands: MTLCommandBuffer, target: MTLTexture, uniforms: EdgeLensUniforms, picture: MTLTexture?) {
        guard let pipeline else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let enc = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        var u = uniforms
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBytes(&u, length: MemoryLayout<EdgeLensUniforms>.stride, index: 0)
        enc.setFragmentTexture(picture ?? blank, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    func register(_ v: EdgeLensNSView) { views.add(v) }
    func unregister(_ v: EdgeLensNSView) { views.remove(v) }

    /// The theme in the glass (2026-11-26: "make the theme more prominent through the liquid glass"): the dock palette's
    /// accent (rgb) and how much of it washes the body (a). The rim's fringe takes the same colour.
    private(set) var tint = SIMD4<Float>(0, 0.898, 1, Float(EdgeLensProfile.tintStrength))
    func setTint(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? color
        let t = SIMD4(Float(c.redComponent), Float(c.greenComponent), Float(c.blueComponent), Float(EdgeLensProfile.tintStrength))
        guard t != tint else { return }
        tint = t
        for v in views.allObjects { v.redraw(frameTime: nil, force: true) }
    }

    /// The ink: every surface with its own region measures the frame under it.
    func sampleInk(_ pixels: CVPixelBuffer, capture: NSRect) {
        EdgeLensInk.shared.sample(pixels, capture: capture, views: views.allObjects)
    }

    /// Every lens view redraws if anything it draws changed (its place on screen after an ancestor moved, the picture).
    func redrawAll() { views.allObjects.forEach { $0.redraw(frameTime: nil) } }

    /// A new frame: every lens view on screen redraws (the first one reports the frame's delay).
    func frameArrived(_ time: CFTimeInterval) {
        var first = true
        for v in views.allObjects {
            v.redraw(frameTime: first ? time : nil)
            first = false
        }
    }

    /// A full-screen triangle; the fragment shader does the rest in points (y down from the view's top-left).
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct U { float4 a; float4 b; float4 c; float4 d; float4 e; float4 f; };
    struct V { float4 pos [[position]]; };

    vertex V lensVertex(uint vid [[vertex_id]]) {
        float2 p = float2(float((vid << 1) & 2), float(vid & 2));
        V o;
        o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
        return o;
    }

    static float sdf(float2 p, float2 size, float kind, float radius) {
        float2 c = size * 0.5;
        if (kind < 0.5) { return length(p - c) - min(c.x, c.y); }
        float r = min(radius, min(c.x, c.y));
        float2 q = abs(p - c) - c + r;
        return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
    }

    fragment float4 lensFragment(V in [[stage_in]], constant U &u [[buffer(0)]],
                                 texture2d<float> picture [[texture(0)]]) {
        constexpr sampler s(address::clamp_to_edge, filter::linear);
        float2 size = u.a.xy;
        float scale = u.a.z, kind = u.a.w;
        float radius = u.b.x, band = u.b.y, shift = u.b.z, has = u.b.w;
        float2 off = u.c.xy, cap = u.c.zw;
        float rimOnly = u.d.x, fringe = u.d.y, dim = u.d.z, fade = u.d.w;
        float body = u.e.x, frost = u.e.y, ink = u.e.z, lift = u.e.w;

        float2 p = in.pos.xy / scale;
        float d = sdf(p, size, kind, radius);
        float cover = clamp(0.5 - d * scale, 0.0, 1.0);
        if (cover <= 0.0) { return float4(0.0); }

        // The outward normal (the distance field's slope).
        float e = 0.5;
        float2 n = float2(sdf(p + float2(e, 0.0), size, kind, radius) - sdf(p - float2(e, 0.0), size, kind, radius),
                          sdf(p + float2(0.0, e), size, kind, radius) - sdf(p - float2(0.0, e), size, kind, radius));
        n = length(n) > 1e-4 ? normalize(n) : float2(0.0, -1.0);
        float t = max(-d, 0.0);
        float x = clamp(t / band, 0.0, 1.0);
        float f = (1.0 - x) * (1.0 - x);

        float4 o = float4(0.0);
        if (has > 0.5) {
            // Rim only: the picture fades out over the band's inner quarter (the real screen shows in the centre).
            // `fade`: the picture's 0.15 s fade-in after the first frame.
            float a = (rimOnly > 0.5 ? 1.0 - smoothstep(0.75, 1.0, x) : 1.0) * fade;
            if (a > 0.0) {
                float k = fringe * abs(n.y);
                float sh = shift * f;
                float2 at = p + off + n * sh;
                // The frost: a light blur (eight taps on a ring of `frost` pt round the bent sample, and the sample).
                float3 c = picture.sample(s, at / cap).rgb;
                float3 sum = c * 0.2;
                for (int i = 0; i < 8; i++) {
                    float ang = float(i) * 0.785398;
                    sum += picture.sample(s, (at + float2(cos(ang), sin(ang)) * frost) / cap).rgb * 0.1;
                }
                // The colour split: red bends a little more, blue a little less (strongest at the top and bottom).
                float r = picture.sample(s, (p + off + n * sh * (1.0 + k)) / cap).r;
                float b = picture.sample(s, (p + off + n * sh * (1.0 - k)) / cap).b;
                float3 col = clamp(sum + float3(r - c.r, 0.0, b - c.b), 0.0, 1.0);
                // The body: a little more colour and a slight lift.
                float l = dot(col, float3(0.2126, 0.7152, 0.0722));
                col = mix(col, clamp(mix(float3(l), col, 1.15), 0.0, 1.0), body);
                col = mix(col, float3(1.0), 0.06 * body);
                o = float4(col * a, a);
            }
        }

        // Light ink: the body's light dim (white text stays readable). Dark ink: a white lift instead (the glass stays
        // bright and clear under near-black text). `ink` moves between the two.
        float4 dimmed = float4(o.rgb * (1.0 - dim), dim + o.a * (1.0 - dim));
        float4 lifted = float4(float3(lift) + o.rgb * (1.0 - lift), lift + o.a * (1.0 - lift));
        o = mix(dimmed, lifted, ink);
        // The theme: a wash of the accent through the body (premultiplied, so the alpha stays).
        o = float4(mix(o.rgb, u.f.rgb * o.a, u.f.a * body), o.a);

        // Thickness: a soft inner shadow along the bottom-right inside edge.
        float br = max(dot(n, float2(0.7071, 0.7071)), 0.0);
        float sha = 0.3 * body * br * exp(-t / 2.5);
        o = float4(o.rgb * (1.0 - sha), sha + o.a * (1.0 - sha));

        // A subtle darker gradient just inside the left edge (6 pt, 0.10 at most).
        float left = max(-n.x, 0.0);
        float dk = 0.10 * body * left * left * (1.0 - smoothstep(0.0, 6.0, t));
        o = float4(o.rgb * (1.0 - dk), dk + o.a * (1.0 - dk));

        // The crisp 1 pt rim: white 0.55 at the top-left fading to 0.15, a blue-to-pink fringe along the top and bottom.
        float line = 1.0 - smoothstep(0.7, 1.2, t);
        float lit = 0.15 + 0.40 * max(dot(n, float2(-0.7071, -0.7071)), 0.0);
        // The fringe in the theme's accent: full at the left, lighter toward the right.
        float3 accent = u.f.a > 0.0 ? u.f.rgb : float3(0.4, 0.68, 1.0);
        float3 tint = mix(accent, mix(accent, float3(1.0), 0.45), clamp(p.x / size.x, 0.0, 1.0));
        float fr = abs(n.y) * abs(n.y);
        // Under dark ink the hairline turns a soft dark grey (white would vanish on a bright backdrop).
        float3 rim = mix(mix(float3(1.0), float3(0.3), ink), tint, 0.8 * fr);
        float ra = line * max(lit, 0.45 * fr);
        o = float4(rim * ra + o.rgb * (1.0 - ra), ra + o.a * (1.0 - ra));

        return o * cover;
    }
    """
}

/// One surface's Metal layer. Never takes a click (`hitTest` nil); redraws on a new frame, a size change or a move.
final class EdgeLensNSView: NSView {
    /// How many were made in this process (the tests check it stays 0 in a test run).
    private(set) static var made = 0

    var kind: EdgeLensShape.Kind = .circle {
        didSet { if kind != oldValue { redraw(frameTime: nil) } }
    }
    private var metal: CAMetalLayer? { layer as? CAMetalLayer }
    /// The surface picks its own ink from what lies under it (nil: it follows the surface it sits on).
    var region: EdgeLensRegion?
    /// Where it was last drawn (screen points), for the ink sampling.
    private(set) var onScreen: CGRect?
    /// 0 light ink (the body dimmed), 1 dark ink (the body lifted); moves to `inkTarget` over `Motion.edgeState`.
    private var ink: CGFloat = 0
    private var inkTarget: CGFloat = 0
    private var inkRamp: Timer?

    func setInk(dark: Bool, animated: Bool) {
        let t: CGFloat = dark ? 1 : 0
        guard t != inkTarget else { return }
        inkTarget = t
        inkRamp?.invalidate()
        if !animated || Motion.still || Motion.reduceMotion {
            ink = t
            return redraw(frameTime: nil)
        }
        let start = ink, began = CACurrentMediaTime(), length = 0.12 // `Motion.edgeState`: ease-out, 0.12 s
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            let x = min(1, (CACurrentMediaTime() - began) / length)
            self.ink = start + (t - start) * CGFloat(1 - (1 - x) * (1 - x))
            self.redraw(frameTime: nil)
            if x >= 1 { timer.invalidate() }
        }
        RunLoop.main.add(timer, forMode: .common)
        inkRamp = timer
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        Self.made += 1
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }
    required init?(coder: NSCoder) { fatalError() }

    override func makeBackingLayer() -> CALayer {
        let l = CAMetalLayer()
        l.device = EdgeLensRenderer.shared.device
        l.pixelFormat = EdgeLensRenderer.pixelFormat
        l.isOpaque = false
        l.framebufferOnly = true
        l.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        l.presentsWithTransaction = false
        return l
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { EdgeLensRenderer.shared.unregister(self) } else {
            EdgeLensRenderer.shared.register(self)
            redraw(frameTime: nil)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        redraw(frameTime: nil)
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        redraw(frameTime: nil)
    }

    /// What the last draw showed: a redraw with the same place, size, shape and picture is skipped.
    private struct Drawn: Equatable {
        let onScreen: CGRect; let kind: EdgeLensShape.Kind; let picture: ObjectIdentifier?; let capture: CGRect; let fade: CGFloat
        let ink: CGFloat
    }
    private var drawn: Drawn?

    /// Draws now (a new frame always; otherwise only when something changed and the window shows). `frameTime`: the
    /// frame's display time, to measure its delay to the screen.
    func redraw(frameTime: CFTimeInterval?, force: Bool = false) {
        let renderer = EdgeLensRenderer.shared, capture = EdgeLensCapture.shared
        guard let window, window.isVisible, let metal, let queue = renderer.queue, bounds.width >= 1, bounds.height >= 1 else { return }
        let onScreen = window.convertToScreen(convert(bounds, to: nil))
        self.onScreen = onScreen
        let cap = capture.captureRect
        let fade = capture.pictureFade
        let now = Drawn(onScreen: onScreen, kind: kind, picture: capture.texture.map { ObjectIdentifier($0) }, capture: cap, fade: fade,
                        ink: ink)
        if frameTime == nil, !force, now == drawn { return }
        drawn = now
        let scale = window.backingScaleFactor
        if metal.device == nil { metal.device = renderer.device }
        metal.contentsScale = scale
        metal.drawableSize = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        let u = EdgeLensUniforms.make(kind: kind, size: bounds.size, scale: scale,
                                      offset: CGPoint(x: onScreen.minX - cap.minX, y: cap.maxY - onScreen.maxY),
                                      capture: cap.size, hasPicture: capture.texture != nil, rimOnly: EdgeLensCapture.rimOnly,
                                      fade: fade, ink: ink, tint: renderer.tint)
        guard let drawable = metal.nextDrawable(), let commands = queue.makeCommandBuffer() else { return }
        renderer.encode(commands, target: drawable.texture, uniforms: u, picture: capture.texture)
        if let frameTime {
            drawable.addPresentedHandler { d in
                let at = d.presentedTime
                DispatchQueue.main.async { EdgeLensCapture.shared.recordPresented(frame: frameTime, at: at) }
            }
        }
        DockPerf.tick("lensDraw")
        commands.present(drawable)
        commands.commit()
    }
}

private struct EdgeLensSurface: NSViewRepresentable {
    let kind: EdgeLensShape.Kind
    let region: EdgeLensRegion?
    let darkInk: Bool
    func makeNSView(context: Context) -> EdgeLensNSView {
        let v = EdgeLensNSView(frame: .zero)
        v.region = region
        v.kind = kind
        v.setInk(dark: darkInk, animated: false)
        return v
    }
    func updateNSView(_ v: EdgeLensNSView, context: Context) {
        v.region = region
        v.kind = kind
        v.setInk(dark: darkInk, animated: true)
    }
}

/// The lens under a glass surface's content: the Metal view (it never takes a click). Every pixel inside the shape has
/// alpha (the body's dim or lift at least, the picture opaque), so clicks land on the surface as they did on the system
/// glass; every pixel outside is alpha 0. With a `region` the surface picks its own ink (`EdgeLensInk`) and sets its
/// content's colour scheme (dark ink: the light scheme, so the hierarchical styles turn near-black); without one it
/// follows the scheme of the surface it sits on.
struct EdgeLensGlass<S: InsettableShape>: ViewModifier {
    let shape: S
    var region: EdgeLensRegion?
    @ObservedObject private var ink = EdgeLensInk.shared
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let dark = region.map { ink.dark[$0] ?? false } ?? (scheme == .light)
        content
            .environment(\.colorScheme, dark ? .light : .dark)
            .environment(\.edgeLensInked, true)
            .background(EdgeLensSurface(kind: EdgeLensShape.Kind(shape), region: region, darkInk: dark).allowsHitTesting(false))
    }
}

/// A lens surface only in the `lens` style off the flat path (the search fields, the timer chip and the card's round
/// buttons, which sit on another surface's glass in the other styles).
private struct EdgeLensOnly<S: InsettableShape>: ViewModifier {
    let shape: S
    let on: Bool
    let region: EdgeLensRegion?
    @Environment(\.edgeGlassStyle) private var style
    func body(content: Content) -> some View {
        if on && style == .lens && !EdgeDockArt.flat { content.modifier(EdgeLensGlass(shape: shape, region: region)) } else { content }
    }
}

extension View {
    /// `region`: the surface samples its backdrop and picks its own ink; nil: it follows the surface it sits on.
    func edgeLensOnly<S: InsettableShape>(_ shape: S, on: Bool = true, region: EdgeLensRegion? = nil) -> some View {
        modifier(EdgeLensOnly(shape: shape, on: on, region: region))
    }
}

// MARK: - Adaptive ink

private struct EdgeLensInkedKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// Inside a lens surface that set its content's colour scheme from its ink (an inner `edgeFlatScheme` keeps it).
    var edgeLensInked: Bool {
        get { self[EdgeLensInkedKey.self] }
        set { self[EdgeLensInkedKey.self] = newValue }
    }
}

/// A glass surface that picks its own ink from the backdrop under it.
enum EdgeLensRegion: Hashable {
    case disc, card, chip
    /// A ring item (Chats 0, Notes 1).
    case item(Int)
    /// A rim button, by its symbol.
    case button(String)

    /// The card weights its text rows: the top 22% (the search field or the header) and the bottom 30% (the caption
    /// and the buttons) count twice. Elsewhere every sample counts once.
    func weight(atFraction y: CGFloat) -> CGFloat {
        guard self == .card else { return 1 }
        return y < 0.22 || y > 0.7 ? 2 : 1
    }
}

/// Light ink (white text on a dimmed body) or dark ink (near-black text on a lifted body), per surface, from the mean
/// luminance of the latest frame under it: sampled at most 5 times a second, smoothed over 0.3 s, with hysteresis.
final class EdgeLensInk: ObservableObject {
    static let shared = EdgeLensInk()

    /// Dark ink above this (the body's luminance with today's light-ink dim), light ink again below `toLight`.
    static let toDark = 0.55
    static let toLight = 0.42
    /// Smoothing time constant and the sampling period.
    static let tau = 0.3
    static let period = 0.2
    /// The body's white lift under dark ink (instead of the dim).
    static let darkLift: CGFloat = 0.15

    @Published private(set) var dark: [EdgeLensRegion: Bool] = [:]
    private(set) var smoothed: [EdgeLensRegion: Double] = [:]
    private var target: [EdgeLensRegion: Double] = [:]
    private var lastTick: CFTimeInterval?

    /// sRGB byte to linear light.
    private static let linear: [Double] = (0..<256).map { i in
        let c = Double(i) / 255
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    /// The body's luminance under light ink for a backdrop of relative luminance `y`: in sRGB terms the lift (0.06) then
    /// the dim (`EdgeLensProfile.bodyDim`).
    static func effective(_ y: Double) -> Double {
        let v = pow(max(0, min(1, y)), 1 / 2.4)
        return pow((v * 0.94 + 0.06) * (1 - Double(EdgeLensProfile.bodyDim)), 2.4)
    }

    /// Hysteresis on the body's luminance: no flicker between `toLight` and `toDark`.
    static func decide(dark: Bool, luma: Double) -> Bool {
        dark ? luma >= toLight : luma > toDark
    }

    /// One step of the 0.3 s smoothing.
    static func smooth(_ s: Double, toward y: Double, dt: Double) -> Double {
        s + (y - s) * (1 - exp(-max(0, dt) / tau))
    }

    /// The mean relative luminance of a BGRA (sRGB) frame inside `rect` (pixels, y down), every `step` pixels, inside
    /// the ellipse when `round`, weighted by `region` (by the row's place in the rect). nil: no sample inside.
    static func meanLuminance(_ base: UnsafeRawPointer, width: Int, height: Int, bytesPerRow: Int, rect: CGRect, round: Bool,
                              region: EdgeLensRegion, step: Int = 6) -> Double? {
        let r = rect.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !r.isNull, r.width >= 1, r.height >= 1 else { return nil }
        let p = base.assumingMemoryBound(to: UInt8.self)
        var sum = 0.0, weights = 0.0
        var y = Int(r.minY)
        while y < Int(r.maxY) {
            let fy = (CGFloat(y) - rect.minY) / max(rect.height, 1)
            let w = Double(region.weight(atFraction: fy))
            var x = Int(r.minX)
            while x < Int(r.maxX) {
                let inside: Bool = {
                    guard round else { return true }
                    let dx = (CGFloat(x) - rect.midX) / (rect.width / 2), dy = (CGFloat(y) - rect.midY) / (rect.height / 2)
                    return dx * dx + dy * dy <= 1
                }()
                if inside {
                    let i = y * bytesPerRow + x * 4
                    sum += w * (0.0722 * linear[Int(p[i])] + 0.7152 * linear[Int(p[i + 1])] + 0.2126 * linear[Int(p[i + 2])])
                    weights += w
                }
                x += step
            }
            y += step
        }
        return weights > 0 ? sum / weights : nil
    }

    /// A new show: the next sample of each surface sets its ink at once (no fade from the last show's backdrop).
    func restart() {
        target = [:]
        smoothed = [:]
        lastTick = nil
    }

    /// A fresh measurement of the body's luminance (`effective`) under `region`.
    func feed(_ region: EdgeLensRegion, _ luma: Double) {
        target[region] = luma
        if smoothed[region] == nil {
            smoothed[region] = luma
            set(region, Self.decide(dark: dark[region] ?? false, luma: luma), animated: false)
        }
    }

    /// The 5-per-second step: every surface moves toward its latest measurement and maybe flips its ink.
    func tick(now: CFTimeInterval = CACurrentMediaTime()) {
        let dt = lastTick.map { now - $0 } ?? Self.period
        lastTick = now
        for (region, y) in target {
            let s = Self.smooth(smoothed[region] ?? y, toward: y, dt: dt)
            smoothed[region] = s
            set(region, Self.decide(dark: dark[region] ?? false, luma: s), animated: true)
        }
    }

    private func set(_ region: EdgeLensRegion, _ on: Bool, animated: Bool) {
        guard (dark[region] ?? false) != on else { return }
        let calm = !animated || Motion.still || Motion.reduceMotion
        withAnimation(calm ? nil : Motion.edgeState) { dark[region] = on }
    }

    /// Samples the latest frame under every surface that picks its own ink.
    func sample(_ pixels: CVPixelBuffer, capture: NSRect, views: [EdgeLensNSView]) {
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels), capture.width > 0 else { return }
        let w = CVPixelBufferGetWidth(pixels), h = CVPixelBufferGetHeight(pixels)
        let k = CGFloat(w) / capture.width
        for v in views {
            guard let region = v.region, let on = v.onScreen else { continue }
            let rect = CGRect(x: (on.minX - capture.minX) * k, y: (capture.maxY - on.maxY) * k, width: on.width * k, height: on.height * k)
            let round: Bool = { if case .circle = v.kind { return true } else { return false } }()
            if let y = Self.meanLuminance(base, width: w, height: h, bytesPerRow: CVPixelBufferGetBytesPerRow(pixels), rect: rect,
                                          round: round, region: region, step: max(2, Int(k * 3))) {
                feed(region, Self.effective(y))
            }
        }
    }
}
