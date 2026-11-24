import AppKit
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

/// What the Library opens on.
enum LibraryDefaultView: String, CaseIterable {
    case desk, all, last

    var title: String {
        switch self {
        case .desk: return "Desk"
        case .all: return "All"
        case .last: return "Last used"
        }
    }
}

/// Which Shift starts point to ask.
enum PointKey: String, CaseIterable {
    case left, right, either

    var title: String {
        switch self {
        case .left: return "Left Shift"
        case .right: return "Right Shift"
        case .either: return "Either"
        }
    }

    /// The key codes that count (56 Left Shift, 60 Right Shift).
    var keys: Set<Int64> {
        switch self {
        case .left: return [56]
        case .right: return [60]
        case .either: return [56, 60]
        }
    }
}

enum LibraryRowDensity: String, CaseIterable {
    case comfortable, compact

    var title: String { rawValue.capitalized }
}

/// Small UserDefaults-backed settings store.
final class Settings {
    static let shared = Settings()

    private let defaults: UserDefaults

    /// Tests pass a throwaway suite, so a crash mid-test can never leave a deleting setting in your real preferences.
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

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

    /// Point to ask: hold Shift on its own, move over something, let go to ask about it. On unless turned off.
    var pointToAsk: Bool {
        get { defaults.object(forKey: "pointToAsk") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "pointToAsk") }
    }

    var pointToAskKey: PointKey {
        get { PointKey(rawValue: defaults.string(forKey: "pointToAskKey") ?? "") ?? .either }
        set { defaults.set(newValue.rawValue, forKey: "pointToAskKey") }
    }

    /// The last chat size set by hand (a drag on a chat's edge); a new chat starts at it. Nil: the auto size (the chat
    /// grows with its answer). Replaces the old "make bigger" switch (`largePopup`): on first read, a Mac that had it on
    /// gets the old big size saved once, and `largePopup` is never read again.
    var chatSize: CGSize? {
        get {
            migrateLargePopup()
            let w = defaults.double(forKey: Self.chatWidthKey), h = defaults.double(forKey: Self.chatHeightKey)
            return w > 0 && h > 0 ? CGSize(width: w, height: h) : nil
        }
        set {
            migrateLargePopup() // so an old switch can't come back over a size set (or cleared) later
            if let s = newValue, s.width > 0, s.height > 0 {
                defaults.set(Double(s.width), forKey: Self.chatWidthKey)
                defaults.set(Double(s.height), forKey: Self.chatHeightKey)
            } else {
                defaults.removeObject(forKey: Self.chatWidthKey)
                defaults.removeObject(forKey: Self.chatHeightKey)
            }
        }
    }
    static let chatWidthKey = "chatWidth", chatHeightKey = "chatHeight"
    /// The old "make bigger" chat: 570 wide, and a 540 pt answer area plus about 120 pt of header, source line and question box.
    static let largeChatSize = CGSize(width: 570, height: 660)

    private func migrateLargePopup() {
        guard !defaults.bool(forKey: "chatSizeMigrated") else { return }
        defaults.set(true, forKey: "chatSizeMigrated")
        if defaults.double(forKey: Self.chatWidthKey) <= 0, defaults.bool(forKey: "largePopup") {
            defaults.set(Double(Self.largeChatSize.width), forKey: Self.chatWidthKey)
            defaults.set(Double(Self.largeChatSize.height), forKey: Self.chatHeightKey)
        }
    }

    /// "Show a dot at the screen edge while Merlin works": the only thing the hidden edge panel shows at rest (on by default).
    var edgeDot: Bool {
        get { defaults.object(forKey: Self.edgeDotKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.edgeDotKey) }
    }
    static let edgeDotKey = "edgeDot"

    /// Local mode: quick questions and short summaries are answered by a model on this Mac (through Ollama)
    /// instead of Claude. Off unless you turn it on.
    var localMode: Bool {
        get { defaults.bool(forKey: "localMode") }
        set { defaults.set(newValue, forKey: "localMode") }
    }

    /// The model Local mode uses: by default Claude Haiku 5.5 (a `claude-…` id, answered through the Claude command), or an
    /// Ollama model that runs on this Mac. (`defaults write com.kien.merlin localModel qwen3:8b` switches to Ollama.)
    var localModel: String {
        get { defaults.string(forKey: "localModel") ?? Self.haikuID }
        set { defaults.set(newValue, forKey: "localModel") }
    }

    /// Which engine turns your voice into text: on this Mac (the default) or Groq Whisper (needs a key; the audio leaves the Mac).
    /// Local mode does not change it.
    static let voiceEngineKey = "voiceEngine"
    var voiceEngine: VoiceEngine {
        get { VoiceEngine(rawValue: defaults.string(forKey: Self.voiceEngineKey) ?? "") ?? .onDevice }
        set { defaults.set(newValue.rawValue, forKey: Self.voiceEngineKey) }
    }

    static let haikuID = "claude-haiku-5-5"

    /// How hard the quick model thinks (when it's a Claude model).
    var localEffort: String {
        get { defaults.string(forKey: "localEffort") ?? "medium" }
        set { defaults.set(newValue, forKey: "localEffort") }
    }

    /// The quick model is a Claude model (so it's answered by the Claude command), not one running on this Mac.
    static func isClaudeModel(_ name: String) -> Bool { name.hasPrefix("claude-") }
    /// The quick answers come from a model on this Mac (Ollama): nothing leaves it.
    var localIsOnMac: Bool { !Self.isClaudeModel(localModel) }


    // MARK: Personal settings. Stored on this Mac only, never in the repo. Empty means they add nothing to any prompt.

    static let contextKey = "personalContext"
    static let rulesKey = "personalRules"
    static let learnModeKey = "learnMode"

    /// Context: what Merlin should always know about you. Goes in the system prompt of every chat.
    var personalContext: String {
        get { defaults.string(forKey: Self.contextKey) ?? "" }
        set { defaults.set(newValue, forKey: Self.contextKey) }
    }

    /// Rules: how Merlin must always answer. Goes in the system prompt of every chat.
    var personalRules: String {
        get { defaults.string(forKey: Self.rulesKey) ?? "" }
        set { defaults.set(newValue, forKey: Self.rulesKey) }
    }

    /// "Delete chat when I close it": clicking × on a chat moves it to the Bin instead of keeping it in the Library.
    /// Off by default. Starred chats stay, and a chat with no answer was never saved, so there is nothing to move.
    var deleteChatOnClose: Bool {
        get { defaults.object(forKey: "deleteChatOnClose") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "deleteChatOnClose") }
    }

    /// Library rules: standing instructions for the Library Assistant. Goes in its prompt (never in a chat's).
    /// Routines: one per line, "name: step; step; …" (see `Routine`).
    static let routinesKey = "assistantRoutines"
    var routines: String {
        get { defaults.string(forKey: Self.routinesKey) ?? "" }
        set { defaults.set(newValue, forKey: Self.routinesKey) }
    }

    static let libraryRulesKey = "libraryRules"
    var libraryRules: String {
        get { defaults.string(forKey: Self.libraryRulesKey) ?? "" }
        set { defaults.set(newValue, forKey: Self.libraryRulesKey) }
    }

    // Hard locks: the Library Assistant's code refuses what a lock forbids, whatever the prompt or the model says.
    static let lockRenameKey = "lockRenameLockedTitles"
    static let lockAskMoveKey = "lockAskBeforeMoving"

    /// The Assistant never renames a chat (or screenshot) whose title is locked, i.e. one you named yourself.
    var lockRenameLockedTitles: Bool {
        get { defaults.object(forKey: Self.lockRenameKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.lockRenameKey) }
    }

    /// The Assistant shows what it would move between sectors and waits for Apply.
    var lockAskBeforeMoving: Bool {
        get { defaults.object(forKey: Self.lockAskMoveKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.lockAskMoveKey) }
    }

    /// Starred chats are never deleted. Always on: Library.delete refuses them, so this can't be turned off.
    static let lockKeepStarred = true

    /// Learn mode: answers highlight the few key words to remember (the model is asked to mark them ==like this==, and the
    /// answer view draws them highlighted). Toggled in the popup's footer and remembered for the next chat.
    var learnMode: Bool {
        get { defaults.bool(forKey: Self.learnModeKey) }
        set { defaults.set(newValue, forKey: Self.learnModeKey) }
    }

    /// Chats are saved to the History (on this Mac) so you can find them later. Turn off to keep nothing.
    var saveHistory: Bool {
        get { defaults.object(forKey: "saveHistory") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "saveHistory") }
    }

    /// Kept notes are also written as Markdown files in Documents/Merlin Notes.
    /// When a chat is closed, Claude gives it a better name and sector (unless you named or filed it yourself).
    var nameChatsOnClose: Bool {
        get { defaults.object(forKey: "nameChatsOnClose") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "nameChatsOnClose") }
    }

    var mirrorNotes: Bool {
        get { defaults.object(forKey: "mirrorNotes") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "mirrorNotes") }
    }


    /// Chats stay on screen, as many as you like at once, until you close or minimize them yourself: clicking elsewhere or
    /// leaving one alone doesn't put it away. Off = the old way (one chat at a time, tidied away when you click off it).
    var chatsStayOpen: Bool {
        get { defaults.object(forKey: "chatsStayOpen") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "chatsStayOpen") }
    }

    /// Every screenshot you take (⌘⇧3/4/5 or Tab+\) is saved to the Screenshots part of the dashboard and labeled by what's in it.
    var saveScreenshots: Bool {
        get { defaults.object(forKey: "saveScreenshots") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "saveScreenshots") }
    }

    /// When Merlin last looked at the screenshots folder, so one taken while Merlin was closed is still picked up.
    var lastScreenshotScan: Date? {
        get { defaults.object(forKey: "lastScreenshotScan") as? Date }
        set { defaults.set(newValue, forKey: "lastScreenshotScan") }
    }

    // MARK: Library settings (LibrarySettingsView). The defaults match how the Library behaved before they existed.

    /// What the Library shows when it opens.
    var libraryDefaultView: LibraryDefaultView {
        get { LibraryDefaultView(rawValue: defaults.string(forKey: "libraryDefaultView") ?? "") ?? .desk }
        set { defaults.set(newValue.rawValue, forKey: "libraryDefaultView") }
    }

    /// The view the Library was on when it was last closed (used by "Last used"). A free-form key the window owns.
    var libraryLastView: String {
        get { defaults.string(forKey: "libraryLastView") ?? "" }
        set { defaults.set(newValue, forKey: "libraryLastView") }
    }

    var libraryRowDensity: LibraryRowDensity {
        get { LibraryRowDensity(rawValue: defaults.string(forKey: "libraryRowDensity") ?? "") ?? .comfortable }
        set { defaults.set(newValue.rawValue, forKey: "libraryRowDensity") }
    }

    /// Show the first line of the answer under each title in the list.
    var libraryShowPreviews: Bool {
        get { defaults.object(forKey: "libraryShowPreviews") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "libraryShowPreviews") }
    }

    /// Items in the Bin are deleted for good after this many days. 0 = never.
    var binAutoEmptyDays: Int {
        get { defaults.object(forKey: "binAutoEmptyDays") as? Int ?? 30 }
        set { defaults.set(newValue, forKey: "binAutoEmptyDays") }
    }

    /// Screenshots kept with chats are deleted after this many days. 0 = keep them.
    var screenshotRetentionDays: Int {
        get { defaults.object(forKey: "screenshotRetentionDays") as? Int ?? 0 }
        set { defaults.set(newValue, forKey: "screenshotRetentionDays") }
    }

    /// How many agents (open and minimized chats) can exist at once.
    let maxAgents = 10

    /// Apps where Merlin never looks at selections (password managers, the Dock).
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
