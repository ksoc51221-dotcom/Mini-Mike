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
        check("theme: default accent is still Margin's lime",
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

        let suite = UserDefaults(suiteName: "margin.theme.test.\(UUID().uuidString)")!
        let store = ThemeStore(defaults: suite, appliesToApp: false)
        check("theme: a fresh store is lime and follows the system", store.accent == .lime && store.mode == .system)
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
        let before = shared.accent
        shared.setAccent(AccentTheme(hue: 0.65))
        let changed = hex(Theme.accent.dark) == hex(AccentTheme(hue: 0.65).fill) && hex(Theme.accent.dark) != 0xC6FF3D
        shared.setAccent(before)
        check("theme: Theme.accent follows the chosen colour, and restores", changed && hex(Theme.accent.dark) == 0xC6FF3D)
    }
}
