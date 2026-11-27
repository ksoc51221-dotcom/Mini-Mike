import Foundation

/// Redraw counters for the dock (2026-11-27, the lag hunt). Off unless Merlin is launched with MERLIN_DOCK_PERF=1:
/// then once a second one line goes to ~/Library/Logs/Merlin/dockperf.log with how many times each part drew or ticked.
/// (A file, not os_log: the unified log reached `log show` minutes late.) Never on in tests.
enum DockPerf {
    static let on = ProcessInfo.processInfo.environment["MERLIN_DOCK_PERF"] == "1"
        && !CommandLine.arguments.contains("--unittest") && !CommandLine.arguments.contains("--uishots")
    private static let lock = NSLock()
    nonisolated(unsafe) private static var counts: [String: Int] = [:]
    nonisolated(unsafe) private static var state: () -> String = { "" }
    nonisolated(unsafe) private static var timer: Timer?
    private static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Merlin", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("dockperf.log")
    }()

    /// One more draw or tick of `name` (any thread).
    @inline(__always) static func tick(_ name: StaticString) {
        guard on else { return }
        lock.lock(); counts["\(name)", default: 0] += 1; lock.unlock()
    }

    /// Starts the once-a-second line (main thread); `describe` adds the dock's state to each line.
    static func start(describe: @escaping () -> String) {
        guard on, timer == nil else { return }
        state = describe
        try? "--- start \(Date())\n".appendTo(url)
        let t = Timer(timeInterval: 1, repeats: true) { _ in flush() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private static func flush() {
        lock.lock(); let c = counts; counts = [:]; lock.unlock()
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        let parts = c.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        try? "\(f.string(from: Date())) \(state()) | \(parts)\n".appendTo(url)
    }
}

private extension String {
    func appendTo(_ url: URL) throws {
        let data = Data(utf8)
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            try h.seekToEnd(); try h.write(contentsOf: data)
        } else {
            try data.write(to: url)
        }
    }
}
