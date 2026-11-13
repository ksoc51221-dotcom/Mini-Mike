import Foundation
import Darwin

/// Routes Margin's long-lived `claude -p` processes (popup chats) through the local
/// billion-context proxy when it is running. If it is not, the first call starts it in the background and
/// that popup goes direct, so Claude never depends on the proxy being up. One-shot calls are left alone:
/// a single short call has nothing to compress.
/// Switch off with: defaults write com.kien.margin useBilliContext -bool false
enum BiliProxy {
    static let port: UInt16 = 18799

    static var enabled: Bool {
        UserDefaults.standard.object(forKey: "useBilliContext") as? Bool ?? true
    }

    /// Loopback connect either succeeds or is refused at once, so this never blocks.
    static func isListening() -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    /// Runs once per app launch, thread-safe (Swift initialises a static let exactly once).
    private static let startOnce: Void = {
        let script = NSHomeDirectory() + "/.local/bin/bili-proxy-up"
        guard FileManager.default.isExecutableFile(atPath: script) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: script)
        try? p.run()
    }()

    /// Call right before launching a long-lived `claude` process.
    static func apply(to env: inout [String: String]) {
        guard enabled else { return }
        if isListening() {
            env["ANTHROPIC_BASE_URL"] = "http://127.0.0.1:\(port)"
        } else {
            _ = startOnce
        }
    }
}
