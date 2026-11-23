import AppKit
import SceneKit
import SwiftUI

// MARK: - Building the 3D nodes (pure: the tests and the pictures use it without a window)

/// Turns a `SceneSpec` into SceneKit nodes. The parts sit in one container; the camera and lights are separate, so the
/// part count is stable. Every part's node is named "part:<id>"; an arrow is a container with exactly two children
/// (a cylinder shaft and a cone head).
enum SceneBuilder {
    static let partPrefix = "part:"

    /// The app's colour for each palette name.
    static func colour(_ c: SceneSpec.Colour, dark: Bool) -> NSColor {
        func rgb(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
        }
        switch c {
        case .red: return rgb(0xE5484D)
        case .orange: return rgb(0xF0883E)
        case .yellow: return rgb(0xF2C53D)
        case .green: return rgb(0x46A758)
        case .blue: return rgb(0x3E8EF7)
        case .purple: return rgb(0x8E6CEF)
        case .white: return rgb(dark ? 0xF2F2EE : 0xFAFAF7)
        case .neutral: return rgb(dark ? 0x8A8A92 : 0xA3A3A8)
        }
    }

    /// The stage behind the parts: one step up from the card.
    static func background(dark: Bool) -> NSColor { Theme.surfaceRaised.resolved(dark: dark) }

    private static func material(_ color: NSColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .blinn
        m.diffuse.contents = color
        m.specular.contents = NSColor(white: 1, alpha: 0.35)
        m.shininess = 0.4
        return m
    }

    /// The part's `i`th size number, or `fallback` when it gave fewer.
    private static func size(_ p: SceneSpec.Part, _ i: Int, _ fallback: Double) -> CGFloat {
        CGFloat(p.size.indices.contains(i) ? p.size[i] : fallback)
    }

    /// One part's own node (before its place or orbit is applied).
    static func node(for p: SceneSpec.Part, dark: Bool) -> SCNNode {
        let color = colour(p.colour, dark: dark)
        let node: SCNNode
        switch p.kind {
        case .sphere:
            node = SCNNode(geometry: SCNSphere(radius: size(p, 0, 0.5)))
            (node.geometry as? SCNSphere)?.segmentCount = 48
        case .box:
            let w = size(p, 0, 1), h = size(p, 1, Double(w)), l = size(p, 2, Double(w)) // one number is a cube
            node = SCNNode(geometry: SCNBox(width: w, height: h, length: l, chamferRadius: min(w, h, l) * 0.06))
        case .cylinder:
            node = SCNNode(geometry: SCNCylinder(radius: size(p, 0, 0.3), height: size(p, 1, 1)))
        case .cone:
            node = SCNNode(geometry: SCNCone(topRadius: 0, bottomRadius: size(p, 0, 0.4), height: size(p, 1, 1)))
        case .torus:
            let ring = size(p, 0, 1)
            node = SCNNode(geometry: SCNTorus(ringRadius: ring, pipeRadius: min(size(p, 1, 0.12), ring * 0.8)))
        case .arrow:
            node = arrow(length: size(p, 0, 1.5), direction: p.direction, color: color)
        case .label:
            node = label(p.text ?? "", scale: size(p, 0, 1), dark: dark)
        }
        if p.kind != .arrow && p.kind != .label { node.geometry?.materials = [material(color)] }
        node.name = partPrefix + p.id
        return node
    }

    /// A cylinder shaft and a cone head, from the part's place along `direction`.
    private static func arrow(length: CGFloat, direction: [Double], color: NSColor) -> SCNNode {
        let shaftRadius = max(0.035, length * 0.035)
        let headLength = min(length * 0.32, 0.5)
        let shaftLength = max(length - headLength, 0.01)
        let shaft = SCNNode(geometry: SCNCylinder(radius: shaftRadius, height: shaftLength))
        shaft.position = SCNVector3(0, shaftLength / 2, 0)
        let head = SCNNode(geometry: SCNCone(topRadius: 0, bottomRadius: shaftRadius * 2.8, height: headLength))
        head.position = SCNVector3(0, shaftLength + headLength / 2, 0)
        shaft.geometry?.materials = [material(color)]
        head.geometry?.materials = [material(color)]
        let container = SCNNode()
        container.addChildNode(shaft)
        container.addChildNode(head)
        container.simdOrientation = rotation(toward: direction)
        return container
    }

