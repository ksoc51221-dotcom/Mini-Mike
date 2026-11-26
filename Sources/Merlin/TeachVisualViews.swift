import AppKit
import AVKit
import SwiftUI
import WebKit

// MARK: - Where a chat's visuals are

private struct VisualsFolderKey: EnvironmentKey {
    static let defaultValue: URL? = nil
}

extension EnvironmentValues {
    /// The chat's Visuals folder (`TeachVisuals.folder`). An answer's <visual> tag names a file in it.
    var visualsFolder: URL? {
        get { self[VisualsFolderKey.self] }
        set { self[VisualsFolderKey.self] = newValue }
    }
}

/// The dark 3Blue1Brown background used only inside a visual.
/// The visual window's dark charcoal (the app's dark canvas, 60-30-10 since 2026-11-26).
let teachVisualBackground = Color(nsColor: Theme.canvas.dark)

/// A diagram or video from an answer's <visual> tag, full chat width.
struct TeachVisualView: View {
    let kind: TeachVisuals.Kind
    let file: String
    @Environment(\.visualsFolder) private var folder

    var body: some View {
        if let folder, FileManager.default.fileExists(atPath: folder.appendingPathComponent(file).path) {
            let url = folder.appendingPathComponent(file)
            switch kind {
            case .diagram: DiagramCard(url: url, folder: folder)
            case .video: VideoCard(url: url)
            }
        } else {
            Text(kind == .diagram ? "Diagram not found." : "Video not found.")
                .font(.geist(12)).foregroundStyle(Theme.inkTertiary.color)
        }
    }
}

// MARK: - Diagram

private struct DiagramCard: View {
    let url: URL
    let folder: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SVGWebView(url: url, readAccess: folder)
                .aspectRatio(TeachVisuals.svgAspect(at: url), contentMode: .fit)
                .frame(maxWidth: .infinity)
                .background(teachVisualBackground)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
                // The web view takes clicks; this plain button on top opens the larger window.
                .overlay(Button { DiagramWindow.open(url: url, folder: folder) } label: {
                    Color.clear.contentShape(Rectangle())
                }.buttonStyle(.plain).help("Open larger"))
            HStack(spacing: 14) {
                Button("Save as PNG") { TeachVisualActions.savePNG(svg: url) }
                Button("Open in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            .buttonStyle(.plain)
            .font(.geist(12, .semibold))
            .foregroundStyle(Theme.inkSecondary.color)
        }
    }
}

/// A web view that shows one local SVG file: JavaScript off, every network load blocked by a content rule,
/// read access only to the chat's Visuals folder. It loads once; SwiftUI re-renders don't reload it.
struct SVGWebView: NSViewRepresentable {
    let url: URL
    let readAccess: URL

    final class Coordinator {
        var loaded: URL?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        view.setValue(false, forKey: "drawsBackground")
        view.allowsMagnification = false
        view.allowsBackForwardNavigationGestures = false
        load(into: view, context: context)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        if context.coordinator.loaded != url { load(into: view, context: context) }
    }

    private func load(into view: WKWebView, context: Context) {
        context.coordinator.loaded = url
        let url = url, folder = readAccess
        // Fail closed: nothing loads until the blocking rule is in place.
        TeachVisualActions.blockNetwork { rules in
            guard let rules else { return }
            view.configuration.userContentController.removeAllContentRuleLists()
            view.configuration.userContentController.add(rules)
            view.loadFileURL(url, allowingReadAccessTo: folder)
        }
    }
}

/// The larger diagram window (one per click; closing it frees it).
@MainActor
enum DiagramWindow {
    private static var open: [NSWindow] = []

