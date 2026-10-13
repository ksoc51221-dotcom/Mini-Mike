import AppKit
import SwiftUI

/// The background agents' pixel cats: eight coats and three poses (sitting, running, loaf). Each sprite is a tiny
/// grid of letters, so the cats stay crisp at any size. A light "sticker" edge keeps dark cats visible on the black bar.
enum PixelCat {
    struct Coat {
        let name: String
        let colors: [Character: UInt32]
    }

    enum Pose: Hashable {
        case sit
        case run(Int)
        case loaf
    }

    static let width = 22, height = 16
    static let runFrames = 4
    /// Room around the sprite for the sticker edge.
    static let pad = 1

    // Letters: k outline · h head · x head stripe · l inner ear · e/f left/right eye · n nose · c cheek · w muzzle
    //          b body · y body stripe · p chest and paws · t tail · z tail stripe/tip

    private static func coat(_ name: String, outline: UInt32, head: UInt32, stripe: UInt32? = nil, ear: UInt32? = nil,
                             eyes: (UInt32, UInt32), nose: UInt32? = nil, cheek: UInt32? = nil, muzzle: UInt32? = nil,
                             body: UInt32? = nil, chest: UInt32? = nil, tail: UInt32? = nil, tip: UInt32? = nil) -> Coat {
        let b = body ?? head
        let t = tail ?? b
        return Coat(name: name, colors: [
            "k": outline, "h": head, "x": stripe ?? head, "l": ear ?? head, "e": eyes.0, "f": eyes.1,
            "n": nose ?? outline, "c": cheek ?? head, "w": muzzle ?? head,
            "b": b, "y": stripe ?? b, "p": chest ?? b, "t": t, "z": tip ?? stripe ?? t,
        ])
    }

    static let coats: [Coat] = [
        coat("Snow", outline: 0x2B2B2E, head: 0xFAFAFA, ear: 0xF6B9C6, eyes: (0x5DB8EA, 0x5DB8EA), nose: 0xEE8FA6, cheek: 0xF6B3C2),
        coat("Cocoa", outline: 0x2A2420, head: 0x8E7D6C, stripe: 0x5F5146, ear: 0x6E5F52, eyes: (0x2A2420, 0x2A2420)),
        coat("Silver", outline: 0x2A2A2D, head: 0xBDBDC2, stripe: 0x7E7E86, ear: 0xA2A2A8, eyes: (0x2A2A2D, 0x2A2A2D),
             muzzle: 0xF6F6F6, chest: 0xF6F6F6),
        coat("Shadow", outline: 0x0B0B0D, head: 0x36363D, ear: 0x55555E, eyes: (0xF5A524, 0xF5A524), nose: 0x0B0B0D),
        coat("Marmalade", outline: 0x3B2412, head: 0xF2A65A, stripe: 0xD47F2A, ear: 0xE8957F, eyes: (0x3B2412, 0x3B2412),
             muzzle: 0xF8D2A2, chest: 0xF8D2A2),
        coat("Pepper", outline: 0x222225, head: 0x5F5F66, ear: 0x7B7B83, eyes: (0x222225, 0x222225),
             muzzle: 0xF7F7F7, chest: 0xF7F7F7),
        coat("Mocha", outline: 0x2A211B, head: 0x5C4636, ear: 0x7A5E4A, eyes: (0x5DB8EA, 0x5DB8EA),
             body: 0xF4EEE4, tail: 0x5C4636),
        coat("Pearl", outline: 0x2B2B2E, head: 0xFAFAFA, ear: 0xEFD9C8, eyes: (0x5DB8EA, 0xF2C94C), nose: 0xEE8FA6),
    ]

    // MARK: Sprites

    /// The head, 11×8, stamped on top of each body.
    private static let head = [
        "kk.......kk",
        "klk.....klk",
        "khhkkkkkhhk",
        "khhxhxhxhhk",
        "khhhhhhhhhk",
        "khhehhhfhhk",
        "kchwwnwwhck",
        ".kwwwwwwwk.",
    ]
    /// Eyes shut, for the contented loaf.
    private static let sleepyHead: [String] = {
        var h = head
        h[5] = "khkkhhhkkhk"
        return h
    }()

    /// Standing side-on, head turned to you, tail up: "sitting still".
    private static let sitBody = [
        "....................",
        "....................",
        "....................",
        ".................kk.",
        "................kzzk",
        "...............kttk.",
        "..............kttk..",
        "..........kkkkttk...",
        "..kpppbbybbybbbk....",
        "..kpppbbbybbbbbk....",
        "..kppbbbbbbbbbbk....",
        "..kppbbbbbbbbbbk....",
        "..kppkkkkkkkkppk....",
        "..kppk......kppk....",
        "..kkkk......kkkk....",
        "....................",
    ]

    /// Lying down with the paws tucked in and the tail wrapped round: a loaf.
    private static let loafBody = [
        "....................",
        "....................",
        "....................",
        "....................",
        "....................",
        "...........kkkkk....",
        "...........kbbbbkk..",
        "...........kbybbbbk.",
        "...........kbbybbbbk",
        "...........kbbbbbbbk",
        "..........kbbbybbbbk",
        ".kpppkpppkbbbbbbbbbk",
        ".kkkkkkkkkzttttttttk",
        ".........kkkkkkkkkk.",
        "....................",
        "....................",
    ]

