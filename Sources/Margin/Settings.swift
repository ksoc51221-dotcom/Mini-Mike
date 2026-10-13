import Foundation

enum ModelChoice: String, CaseIterable {
    case sonnet, haiku, opus

    var title: String { rawValue.capitalized }
}

/// What gets screenshotted when you click the ? (sent with your first question).
enum ScreenContext: String, CaseIterable {
    case smart, screen, window, off

    var title: String {
        switch self {
        case .smart: return "Smart (only when needed)"
        case .screen: return "Whole Screen"
        case .window: return "Just the App Window"
        case .off: return "Off"
        }
    }
}

/// Small UserDefaults-backed settings store.
final class Settings {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    var paused: Bool {
        get { defaults.bool(forKey: "paused") }
        set { defaults.set(newValue, forKey: "paused") }
    }

    var model: ModelChoice {
        get { ModelChoice(rawValue: defaults.string(forKey: "model") ?? "") ?? .sonnet }
        set { defaults.set(newValue.rawValue, forKey: "model") }
    }

    var webSearch: Bool {
        get { defaults.object(forKey: "webSearch") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "webSearch") }
    }

    var screenContext: ScreenContext {
        get { ScreenContext(rawValue: defaults.string(forKey: "screenContext") ?? "") ?? .smart }
        set { defaults.set(newValue.rawValue, forKey: "screenContext") }
    }

    /// The popup's "make bigger" toggle (remembered for the next popup).
    var largePopup: Bool {
        get { defaults.bool(forKey: "largePopup") }
        set { defaults.set(newValue, forKey: "largePopup") }
    }

    /// Whether the chat sidebar is unfolded (otherwise it's a slim strip of dots).
    var sidebarOpen: Bool {
        get { defaults.object(forKey: "sidebarOpen") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "sidebarOpen") }
    }

    /// Local mode: quick questions and short summaries are answered by a model on this Mac (through Ollama)
    /// instead of Claude. Off unless you turn it on.
    var localMode: Bool {
        get { defaults.bool(forKey: "localMode") }
        set { defaults.set(newValue, forKey: "localMode") }
    }

    /// The Ollama model Local mode uses. (`defaults write com.kien.margin localModel <name>` to change it.)
    var localModel: String {
        get { defaults.string(forKey: "localModel") ?? "qwen3:8b" }
        set { defaults.set(newValue, forKey: "localModel") }
    }


    /// Chats are saved to the History (on this Mac) so you can find them later. Turn off to keep nothing.
    var saveHistory: Bool {
        get { defaults.object(forKey: "saveHistory") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "saveHistory") }
    }

    /// Kept notes are also written as Markdown files in Documents/Margin Notes.
    /// When a chat is closed, Claude gives it a better name and sector (unless you named or filed it yourself).
    var nameChatsOnClose: Bool {
        get { defaults.object(forKey: "nameChatsOnClose") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "nameChatsOnClose") }
    }

    var mirrorNotes: Bool {
        get { defaults.object(forKey: "mirrorNotes") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "mirrorNotes") }
    }

    /// How many agents (open chats + sidebar rows) can exist at once.
    let maxAgents = 4

    /// Apps where Margin never looks at selections (password managers, the Dock).
    let excludedBundleIDs: Set<String> = [
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
        "com.apple.keychainaccess",
        "com.apple.Passwords",
        "com.apple.dock",
    ]

    /// Apps where the ⌘C fallback is skipped because ⌘C copies files, not text.
    let noCopyFallbackBundleIDs: Set<String> = [
        "com.apple.finder",
    ]
}