    /// The turn that points +y along `direction`. Straight down is its own case (the general turn is undefined there).
    static func rotation(toward direction: [Double]) -> simd_quatf {
        var d = SIMD3<Float>(Float(direction[0]), Float(direction[1]), Float(direction[2]))
        if simd_length(d) < 0.0001 { d = [0, 1, 0] }
        d = simd_normalize(d)
        let up = SIMD3<Float>(0, 1, 0)
        let dot = simd_dot(up, d)
        if dot > 0.9999 { return simd_quatf(angle: 0, axis: [1, 0, 0]) }
        if dot < -0.9999 { return simd_quatf(angle: .pi, axis: [0, 0, 1]) }
        return simd_quatf(from: up, to: d)
    }

    /// Flat text that always faces the camera, unlit so it reads the same from every side.
    private static func label(_ text: String, scale: CGFloat, dark: Bool) -> SCNNode {
        let fontSize: CGFloat = 48 // built large and scaled down: small SCNText sizes come out jagged
        // The system font: SCNText drops some of Geist's glyphs (seen in the pictures: "N cle s" for "Nucleus").
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let geometry = SCNText(string: text, extrusionDepth: 0)
        geometry.font = font
        geometry.flatness = 0.08
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = Theme.ink.resolved(dark: dark)
        m.isDoubleSided = true
        geometry.materials = [m]
        let textNode = SCNNode(geometry: geometry)
        let (lo, hi) = textNode.boundingBox
        textNode.pivot = SCNMatrix4MakeTranslation((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, 0)
        let k = 0.4 / fontSize * scale // about 0.4 units tall at size 1
        textNode.scale = SCNVector3(k, k, k)
        let holder = SCNNode()
        holder.addChildNode(textNode)
        holder.constraints = [SCNBillboardConstraint()]
        return holder
    }

    /// All the parts, placed, with orbits and spins. `animated` false: nothing moves (Reduce Motion, the pictures, tests).
    static func partsNode(_ spec: SceneSpec, dark: Bool, animated: Bool) -> SCNNode {
        let root = SCNNode()
        root.name = "parts"
        let orbiters = spec.parts.filter { $0.orbit != nil }.map(\.id)
        var placed: [String: SCNNode] = [:]
        var pending: [(SceneSpec.Part, SCNNode)] = []
        for p in spec.parts {
            let n = node(for: p, dark: dark)
            if let spin = p.spin, animated {
                n.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: spin)))
            }
            placed[p.id] = n
            if p.orbit == nil {
                n.position = SCNVector3(p.x, p.y, p.z)
                root.addChildNode(n)
            } else {
                pending.append((p, n))
            }
        }
        // Orbits: a pivot at the centre (tilted), a turner inside it, the part at the radius. Each orbiter starts at its
        // own angle so they don't stack in a still frame.
        var remaining = pending
        while !remaining.isEmpty {
            let before = remaining.count
            remaining.removeAll { p, n in
                guard let o = p.orbit else { return true }
                let pivot = SCNNode()
                if let a = o.around {
                    // Wait until the centre itself is placed, then hang the pivot from the centre's parent at the
                    // centre's place, so it follows a centre that moves (a moon around a planet).
                    guard let target = placed[a], let holder = target.parent else { return false }
                    pivot.position = target.position
                    holder.addChildNode(pivot)
                } else {
                    root.addChildNode(pivot)
                }
                pivot.eulerAngles.x = CGFloat(o.tilt * .pi / 180)
                // A faint ring shows the path, so a still frame (and Reduce Motion) still reads as an orbit.
                let ring = SCNNode(geometry: SCNTorus(ringRadius: CGFloat(o.radius), pipeRadius: 0.012))
                let ringMaterial = SCNMaterial()
                ringMaterial.lightingModel = .constant
                // Opaque, mixed with the stage colour by hand (a see-through ring rendered near-white on the light stage).
                ringMaterial.diffuse.contents = background(dark: dark).blended(withFraction: dark ? 0.5 : 0.4,
                                                                              of: Theme.inkTertiary.resolved(dark: dark))
                ring.geometry?.materials = [ringMaterial]
                ring.name = "path"
                pivot.addChildNode(ring)
                let turner = SCNNode()
                let k = orbiters.firstIndex(of: p.id) ?? 0
                turner.eulerAngles.y = CGFloat(Double(k) / Double(max(orbiters.count, 1)) * 2 * .pi + 0.6)
                pivot.addChildNode(turner)
                n.position = SCNVector3(o.radius, 0, 0)
                turner.addChildNode(n)
                if animated { turner.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: o.period))) }
                return true
            }
            if remaining.count == before { break } // never loops (cycles were cut when reading)
        }
        for (p, n) in remaining { // anything left circles the origin
            n.position = SCNVector3(p.x, p.y, p.z)
            root.addChildNode(n)
        }
        return root
    }

    /// The part nodes in a built tree.
    static func partNodes(in root: SCNNode) -> [SCNNode] {
        root.childNodes { n, _ in n.name?.hasPrefix(partPrefix) == true }
    }

    /// The box around everything, in scene units (orbits included at full radius).
    static func bounds(_ root: SCNNode) -> (min: SIMD3<Float>, max: SIMD3<Float>) {
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        func add(_ p: SIMD3<Float>) { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        for n in partNodes(in: root) {
            let (a, b) = n.boundingBox
            let local = [SIMD3<Float>(Float(a.x), Float(a.y), Float(a.z)), SIMD3<Float>(Float(b.x), Float(b.y), Float(b.z))]
            if n.constraints?.isEmpty == false { // a label: the box doesn't turn with the camera, so use a sphere around it
                let c = n.simdConvertPosition(.zero, to: root)
                let r = simd_length(n.childNodes.first.map { t -> SIMD3<Float> in
                    let (ta, tb) = t.boundingBox
                    return SIMD3<Float>(Float(tb.x - ta.x), Float(tb.y - ta.y), 0) * t.simdScale / 2
                } ?? .zero)
                add(c - r); add(c + r)
                continue
            }
            for x in [local[0].x, local[1].x] { for y in [local[0].y, local[1].y] { for z in [local[0].z, local[1].z] {
                add(n.simdConvertPosition([x, y, z], to: root))
            } } }
            // An orbiting part sweeps its whole circle: add the circle's extremes.
            if let turner = n.parent, turner !== root, let pivot = turner.parent {
                let r = simd_length(n.simdPosition) + max(local[1].x, local[1].y)
                for a in stride(from: Float(0), to: 2 * .pi, by: .pi / 4) {
                    add(pivot.simdConvertPosition([r * cos(a), 0, r * sin(a)], to: root))
                }
            }
        }
        if lo.x > hi.x { return ([-1, -1, -1], [1, 1, 1]) }
        return (lo, hi)
    }

    /// A built scene: the parts, soft lights, the background, and a camera that frames everything.
    static func scene(_ spec: SceneSpec, dark: Bool, animated: Bool) -> (scene: SCNScene, camera: SCNNode, target: SCNVector3) {
        let scene = SCNScene()
        scene.background.contents = background(dark: dark)
        let parts = partsNode(spec, dark: dark, animated: animated)
        scene.rootNode.addChildNode(parts)

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = dark ? 420 : 520
        scene.rootNode.addChildNode(ambient)
        for (dir, intensity) in [(SIMD3<Float>(-0.5, -0.8, -0.6), 820.0), (SIMD3<Float>(0.7, -0.2, 0.4), 260.0)] {
            let key = SCNNode()
            key.light = SCNLight()
            key.light?.type = .directional
            key.light?.intensity = CGFloat(intensity)
            key.simdLook(at: dir, up: [0, 1, 0], localFront: [0, 0, -1])
            scene.rootNode.addChildNode(key)
        }

        let (lo, hi) = bounds(parts)
        let centre = (lo + hi) / 2
        // The largest half-extent, with a margin: the box's diagonal framed everything far too small.
        let half = (hi - lo) / 2
        let radius = max(max(half.x, half.y, half.z) * 1.1, 1)
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 38
        camera.camera?.zNear = 0.1
        camera.camera?.zFar = 200
        let distance = radius / tan(Float(38.0 / 2 * .pi / 180)) + half.z * 0.4
        camera.simdPosition = centre + simd_normalize(SIMD3<Float>(0.32, 0.38, 1)) * distance
        camera.simdLook(at: centre)
        scene.rootNode.addChildNode(camera)
        return (scene, camera, SCNVector3(centre.x, centre.y, centre.z))
    }

    /// An offscreen picture of the scene (the `--uishots` pictures, where a live SCNView can't be captured).
    static func snapshot(_ spec: SceneSpec, dark: Bool, size: CGSize) -> NSImage? {
        guard size.width > 1, size.height > 1, let device = MTLCreateSystemDefaultDevice() else { return nil }
        let built = scene(spec, dark: dark, animated: false)
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = built.scene
        renderer.pointOfView = built.camera
        let image = renderer.snapshot(atTime: 0, with: CGSize(width: size.width * 2, height: size.height * 2), antialiasingMode: .multisampling4X)
        image.size = size
        return image
    }
}

