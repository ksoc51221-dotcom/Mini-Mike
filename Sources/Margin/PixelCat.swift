import AppKit
import SwiftUI
import ImageIO

/// The background agents' pixel cats: eight coats in six poses (standing, a three-picture trot, loaf, asleep). They're cut from a
/// pixel-art sheet by scripts/make-cat-atlas.swift into one transparent picture (CatAtlas.swift), each with a white "sticker" edge
/// so dark cats stay visible on the black bar. Every picture has the cat's feet on the same line and its weight on the same
/// vertical line, so switching poses never makes it jump.
enum PixelCat {
    struct Coat {
        let name: String
    }

    enum Pose: Hashable {
        /// Standing, head turned to you, tail up: waiting to start or for your OK.
        case sit
        /// A trot: stretched out, walking, crouched, walking.
        case run(Int)
        /// Lying down with the head up: finished.
        case loaf
        /// Curled up asleep (zzz): waiting its turn.
        case sleep
    }

    static let runFrames = 4

    /// In the atlas's row order.
    static let coats: [Coat] = [
        Coat(name: "Cinnamon"), Coat(name: "Cocoa"), Coat(name: "Silver"), Coat(name: "Shadow"),
        Coat(name: "Marmalade"), Coat(name: "Mittens"), Coat(name: "Latte"), Coat(name: "Domino"),
    ]

    /// One picture's size in atlas pixels.
    static let cell = CGSize(width: CatAtlas.cellWidth, height: CatAtlas.cellHeight)

    /// Which column of the atlas each pose is.
    static func column(_ pose: Pose) -> Int {
        switch pose {
        case .sit: return 0
        case .run(let i): return [1, 2, 3, 2][((i % runFrames) + runFrames) % runFrames]
        case .loaf: return 4
        case .sleep: return 5
        }
    }

    // MARK: Drawing

