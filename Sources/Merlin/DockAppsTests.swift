import AppKit

private final class FakeDockWorkspace: DockWorkspace {
    var urls: [String: URL] = [:]
    var opened: [URL] = []
    func url(forBundleID id: String) -> URL? { urls[id] }
    func open(_ url: URL) { opened.append(url) }
    func installedApps() -> [DockApp] { [] }
    func icon(for url: URL) -> NSImage { NSImage(size: NSSize(width: 1, height: 1)) }
}

extension FeatureTests {
    /// The dock's pinned apps: first-run default, saving, the cap, and opening. Headless: a fake workspace and a throwaway defaults suite.
    static func dockAppsChecks(_ check: (String, Bool) -> Void) {
        let suite = "merlin.dockapps.test"
        func fresh() -> UserDefaults {
            let d = UserDefaults(suiteName: suite)!
            d.removePersistentDomain(forName: suite)
            return d
        }
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

        let claudeID = "com.anthropic.claudefordesktop"
        let ws = FakeDockWorkspace()
        let withClaude = DockAppStore(defaults: fresh(), workspace: ws)
        check("dock apps: first run without Claude is empty", withClaude.pinned.isEmpty)
        ws.urls[claudeID] = URL(fileURLWithPath: "/Applications/Claude.app")
        let first = DockAppStore(defaults: fresh(), workspace: ws)
        check("dock apps: first run with Claude pins Claude", first.pinned.map(\.bundleID) == [claudeID])

        let d = fresh()
        let store = DockAppStore(defaults: d, workspace: FakeDockWorkspace())
        let notes = DockApp(bundleID: "com.apple.Notes", name: "Notes")
        let mail = DockApp(bundleID: "com.apple.mail", name: "Mail")
        check("dock apps: pin works", store.pin(notes) && store.pin(mail) && store.isPinned(notes.bundleID))
        check("dock apps: double pin rejected", !store.pin(notes) && store.pinned.count == 2)
        var again = DockAppStore(defaults: d, workspace: FakeDockWorkspace())
        check("dock apps: pins persist in a new store", again.pinned == [notes, mail])
        again.unpin(notes.bundleID)
        again = DockAppStore(defaults: d, workspace: FakeDockWorkspace())
        check("dock apps: unpin persists", again.pinned == [mail])

        let cappedDefaults = fresh()
        let capped = DockAppStore(defaults: cappedDefaults, workspace: FakeDockWorkspace())
        for i in 0..<DockAppStore.maxPinned { _ = capped.pin(DockApp(bundleID: "x.\(i)", name: "X\(i)")) }
        check("dock apps: cap at 20 (a 21st is refused)", DockAppStore.maxPinned == 20 && capped.pinned.count == 20 && !capped.canPin && !capped.pin(DockApp(bundleID: "x.extra", name: "Extra")) && capped.pinned.count == 20)
        let reloaded = DockAppStore(defaults: cappedDefaults, workspace: FakeDockWorkspace())
        check("dock apps: 20 pins save and load", reloaded.pinned == capped.pinned)

        let url = URL(fileURLWithPath: "/Applications/Notes.app")
        let openWs = FakeDockWorkspace()
        openWs.urls[notes.bundleID] = url
        let opener = DockAppStore(defaults: fresh(), workspace: openWs)
        opener.open(notes)
        check("dock apps: open calls the workspace once with the URL", openWs.opened == [url])
        opener.open(mail)
        check("dock apps: open of a missing app does nothing", openWs.opened.count == 1)
    }
}