// MARK: - The scene card in a chat

/// A small 3D scene Claude composed: drag to turn it, pinch (or ⌥-scroll) to zoom, "Reset view" to go back.
/// Orbits and spins move unless Reduce Motion is on. See `SceneSpec` for the format.
struct SceneView3D: View {
    let source: String
    private let spec: SceneSpec?
    @State private var resetCount = 0
    @Environment(\.colorScheme) private var scheme
    @Environment(\.merlinActivity) private var activity

    static let stageHeight: CGFloat = 240

    init(source: String) {
        self.source = source
        spec = SceneSpec.parse(source)
    }

    var body: some View {
        if let spec {
            card(spec)
        }
    }

    private func card(_ spec: SceneSpec) -> some View {
        let dark = scheme == .dark
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("3D · drag to turn")
                    .font(.geist(11, .medium))
                    .foregroundStyle(Theme.inkTertiary.color)
                Spacer(minLength: 0)
                Button {
                    activity()
                    resetCount += 1
                } label: {
                    Text("Reset view")
                }
                .buttonStyle(SceneQuietButton())
            }
            Group {
                if Motion.still {
                    GeometryReader { geo in
                        if let image = SceneBuilder.snapshot(spec, dark: dark, size: geo.size) {
                            Image(nsImage: image).resizable()
                        } else {
                            Color(nsColor: SceneBuilder.background(dark: dark))
                        }
                    }
                } else {
                    SceneStage(spec: spec, dark: dark, resetCount: resetCount)
                }
            }
            .frame(height: Self.stageHeight)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline.color, lineWidth: 1))
            if let caption = spec.caption {
                MarkdownText(text: caption)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .cardSurface()
    }
}