    private static func decode(_ base64: String) -> CGImage? {
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static let atlas: CGImage? = decode(CatAtlas.png)
    private static let sleepAtlas: CGImage? = decode(CatSleepAtlas.png)

    /// The whole atlas (for tests).
    static var atlasImage: CGImage? { atlas }

    private static var cache: [Int: CGImage] = [:]
    private static var bigCache: [Int: CGImage] = [:]
    private static var inhaledCache: [Int: CGImage] = [:]

    /// One big sleeping cat's picture size (see CatSleepAtlas: every sheet pixel is a 5×5 block).
    static let bigCell = CGSize(width: CatSleepAtlas.cellWidth, height: CatSleepAtlas.cellHeight)

    /// One picture of the big sleeping cat: column 0 is the cat, columns 1… its z's, all on the same canvas. Cached.
    private static func bigPicture(coat index: Int, column: Int) -> CGImage? {
        let row = ((index % coats.count) + coats.count) % coats.count
        let key = row * 16 + column
        if let hit = bigCache[key] { return hit }
        guard let sleepAtlas else { return nil }
        let image = sleepAtlas.cropping(to: CGRect(x: CGFloat(column) * bigCell.width, y: CGFloat(row) * bigCell.height,
                                                   width: bigCell.width, height: bigCell.height))
        bigCache[key] = image
        return image
    }

    /// The big cat asleep (without its z's), the one that rests in the corner of the screen.
    static func bigSleeping(coat index: Int) -> CGImage? { bigPicture(coat: index, column: 0) }

    /// One of the z's over a big sleeping cat (0 is the smallest), on a canvas the size of the cat's.
    static func bigZ(coat index: Int, _ z: Int) -> CGImage? {
        guard (0..<CatSleepAtlas.zCount).contains(z) else { return nil }
        return bigPicture(coat: index, column: 1 + z)
    }

    /// The same cat breathed in: one sheet pixel taller (a row of blocks in the middle of its body is repeated, so the back moves up
    /// a block and the paws stay where they are). Rows are copied, never blended, so it stays hard pixels.
    static func bigSleepingInhaled(coat index: Int) -> CGImage? {
        let row = ((index % coats.count) + coats.count) % coats.count
        if let hit = inhaledCache[row] { return hit }
        guard let rest = bigSleeping(coat: row) else { return nil }
        let w = rest.width, h = rest.height, stride = w * 4, block = CatSleepAtlas.block
        var px = [UInt8](repeating: 0, count: stride * h)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: stride, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(rest, in: CGRect(x: 0, y: 0, width: w, height: h))
        func difference(_ a: Int, _ b: Int) -> Int {
            var d = 0
            for i in 0..<stride { d += abs(Int(px[a * stride + i]) - Int(px[b * stride + i])) }
            return d
        }
        // Repeat the row that looks most like its neighbours (flat fur, not an outline), somewhere in the body.
        var split = h * 62 / 100, best = Int.max
        for y in (h * 62 / 100)..<(h * 82 / 100) {
            let d = difference(y - 1, y) + difference(y, y + 1)
            if d < best { best = d; split = y }
        }
        // The picture with that row repeated `block` more times, minus its first `block` rows: everything above moves up, nothing below does.
        var out = px
        for y in 0..<h {
            let from = y <= split - block ? y + block : y <= split ? split : y
            if from != y { for i in 0..<stride { out[y * stride + i] = px[from * stride + i] } }
        }
        guard let outCtx = CGContext(data: &out, width: w, height: h, bitsPerComponent: 8, bytesPerRow: stride, space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let made = outCtx.makeImage() else { return nil }
        inhaledCache[row] = made
        return made
    }

    /// One cat in one pose, `cell` pixels, on a transparent background. Cached.
    static func image(coat index: Int, pose: Pose) -> CGImage? {
        let row = ((index % coats.count) + coats.count) % coats.count
        let col = column(pose)
        let key = row * 16 + col
        if let hit = cache[key] { return hit }
        guard let atlas else { return nil }
        let image = atlas.cropping(to: CGRect(x: CGFloat(col) * cell.width, y: CGFloat(row) * cell.height, width: cell.width, height: cell.height))
        cache[key] = image
        return image
    }
}

/// One cat. Running cats trot back and forth, facing the way they're going.
struct PixelCatView: View {
    enum Mood: Equatable {
        /// Standing still: waiting to start, or waiting for your OK.
        case idle
        case running
        /// A running cat while the bar is hidden: mid-stride, not moving.
        case paused
        /// Finished: a loaf.
        case done
        /// Waiting its turn behind other agents: curled up asleep.
        case asleep
    }

    let coat: Int
    let mood: Mood
    /// How far a running cat roams to each side, in points.
    var roam: CGFloat = 10
    /// Tenths of a point per picture pixel: 5 in the bar (a cat about 55 points across, one picture pixel per Retina pixel),
    /// 3 in the minimized strip.
    var pixels = 5

    private var size: CGSize {
        CGSize(width: PixelCat.cell.width * CGFloat(pixels) / 10, height: PixelCat.cell.height * CGFloat(pixels) / 10)
    }

    var body: some View {
        Group {
            switch mood {
            case .idle: sprite(.sit)
            case .done: sprite(.loaf)
            case .asleep: sprite(.sleep)
            case .paused: sprite(.run(0))
            case .running:
                TimelineView(.periodic(from: .now, by: 1.0 / 15)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    let frame = Int(t * 8) % PixelCat.runFrames
                    // Trot left, turn, trot right: a triangle wave, facing the way it's going (the pictures face left).
                    let period = 2.4
                    let phase = t.truncatingRemainder(dividingBy: period) / period
                    let goingLeft = phase < 0.5
                    let p = goingLeft ? phase * 2 : (1 - phase) * 2
                    sprite(.run(frame))
                        .scaleEffect(x: goingLeft ? 1 : -1, y: 1)
                        .offset(x: (roam - CGFloat(p) * roam * 2).rounded())
                }
            }
        }
        .frame(width: size.width, height: size.height)
    }

    @ViewBuilder private func sprite(_ pose: PixelCat.Pose) -> some View {
        if let image = PixelCat.image(coat: coat, pose: pose) {
            Image(decorative: image, scale: 10 / CGFloat(pixels)).interpolation(.high)
        }
    }
}

/// A cat asleep on the desktop: it breathes (on every in-breath it rises one block of the art, then settles) and its z's float up and
/// away, one after another. Everything moves in whole blocks, so it stays pixel art.
struct SleepingCatView: View {
    let coat: Int
    /// Tenths of a point per picture pixel (a sheet pixel is 5 of them, so 4 here is 2 points: whole device pixels on a Retina screen).
    var pixels = 4
    /// Where in its breath and its z's cycle this cat starts, so a row of cats isn't in step.
    var offset = 0.0

    /// Seconds for one breath, in and out.
    static let breathPeriod = 4.0
    /// Seconds for the z's: they appear one after another, drift up, then all fade.
    static let zPeriod = 5.0

    /// Is the cat breathed in at `time`? About 45% of each breath.
    static func inhaled(at time: Double, offset: Double = 0) -> Bool {
        var phase = (time / breathPeriod + offset).truncatingRemainder(dividingBy: 1)
        if phase < 0 { phase += 1 }
        return phase >= 0.3 && phase < 0.75
    }

    /// How visible the `index`th z is at `time`, and how many blocks it has floated up.
    static func zState(at time: Double, index: Int, offset: Double = 0) -> (opacity: Double, rise: Int) {
        var p = (time + offset * zPeriod).truncatingRemainder(dividingBy: zPeriod)
        if p < 0 { p += zPeriod }
        let appears = 0.3 + 0.8 * Double(index), fadeAt = 4.2
        guard p >= appears else { return (0, 0) }
        let rise = min(3, Int((p - appears) / 0.55))
        if p >= fadeAt { return (max(0, 1 - (p - fadeAt) / 0.7), rise) }
        return (min(1, (p - appears) / 0.3), rise)
    }

    private var size: CGSize {
        CGSize(width: PixelCat.bigCell.width * CGFloat(pixels) / 10, height: PixelCat.bigCell.height * CGFloat(pixels) / 10)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let scale = 10 / CGFloat(pixels)
            ZStack(alignment: .topLeading) {
                if let image = Self.inhaled(at: t, offset: offset) ? PixelCat.bigSleepingInhaled(coat: coat) : PixelCat.bigSleeping(coat: coat) {
                    Image(decorative: image, scale: scale).interpolation(.high)
                }
                ForEach(0..<CatSleepAtlas.zCount, id: \.self) { z in
                    let state = Self.zState(at: t, index: z, offset: offset)
                    if state.opacity > 0, let image = PixelCat.bigZ(coat: coat, z) {
                        Image(decorative: image, scale: scale).interpolation(.high)
                            .opacity(state.opacity)
                            .offset(y: -CGFloat(state.rise * CatSleepAtlas.block) / scale)
                    }
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}
