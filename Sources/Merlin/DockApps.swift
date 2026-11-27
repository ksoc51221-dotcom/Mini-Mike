import AppKit

/// One app that can sit in the dock row.
struct DockApp: Identifiable, Equatable, Codable {
    let bundleID: String
    var name: String
    var id: String { bundleID }
}

/// What the dock needs from the system, so tests can swap in a fake.
protocol DockWorkspace {
    func url(forBundleID id: String) -> URL?
    func open(_ url: URL)
    func installedApps() -> [DockApp]
    func icon(for url: URL) -> NSImage
}

struct LiveDockWorkspace: DockWorkspace {
    func url(forBundleID id: String) -> URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) }

    func open(_ url: URL) { NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil) }

    func icon(for url: URL) -> NSImage { NSWorkspace.shared.icon(forFile: url.path) }

    func installedApps() -> [DockApp] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
        let roots = ["/Applications", "/Applications/Utilities", "/System/Applications", home]
        var byID: [String: DockApp] = [:]
        for root in roots {
            guard let names = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for file in names where file.hasSuffix(".app") {
                let path = (root as NSString).appendingPathComponent(file)
                guard let bundle = Bundle(path: path), let id = bundle.bundleIdentifier, id != "com.kien.merlin" else { continue }
                if byID[id] != nil { continue }
                let info = bundle.infoDictionary ?? [:]
                let name = (bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
                    ?? (info["CFBundleDisplayName"] as? String)
                    ?? (info["CFBundleName"] as? String)
                    ?? (file as NSString).deletingPathExtension
                byID[id] = DockApp(bundleID: id, name: name)
            }
        }
        return byID.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// The pinned apps (saved as JSON in UserDefaults) and the cached list of installed apps.
final class DockAppStore: ObservableObject {
    static let shared = DockAppStore()
    /// 20 apps (2026-11-27, Merlin): 10 places show on the arc; the rest wait behind the disc and come round on a scroll.
    static let maxPinned = 20
    static let defaultsKey = "dockPinnedApps"
    static let claudeBundleID = "com.anthropic.claudefordesktop"

    @Published private(set) var pinned: [DockApp]
    @Published private(set) var installed: [DockApp] = []

    private let defaults: UserDefaults
    private let workspace: DockWorkspace
    private var loading = false
    private var loaded = false
    private var icons: [String: NSImage] = [:]

    init(defaults: UserDefaults = .standard, workspace: DockWorkspace = LiveDockWorkspace()) {
        self.defaults = defaults
        self.workspace = workspace
        if let data = defaults.data(forKey: Self.defaultsKey), let saved = try? JSONDecoder().decode([DockApp].self, from: data) {
            pinned = Array(saved.prefix(Self.maxPinned))
        } else if workspace.url(forBundleID: Self.claudeBundleID) != nil {
            pinned = [DockApp(bundleID: Self.claudeBundleID, name: "Claude")]
        } else {
            pinned = []
        }
    }

    func loadInstalled() {
        guard !loaded, !loading else { return }
        loading = true
        let ws = workspace
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let apps = ws.installedApps()
            DispatchQueue.main.async {
                guard let self else { return }
                self.installed = apps
                self.loaded = true
                self.loading = false
            }
        }
    }

    /// The installed apps now: the cached list, or one scan on this thread the first time (a voice command can come
    /// before the dock ever loaded it).
    func installedNow() -> [DockApp] {
        if loaded { return installed }
        let apps = workspace.installedApps()
        installed = apps
        loaded = true
        return apps
    }

    func isPinned(_ bundleID: String) -> Bool { pinned.contains { $0.bundleID == bundleID } }

    var canPin: Bool { pinned.count < Self.maxPinned }

    @discardableResult
    func pin(_ app: DockApp) -> Bool {
        guard canPin, !isPinned(app.bundleID) else { return false }
        pinned.append(app)
        save()
        return true
    }

    func unpin(_ bundleID: String) {
        pinned.removeAll { $0.bundleID == bundleID }
        icons[bundleID] = nil
        save()
    }

    func open(_ app: DockApp) {
        guard let url = workspace.url(forBundleID: app.bundleID) else { return }
        workspace.open(url)
    }

    func icon(for app: DockApp) -> NSImage? {
        if let cached = icons[app.bundleID] { return cached }
        guard let url = workspace.url(forBundleID: app.bundleID) else { return nil }
        let image = workspace.icon(for: url)
        icons[app.bundleID] = image
        return image
    }

    private func save() {
        if let data = try? JSONEncoder().encode(pinned) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}
