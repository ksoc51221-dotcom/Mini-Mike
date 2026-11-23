import CoreGraphics

/// Resizing a chat by hand: which edge a press is on, and the new frame for a drag. Pure (no AppKit), so the rules can be
/// tested without a window. Frames are in screen points, origin bottom-left (AppKit's).
///
/// The top 40 pt is the move zone (`HeaderPress`), so it is never a resize zone: only the left, right and bottom edges and
/// the two bottom corners resize. The edge band is 6 pt deep, inside the window; a corner is the last 14 pt of an edge band.
struct PanelResize {
    enum Zone: Equatable { case left, right, bottom, bottomLeft, bottomRight }

    static let band: CGFloat = 6
    static let corner: CGFloat = 14
    /// The header strip that moves the window (same as `ChatPanel.startsDrag`).
    static let header: CGFloat = 40
    static let minSize = CGSize(width: 360, height: 260)

    /// The zone under `p` (window coordinates, origin bottom-left) in a window of `size`. Nil: not a resize zone.
    static func zone(at p: CGPoint, in size: CGSize) -> Zone? {
        guard p.x >= 0, p.y >= 0, p.x <= size.width, p.y <= size.height else { return nil }
        guard size.height - p.y >= header else { return nil } // the header wins
        let nearLeft = p.x < band, nearRight = p.x > size.width - band, nearBottom = p.y < band
        let cornerLeft = p.x < corner, cornerRight = p.x > size.width - corner, cornerBottom = p.y < corner
        if (nearBottom && cornerLeft) || (nearLeft && cornerBottom) { return .bottomLeft }
        if (nearBottom && cornerRight) || (nearRight && cornerBottom) { return .bottomRight }
        if nearLeft { return .left }
        if nearRight { return .right }
        if nearBottom { return .bottom }
        return nil
    }

    /// The frame after dragging `zone` of `start` by `delta` (screen points). The opposite edge and the top edge stay put.
    /// Never smaller than `minSize`, never larger than `screen` (the visible frame), and the moving edge stops at the
    /// screen's edge.
    static func resized(_ start: CGRect, zone: Zone, by delta: CGPoint, within screen: CGRect) -> CGRect {
        var minX = start.minX, maxX = start.maxX, minY = start.minY
        let maxY = start.maxY
        let maxW = max(minSize.width, screen.width), maxH = max(minSize.height, screen.height)
        if zone == .left || zone == .bottomLeft {
            let room = max(minSize.width, maxX - screen.minX)
            let w = clamp(start.width - delta.x, minSize.width, min(maxW, room))
            minX = maxX - w
        }
        if zone == .right || zone == .bottomRight {
            let room = max(minSize.width, screen.maxX - minX)
            let w = clamp(start.width + delta.x, minSize.width, min(maxW, room))
            maxX = minX + w
        }
        if zone == .bottom || zone == .bottomLeft || zone == .bottomRight {
            let room = max(minSize.height, maxY - screen.minY)
            let h = clamp(start.height - delta.y, minSize.height, min(maxH, room))
            minY = maxY - h
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// `frame` made to fit `screen`: no larger than it, and moved inside it, `margin` points from its edges when there is
    /// room (flush with the edge when there isn't).
    static func fit(_ frame: CGRect, into screen: CGRect, margin: CGFloat = 0) -> CGRect {
        let w = min(frame.width, screen.width), h = min(frame.height, screen.height)
        func place(_ v: CGFloat, _ size: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
            let m = hi - lo - size >= 2 * margin ? margin : 0
            return clamp(v, lo + m, hi - size - m)
        }
        return CGRect(x: place(frame.minX, w, screen.minX, screen.maxX),
                      y: place(frame.maxY - h, h, screen.minY, screen.maxY), width: w, height: h)
    }

    private static func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { min(max(v, lo), max(lo, hi)) }
}

/// The ⤢ button (and a double-click on the header): fill the visible screen, and again to go back. Pure.
struct FillToggle {
    /// The frame the chat had before it filled the screen, and whether that size was set by hand. Nil: not filled.
    private(set) var before: (frame: CGRect, manual: Bool)?
    var isFilled: Bool { before != nil }

    /// Where to go: the whole screen when not filled (a fixed size), the earlier frame (and whether it was set by hand)
    /// when filled.
    mutating func toggle(current: CGRect, manual: Bool, screen: CGRect) -> (frame: CGRect, manual: Bool) {
        if let b = before {
            before = nil
            return b
        }
        before = (current, manual)
        return (screen, true)
    }

    /// A drag on an edge while filled: the chat now has a new hand-set size, and the earlier one is forgotten.
    mutating func forget() { before = nil }
}

/// The width a new chat starts at. A new chat always starts at the auto size (its height fits its content, it grows
/// with its answer); only the width of the last size set by hand carries over, and only a sane one.
/// Nil: the default width.
enum ChatStartSize {
    /// The default width (`AskPanelController.width`) and the old "make bigger" width (1.5 x).
    static let defaultWidth: CGFloat = 380
    static let largeWidth: CGFloat = 570

    /// The widest saved width a new chat may take on `screen` (a visible frame): 1.5 x the default, and 60% of the screen.
    static func maxWidth(screen: CGRect) -> CGFloat { min(largeWidth, screen.width * 0.6) }

    /// A saved width that is invalid or wider than `maxWidth` (a filled screen saved by an old build, say) is rejected:
    /// the chat opens at the default width. The saved value itself is left alone.
    static func resolve(saved: CGSize?, isVideo: Bool, screen: CGRect) -> CGFloat? {
        guard let saved, !isVideo else { return nil } // a video summary starts at the large auto size
        let w = saved.width
        guard w.isFinite, w > 0, w <= maxWidth(screen: screen) else { return nil }
        return max(PanelResize.minSize.width, w)
    }

    /// Whether a hand resize that ended at `size` is saved for new chats. A drag that started on a filled chat is not
    /// (a fill must never become the next chat's size), and neither is a width beyond `maxWidth` (the earlier sane
    /// saved width is kept). The chat itself keeps its size either way.
    static func shouldSave(size: CGSize, startedFilled: Bool, screen: CGRect) -> Bool {
        !startedFilled && size.width.isFinite && size.width > 0 && size.height > 0 && size.width <= maxWidth(screen: screen)
    }
}
