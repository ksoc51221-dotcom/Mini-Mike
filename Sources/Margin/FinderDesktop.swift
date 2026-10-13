import AppKit

/// Where the icons on your Desktop sit. Finder keeps those positions, so moving them means asking Finder (with AppleScript).
/// macOS asks you once to let Margin control Finder. Everything here is reversible: the positions (and Finder's "Sort By"
/// setting, which has to be None for icons to stay where they're put) are read before they're changed, and kept in the
/// task's undo ledger.
enum FinderDesktop {
    struct Placement: Equatable {
        var name: String
        var x: Int
        var y: Int
    }

    /// What Finder said back.
    struct Result: Equatable {
        /// The Sort By setting before (e.g. "snap to grid"), if Finder told us.
        var arrangement: String?
        /// Where each icon was.
        var old: [Placement] = []
        /// Items Finder couldn't place, with its reason.
        var failed: [(name: String, reason: String)] = []
        /// macOS hasn't let Margin control Finder.
        var needsPermission = false

        static func == (a: Result, b: Result) -> Bool {
            a.arrangement == b.arrangement && a.old == b.old && a.needsPermission == b.needsPermission
                && a.failed.map(\.name) == b.failed.map(\.name)
        }
    }

    /// Sends a script to Finder. Replaced in tests, so they never touch the real Desktop.
    static var runner: (_ script: String) -> (output: String, error: String) = { script in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-"]
        let input = Pipe(), output = Pipe(), error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        do { try process.run() } catch { return ("", error.localizedDescription) }
        try? input.fileHandleForWriting.write(contentsOf: Data(script.utf8))
        try? input.fileHandleForWriting.close()
        var out = Data(), err = Data()
        let group = DispatchGroup()
        for (pipe, isOut) in [(output, true), (error, false)] {
            group.enter()
            DispatchQueue.global().async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if isOut { out = data } else { err = data }
                group.leave()
            }
        }
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { process.waitUntilExit(); finished.signal() }
        if finished.wait(timeout: .now() + 90) == .timedOut { process.terminate() }
        _ = group.wait(timeout: .now() + 5)
        return (String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self))
    }

    // MARK: Scripts

    /// A string as an AppleScript literal.
    static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Names Finder can be given safely (no line breaks or tabs, which would break reading its answer back).
    static func isSafeName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\t" })
    }

    /// Sets each Desktop item's position, reading where it was first. With `freeArrangement`, also turns Finder's Sort By
    /// to None (icons snap back into order otherwise).
    static func positionScript(_ placements: [Placement], freeArrangement: Bool) -> String {
        var lines = [
            "set out to \"\"",
            "tell application \"Finder\"",
            "  try",
            "    set arr to (arrangement of icon view options of window of desktop) as text",
            "  on error",
            "    set arr to \"\"",
            "  end try",
            "  set out to out & \"ARR\" & tab & arr & linefeed",
        ]
        if freeArrangement {
            lines += ["  try", "    set arrangement of icon view options of window of desktop to not arranged", "  end try"]
        }
        for p in placements where isSafeName(p.name) {
            let n = quote(p.name)
            lines += [
                "  try",
                "    set p to position of item \(n) of desktop",
                "    set out to out & \"POS\" & tab & \(n) & tab & (item 1 of p) & tab & (item 2 of p) & linefeed",
                "    set position of item \(n) of desktop to {\(p.x), \(p.y)}",
                "  on error errMsg number errNum",
                "    set out to out & \"ERR\" & tab & \(n) & tab & errNum & tab & errMsg & linefeed",
                "  end try",
            ]
        }
        lines += ["end tell", "return out"]
        return lines.joined(separator: "\n")
    }

    /// Puts icons (and the Sort By setting) back.
    static func restoreScript(_ placements: [Placement], arrangement: String?) -> String {
        var lines = ["tell application \"Finder\""]
        if let arrangement, let word = arrangementWord(arrangement) {
            lines += ["  try", "    set arrangement of icon view options of window of desktop to \(word)", "  end try"]
        }
        for p in placements where isSafeName(p.name) {
            lines += ["  try", "    set position of item \(quote(p.name)) of desktop to {\(p.x), \(p.y)}", "  end try"]
        }
        lines += ["end tell", "return \"ok\""]
        return lines.joined(separator: "\n")
    }

    /// Finder's own words for Sort By (what `as text` gives, mapped back to something AppleScript accepts).
    static func arrangementWord(_ text: String) -> String? {
        switch text.trimmingCharacters(in: .whitespaces).lowercased() {
        case "not arranged": return "not arranged"
        case "snap to grid": return "snap to grid"
        case "arranged by name": return "arranged by name"
        case "arranged by kind": return "arranged by kind"
        case "arranged by modification date": return "arranged by modification date"
        case "arranged by creation date": return "arranged by creation date"
        case "arranged by size": return "arranged by size"
        case "arranged by label": return "arranged by label"
        default: return nil
        }
    }

    static let selectionScript = """
    tell application "Finder"
      set out to ""
      try
        repeat with i in (selection as alias list)
          set out to out & POSIX path of i & linefeed
        end repeat
      end try
      return out
    end tell
    """

    // MARK: Running them

    private static func isPermissionError(_ s: String) -> Bool {
        s.contains("-1743") || s.localizedCaseInsensitiveContains("not authorized") || s.localizedCaseInsensitiveContains("not allowed assistive")
    }

    static func parse(_ output: String, error: String) -> Result {
        var result = Result()
        result.needsPermission = isPermissionError(error)
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            switch f.first {
            case "ARR": result.arrangement = f.count > 1 ? f[1] : nil
            case "POS" where f.count >= 4:
                if let x = Int(f[2].trimmingCharacters(in: .whitespaces)), let y = Int(f[3].trimmingCharacters(in: .whitespaces)) {
                    result.old.append(Placement(name: f[1], x: x, y: y))
                }
            case "ERR" where f.count >= 2:
                result.failed.append((f[1], f.count > 3 ? f[3] : "Finder couldn't move it"))
            default: break
            }
        }
        return result
    }

    /// Places the icons. Blocks until Finder is done, so call it off the main thread.
    static func place(_ placements: [Placement], freeArrangement: Bool = true) -> Result {
        guard !placements.isEmpty else { return Result() }
        let run = runner(positionScript(placements, freeArrangement: freeArrangement))
        return parse(run.output, error: run.error)
    }

    static func restore(_ placements: [Placement], arrangement: String?) {
        guard !placements.isEmpty || arrangement != nil else { return }
        _ = runner(restoreScript(placements, arrangement: arrangement))
    }

    /// The items selected in Finder right now (only those inside folders Margin may work in are of any use to the caller).
    static func selection() -> (paths: [String], needsPermission: Bool) {
        let run = runner(selectionScript)
        let paths = run.output.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("/") }
        return (paths, isPermissionError(run.error))
    }

    // MARK: Where things go

    enum Layout: String, CaseIterable {
        case scatter, grid, row, column
    }

    /// The part of the main display where icons can sit, in Finder's coordinates (origin top-left): clear of the menu bar,
    /// the Dock and the screen's edges.
    static func usableArea(screen: NSScreen? = NSScreen.screens.first) -> CGRect {
        guard let screen else { return CGRect(x: 80, y: 80, width: 1200, height: 640) }
        let frame = screen.frame, visible = screen.visibleFrame
        let left = visible.minX - frame.minX + 70
        let right = visible.maxX - frame.minX - 70
        let top = frame.maxY - visible.maxY + 80
        let bottom = frame.maxY - visible.minY - 70
        return CGRect(x: left, y: top, width: max(200, right - left), height: max(200, bottom - top))
    }

    /// Where `count` icons go. Scatter is random but never crowded; the others are neat.
    static func positions(for layout: Layout, count: Int, in area: CGRect,
                          using generator: inout some RandomNumberGenerator) -> [CGPoint] {
        guard count > 0 else { return [] }
        switch layout {
        case .scatter:
            var spacing: CGFloat = 110
            while true {
                var points: [CGPoint] = []
                var attempts = 0
                while points.count < count, attempts < count * 60 {
                    attempts += 1
                    let p = CGPoint(x: .random(in: area.minX...area.maxX, using: &generator),
                                    y: .random(in: area.minY...area.maxY, using: &generator))
                    if points.allSatisfy({ hypot($0.x - p.x, $0.y - p.y) >= spacing }) { points.append(p) }
                }
                if points.count == count { return points }
                spacing *= 0.85 // too many for this much room: let them sit a little closer
                if spacing < 20 { // a very crowded desktop: stop caring about overlap
                    return (0..<count).map { _ in CGPoint(x: .random(in: area.minX...area.maxX, using: &generator),
                                                          y: .random(in: area.minY...area.maxY, using: &generator)) }
                }
            }
        case .grid:
            let cell: CGFloat = 110
            let columns = max(1, Int(area.width / cell))
            return (0..<count).map { i in CGPoint(x: area.minX + CGFloat(i % columns) * cell, y: area.minY + CGFloat(i / columns) * cell) }
        case .row:
            let step = count > 1 ? min(130, area.width / CGFloat(count - 1)) : 0
            let y = area.midY
            return (0..<count).map { CGPoint(x: area.minX + CGFloat($0) * step, y: y) }
        case .column:
            let step = count > 1 ? min(110, area.height / CGFloat(count - 1)) : 0
            return (0..<count).map { CGPoint(x: area.midX, y: area.minY + CGFloat($0) * step) }
        }
    }
}