    /// Running: front leg reaching forward, hind leg pushing back, tail streaming behind (head up).
    private static let runStretch = [
        "......................",
        "......................",
        "......................",
        "......................",
        "......................",
        "...........kkkkkkkkkkk",
        "...........kbbbbbbttzk",
        "...........kbybbbbttzk",
        "...........kbbybbbkkkk",
        "...........kbbbbbbk...",
        "..kpppppppkbbbbbbbk...",
        ".kppkkkkkkkkkkkkppk...",
        "kppk............kppk..",
        "kkk..............kkk..",
        "......................",
        "......................",
    ]
    /// Running: legs passing straight under the body.
    private static let runPass = [
        "......................",
        "......................",
        "......................",
        "......................",
        "......................",
        "......................",
        "...........kkkkkkkkkkk",
        "...........kbbbbbbttzk",
        "...........kbybbbbttzk",
        "...........kbbybbbkkkk",
        "...........kbbbbbbk...",
        "..kpppppppkbbbbbbbk...",
        "..kkppkkkkkkkkppkkk...",
        "...kppk......kppk.....",
        "...kkkk......kkkk.....",
        "......................",
    ]
    /// Running: legs gathered under the belly (head down).
    private static let runGather = [
        "......................",
        "......................",
        "......................",
        "......................",
        "......................",
        "......................",
        "......................",
        "...........kkkkkkkkkkk",
        "...........kbbbbbbttzk",
        "...........kbybbbbttzk",
        "...........kbbybbbkkkk",
        "...........kbbbbbbk...",
        "..kpppppppkbbbbbbbk...",
        "..kkkkkkppkppkkkkkk...",
        ".......kppkppk........",
        ".......kkkkkkk........",
    ]

    /// The letter grid for a pose, head included.
    static func grid(_ pose: Pose) -> [[Character]] {
        let body: [String], headRows: [String], at: (x: Int, y: Int)
        switch pose {
        case .sit: (body, headRows, at) = (sitBody, head, (1, 0))
        case .loaf: (body, headRows, at) = (loafBody, sleepyHead, (1, 3))
        case .run(let i):
            switch i % runFrames {
            case 0: (body, headRows, at) = (runStretch, head, (1, 2))
            case 2: (body, headRows, at) = (runGather, head, (1, 4))
            default: (body, headRows, at) = (runPass, head, (1, 3))
            }
        }
        var g = body.map { row -> [Character] in
            var r = Array(row)
            while r.count < width { r.append(".") }
            return Array(r.prefix(width))
        }
        while g.count < height { g.append(Array(repeating: ".", count: width)) }
        for (dy, row) in headRows.enumerated() {
            for (dx, ch) in row.enumerated() where ch != "." {
                let y = at.y + dy, x = at.x + dx
                if y < height && x < width { g[y][x] = ch }
            }
        }
        return g
    }

    // MARK: Drawing

    private static var cache: [String: CGImage] = [:]

    /// The sprite as an image, `scale` pixels per grid square, with a light sticker edge. Cached.
    static func image(coat index: Int, pose: Pose, scale: Int = 3) -> CGImage? {
        let key = "\(index)-\(pose)-\(scale)"
        if let hit = cache[key] { return hit }
        let coat = coats[((index % coats.count) + coats.count) % coats.count]
        let g = grid(pose)
        let w = (width + pad * 2) * scale, h = (height + pad * 2) * scale
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .none
        func fill(_ x: Int, _ y: Int, _ color: CGColor) {
            ctx.setFillColor(color)
            // CG's origin is bottom-left; the grid's is top-left.
            ctx.fill(CGRect(x: (x + pad) * scale, y: h - (y + pad + 1) * scale, width: scale, height: scale))
        }
        // The sticker edge: every empty square touching the cat.
        let edge = CGColor(red: 1, green: 1, blue: 1, alpha: 0.92)
        for y in -pad..<(height + pad) {
            for x in -pad..<(width + pad) {
                if y >= 0, y < height, x >= 0, x < width, g[y][x] != "." { continue }
                var touches = false
                for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (1, 1), (-1, 1), (1, -1)] {
                    let nx = x + dx, ny = y + dy
                    if ny >= 0, ny < height, nx >= 0, nx < width, g[ny][nx] != "." { touches = true; break }
                }
                if touches { fill(x, y, edge) }
            }
        }
        for y in 0..<height {
            for x in 0..<width {
                let ch = g[y][x]
                guard ch != ".", let hex = coat.colors[ch] else { continue }
                fill(x, y, CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                                   blue: CGFloat(hex & 0xFF) / 255, alpha: 1))
            }
        }
        let image = ctx.makeImage()
        cache[key] = image
        return image
    }

}

/// One cat, drawn crisp at 2.5 points per square (5 pixels on a Retina screen). Running cats trot back and forth.
struct PixelCatView: View {
    enum Mood: Equatable {
        /// Sitting still: waiting to start, or waiting for your OK.
        case idle
        case running
        /// A running cat while the bar is hidden: mid-stride, not moving.
        case paused
        /// Finished: a loaf.
        case done
    }

    let coat: Int
    let mood: Mood
    /// How far a running cat roams to each side, in points.
    var roam: CGFloat = 10
    /// Screen pixels per square on a Retina display: 5 in the bar, 3 in the minimized strip.
    var pixels = 5

    private var size: CGSize {
        CGSize(width: CGFloat((PixelCat.width + PixelCat.pad * 2) * pixels) / 2, height: CGFloat((PixelCat.height + PixelCat.pad * 2) * pixels) / 2)
    }

    var body: some View {
        Group {
            switch mood {
            case .idle: sprite(.sit)
            case .done: sprite(.loaf)
            case .paused: sprite(.run(0))
            case .running:
                TimelineView(.periodic(from: .now, by: 1.0 / 15)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    let frame = Int(t * 10) % PixelCat.runFrames
                    // Trot left, turn, trot right: a triangle wave, facing the way it's going.
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
        if let image = PixelCat.image(coat: coat, pose: pose, scale: pixels) {
            Image(decorative: image, scale: 2).interpolation(.none)
        }
    }
}
