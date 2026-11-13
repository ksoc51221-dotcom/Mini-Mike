import Foundation

/// Margin's patch: upstream SwiftMath finds its fonts through `Bundle.module`, which doesn't work inside a hand-assembled
/// signed .app. Fonts live in Resources/Fonts instead: the app's Resources/Fonts first, then the repo's, for `swift run` and tests.
enum MathFontLocator {
    static func url(_ name: String, _ ext: String) -> URL? {
        if let u = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Fonts") { return u }
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Fonts/\(name).\(ext)")
        return FileManager.default.fileExists(atPath: repo.path) ? repo : nil
    }
}
