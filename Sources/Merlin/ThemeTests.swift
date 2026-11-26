import AppKit
import Foundation

extension FeatureTests {
    /// The accent colour, light/dark mode, and that they survive a restart.
    static func themeChecks(_ check: (String, Bool) -> Void) {
        func hex(_ c: NSColor) -> UInt32 {
            let s = c.usingColorSpace(.sRGB) ?? c
            return (UInt32((s.redComponent * 255).rounded()) << 16) | (UInt32((s.greenComponent * 255).rounded()) << 8) | UInt32((s.blueComponent * 255).rounded())
        }
        let lime = AccentTheme.lime
        check("theme: default accent is still Merlin's lime",
              hex(lime.fill) == 0xC6FF3D && hex(lime.text(dark: false)) == 0x4A6B00 && hex(lime.text(dark: true)) == 0xC6FF3D
              && hex(lime.onFill) == 0x0B0B0C)

        var worst = 99.0, worstName = ""
        for (name, theme) in AccentTheme.presets {
            for dark in [false, true] {
                let canvas = dark ? Theme.canvas.dark : Theme.canvas.light
                let text = AccentTheme.contrast(theme.text(dark: dark), canvas)
                let ink = AccentTheme.contrast(theme.onFill, theme.fill)
                let low = min(text, ink)
                if low < worst { worst = low; worstName = "\(name) \(dark ? "dark" : "light")" }
            }
        }
        check("theme: every preset reads in light and dark (≥ 4.5:1; worst \(worstName) \(String(format: "%.1f", worst)))", worst >= 4.5)

        var sweepOK = true
        for i in 0...40 {
            let t = AccentTheme(hue: Double(i) / 40)
            for dark in [false, true] {
                let canvas = dark ? Theme.canvas.dark : Theme.canvas.light
                if AccentTheme.contrast(t.text(dark: dark), canvas) < 4.5 { sweepOK = false }
            }
            if AccentTheme.contrast(t.onFill, t.fill) < 4.5 { sweepOK = false }
        }
        check("theme: every hue on the spectrum reads too", sweepOK)

        // The default (cyan) and every cover colour the music accent can take: 24 hues x 3 saturations x 3 brightnesses,
        // and greys. As text on both canvases, and the ink on its fill.
        var coverOK = true, coverWorst = 99.0
        var covers: [NSColor] = [AccentTheme.cyan, .white, .black, NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)]
        for i in 0..<24 { for sat in [0.3, 0.7, 1.0] { for b in [0.35, 0.7, 1.0] {
            covers.append(NSColor(hue: CGFloat(i) / 24, saturation: CGFloat(sat), brightness: CGFloat(b), alpha: 1))
        } } }
        for c in covers {
            let t = AccentTheme(hue: nil, followsMusic: true, exact: c)
            for dark in [false, true] {
                let canvas = dark ? Theme.canvas.dark : Theme.canvas.light
                let r = AccentTheme.contrast(t.text(dark: dark), canvas)
                coverWorst = min(coverWorst, r)
                if r < 4.5 { coverOK = false }
            }
            if AccentTheme.contrast(t.onFill, t.fill) < 4.5 { coverOK = false }
        }
        check("theme: cyan and every cover colour read as text and under their ink (worst \(String(format: "%.1f", coverWorst)))", coverOK)
        check("theme: the default accent is electric cyan #00E5FF", hex(AccentTheme.music.fill) == 0x00E5FF)

        // The 60-30-10 tokens: the ink on every surface in both modes.
        var inkOK = true, inkWorstName = ""
        for dark in [false, true] {
            for (sn, surface) in [("canvas", Theme.canvas), ("surface", Theme.surface), ("raised", Theme.surfaceRaised)] {
                let bg = surface.resolved(dark: dark)
                for (tn, token, need) in [("ink", Theme.ink, 7.0), ("secondary", Theme.inkSecondary, 4.5), ("tertiary", Theme.inkTertiary, 4.5)]
                where AccentTheme.contrast(token.resolved(dark: dark), bg) < need {
                    inkOK = false
                    inkWorstName += " \(tn) on \(sn) \(dark ? "dark" : "light") \(String(format: "%.2f", AccentTheme.contrast(token.resolved(dark: dark), bg)))"
                }
            }
        }
        check("theme: ink (7:1), secondary and tertiary (4.5:1) read on every surface\(inkWorstName)", inkOK)

        let suite = UserDefaults(suiteName: "merlin.theme.test.\(UUID().uuidString)")!
        let store = ThemeStore(defaults: suite, appliesToApp: false)
        check("theme: a fresh store follows the music (cyan) and the system",
              store.choice == .music && hex(store.accent.fill) == 0x00E5FF && store.mode == .system)
        let old = UserDefaults(suiteName: "merlin.theme.test.\(UUID().uuidString)")!
        old.set(0.1028, forKey: "accentHue") // the orange saved before 2026-11-26
        check("theme: an old saved orange is not used (the accent follows the music)",
              hex(ThemeStore(defaults: old, appliesToApp: false).accent.fill) == 0x00E5FF && old.double(forKey: "accentHue") == 0.1028)
        store.setAccent(AccentTheme(hue: 0.75))
        store.setMode(.dark)
        let again = ThemeStore(defaults: suite, appliesToApp: false)
        check("theme: choices are kept", again.accent.hue == 0.75 && again.mode == .dark)
        store.setAccent(.lime)
        check("theme: lime again clears the saved hue", ThemeStore(defaults: suite, appliesToApp: false).accent == .lime)

        check("theme: modes map to appearances",
              AppearanceMode.system.nsAppearance == nil && AppearanceMode.light.nsAppearance?.name == .aqua
              && AppearanceMode.dark.nsAppearance?.name == .darkAqua && AppearanceMode(rawValue: "nonsense") == nil)

        // The tokens really follow the shared store.
        let shared = ThemeStore.shared
        let before = shared.choice
        shared.setAccent(AccentTheme(hue: 0.65))
        let changed = hex(Theme.accent.dark) == hex(AccentTheme(hue: 0.65).fill) && hex(Theme.accent.dark) != 0x00E5FF
        shared.setAccent(before)
        check("theme: Theme.accent follows the chosen colour, and restores", changed && hex(Theme.accent.dark) == 0x00E5FF)
        shared.setMusicAccent(.red)
        check("theme: the music accent never changes in a test run", hex(Theme.accent.dark) == 0x00E5FF)
    }
}