    static func open(url: URL, folder: URL) {
        let aspect = TeachVisuals.svgAspect(at: url)
        let width: CGFloat = min(1280, (NSScreen.main?.visibleFrame.width ?? 1440) * 0.8)
        let size = NSSize(width: width, height: width / max(aspect, 0.2))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Diagram"
        window.isReleasedWhenClosed = false
        window.backgroundColor = Theme.canvas.dark
        window.contentView = NSHostingView(rootView: SVGWebView(url: url, readAccess: folder).background(teachVisualBackground))
        window.center()
        open.append(window)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { note in
            MainActor.assumeIsolated { open.removeAll { $0 === note.object as? NSWindow } }
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Video

private struct VideoCard: View {
    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PlayerView(player: player)
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .background(teachVisualBackground)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
            HStack(spacing: 14) {
                Button("Replay") {
                    player?.seek(to: .zero)
                    player?.play()
                }
                Button("Open in QuickTime") { TeachVisualActions.openInQuickTime(url) }
            }
            .buttonStyle(.plain)
            .font(.geist(12, .semibold))
            .foregroundStyle(Theme.inkSecondary.color)
        }
        .onAppear { if player == nil { player = AVPlayer(url: url) } }
        .onDisappear { player?.pause() }
    }
}

private struct PlayerView: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

// MARK: - While a visual is being made

/// "Rendering…" with a Cancel button, or the last error (with the install command when Manim is missing).
struct TeachVisualStatus: View {
    let stage: TeachVisuals.Stage?
    let error: TeachVisuals.Failure?
    let cancel: () -> Void
    let dismiss: () -> Void

    var body: some View {
        if let stage {
            HStack(spacing: 12) {
                ShimmerText(text: stage.text)
                Button("Cancel", action: cancel)
                    .buttonStyle(.plain)
                    .font(.geist(12, .semibold))
                    .foregroundStyle(Theme.inkSecondary.color)
            }
        } else if let error, error != .cancelled {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    if error == .manimMissing {
                        Text("Manim is not installed. Install it in Terminal, then try again:")
                        Text(TeachVisuals.installCommand).font(.geistMono(12)).textSelection(.enabled)
                    } else {
                        Text(error.message).textSelection(.enabled)
                    }
                }
                .font(.geist(12))
                .foregroundStyle(Theme.inkSecondary.color)
                Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.inkTertiary.color)
                    .help("Dismiss")
            }
        }
    }
}

// MARK: - Helpers

enum TeachVisualActions {
    @MainActor private static var compiled: WKContentRuleList?
    @MainActor private static var waiting: [(WKContentRuleList?) -> Void] = []

    /// Blocks every load except local files. Compiled once; nil if WebKit refuses it (then nothing is shown).
    nonisolated(unsafe) static var blockRules = #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}},{"trigger":{"url-filter":"^file:"},"action":{"type":"ignore-previous-rules"}}]"#

    @MainActor static func blockNetwork(_ ready: @escaping (WKContentRuleList?) -> Void) {
        if let compiled { return ready(compiled) }
        waiting.append(ready)
        guard waiting.count == 1 else { return }
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "merlin-visuals-offline", encodedContentRuleList: blockRules) { list, _ in
            MainActor.assumeIsolated {
                compiled = list
                let all = waiting
                waiting = []
                all.forEach { $0(list) }
            }
        }
    }

    static func openInQuickTime(_ url: URL) {
        let app = URL(fileURLWithPath: "/System/Applications/QuickTime Player.app")
        if FileManager.default.fileExists(atPath: app.path) {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// Draws the SVG 1920 px wide and saves it as a PNG where you choose.
    @MainActor static func savePNG(svg url: URL) {
        guard let png = pngData(svg: url) else { return NSSound.beep() }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Diagram.png"
        if panel.runModal() == .OK, let target = panel.url { try? png.write(to: target) }
    }

    /// The SVG as PNG data, 1920 px wide on the dark background (nil if it can't be drawn).
    static func pngData(svg url: URL) -> Data? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        let aspect = TeachVisuals.svgAspect(at: url)
        let size = NSSize(width: 1920, height: (1920 / max(aspect, 0.2)).rounded())
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        Theme.canvas.dark.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