/// The live SceneKit view.
private struct SceneStage: NSViewRepresentable {
    let spec: SceneSpec
    let dark: Bool
    let resetCount: Int

    final class Coordinator {
        var camera: SCNNode?
        var home: SCNMatrix4 = SCNMatrix4Identity
        var target = SCNVector3Zero
        var dark: Bool?
        var spec: SceneSpec?
        var resetCount = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SceneHostView {
        let view = SceneHostView(frame: .zero, options: nil)
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.antialiasingMode = .multisampling4X
        view.rendersContinuously = false
        load(view, context.coordinator)
        context.coordinator.resetCount = resetCount
        return view
    }

    func updateNSView(_ view: SceneHostView, context: Context) {
        let c = context.coordinator
        if c.dark != dark || c.spec != spec { load(view, c) }
        if c.resetCount != resetCount {
            c.resetCount = resetCount
            if let camera = c.camera {
                camera.transform = c.home
                view.pointOfView = camera
                view.defaultCameraController.target = c.target
            }
        }
    }

    private func load(_ view: SceneHostView, _ c: Coordinator) {
        let animated = !Motion.reduceMotion && !Motion.still
        let built = SceneBuilder.scene(spec, dark: dark, animated: animated)
        view.scene = built.scene
        view.backgroundColor = SceneBuilder.background(dark: dark)
        view.pointOfView = built.camera
        view.defaultCameraController.target = built.target
        view.animates = animated
        view.isPlaying = animated && view.window != nil
        c.camera = built.camera
        c.home = built.camera.transform
        c.target = built.target
        c.dark = dark
        c.spec = spec
    }
}

/// Plays only while it is in a window; plain scrolling goes on to the chat (⌥-scroll or a pinch zooms).
final class SceneHostView: SCNView {
    var animates = false

    /// A drag turns the scene; it never moves a window that moves by its background (the library).
    override var mouseDownCanMoveWindow: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        isPlaying = animates && window != nil
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.option) { super.scrollWheel(with: event) } else { nextResponder?.scrollWheel(with: event) }
    }
}

/// The quiet action: text only, a faint fill on press (as on the board).
private struct SceneQuietButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.geist(12, .medium))
            .foregroundStyle(Theme.inkSecondary.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                .fill(configuration.isPressed ? Theme.hairline.color : Color.clear))
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
            .scaleEffect(configuration.isPressed ? Motion.pressScale : 1)
            .animation(Motion.animation(Motion.small), value: configuration.isPressed)
    }
}
