import AppKit
import CoreText
import SwiftUI

/// Geist + Geist Mono, bundled in Resources/Fonts (variable fonts; each weight is a named instance, so a weight is
/// a PostScript name such as "Geist-SemiBold"). If registration fails everything falls back to SF.
enum MarginFonts {
    enum Family { case sans, italic, mono }

    /// True when Geist registered (or was already installed). Registers on first use, so any caller is safe.
    nonisolated(unsafe) private(set) static var available: Bool = {
        let ok = registerFiles()
        return ok
    }()

    /// Call at the very top of launch; later calls are no-ops.
    static func register() { _ = available }

    private static let fileNames = ["Geist-Variable", "Geist-Italic-Variable", "GeistMono-Variable"]

    private static func fontDirectories() -> [URL] {
        var dirs: [URL] = []
        if let r = Bundle.main.resourceURL { dirs.append(r.appendingPathComponent("Fonts")) }
        // `.build/release/Margin --uishots`: walk up from the executable to the repo's Resources/Fonts.
        var url = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
        for _ in 0..<8 {
            url.deleteLastPathComponent()
            dirs.append(url.appendingPathComponent("Resources/Fonts"))
        }
        return dirs
    }

    private static func registerFiles() -> Bool {
        let fm = FileManager.default
        for dir in fontDirectories() {
            let files = fileNames.map { dir.appendingPathComponent($0 + ".ttf") }
            guard files.allSatisfy({ fm.fileExists(atPath: $0.path) }) else { continue }
            var any = false
            for f in files {
                var err: Unmanaged<CFError>?
                if CTFontManagerRegisterFontsForURL(f as CFURL, .process, &err) { any = true }
                else if let e = err?.takeRetainedValue(), CFErrorGetCode(e) == 105 { any = true } // already registered
            }
            if any { break }
        }
        return CTFontCreateWithName("Geist-Regular" as CFString, 12, nil).familyName == "Geist"
    }

    /// Weight -> named instance suffix.
    private static func suffix(_ w: CGFloat) -> String {
        switch w {
        case ..<(-0.5): return "Thin"
        case ..<(-0.1): return "Light"
        case ..<0.1: return "Regular"
        case ..<0.27: return "Medium"
        case ..<0.35: return "SemiBold"
        case ..<0.5: return "Bold"
        case ..<0.6: return "ExtraBold"
        default: return "Black"
        }
    }

    private static func postScriptName(_ family: Family, _ w: CGFloat) -> String {
        let s = suffix(w)
        switch family {
        case .sans: return "Geist-\(s)"
        case .mono: return "GeistMono-\(s)"
        case .italic: return s == "Regular" ? "Geist-Italic" : "Geist-\(s)Italic"
        }
    }

    static func ctFont(_ family: Family, _ size: CGFloat, _ weight: CGFloat) -> CTFont? {
        guard available else { return nil }
        let f = CTFontCreateWithName(postScriptName(family, weight) as CFString, size, nil)
        return f.familyName.hasPrefix("Geist") ? f : nil
    }

    static func nsFont(_ family: Family, _ size: CGFloat, _ weight: NSFont.Weight) -> NSFont? {
        ctFont(family, size, weight.rawValue) as NSFont?
    }

    static func swiftUIWeight(_ w: Font.Weight) -> CGFloat {
        switch w {
        case .ultraLight: return -0.8
        case .thin: return -0.6
        case .light: return -0.4
        case .medium: return 0.23
        case .semibold: return 0.3
        case .bold: return 0.4
        case .heavy: return 0.56
        case .black: return 0.62
        default: return 0
        }
    }
}

private extension CTFont {
    var familyName: String { CTFontCopyFamilyName(self) as String }
}

extension Font {
    /// Geist at an exact size and weight (SF if the fonts did not register).
    static func geist(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        if let f = MarginFonts.ctFont(.sans, size, MarginFonts.swiftUIWeight(weight)) { return Font(f) }
        return .system(size: size, weight: weight)
    }
    static func geistMono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        if let f = MarginFonts.ctFont(.mono, size, MarginFonts.swiftUIWeight(weight)) { return Font(f) }
        return .system(size: size, weight: weight, design: .monospaced)
    }
    static func geistItalic(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        if let f = MarginFonts.ctFont(.italic, size, MarginFonts.swiftUIWeight(weight)) { return Font(f) }
        return .system(size: size, weight: weight).italic()
    }
}
