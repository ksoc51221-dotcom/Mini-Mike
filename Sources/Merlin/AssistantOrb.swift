import AppKit
import SwiftUI

// MARK: - The orb

/// Merlin's spark in a glowing orb: it breathes, a ring turns around it and a bright point drifts along the ring.
/// It's the Assistant's button in the Library and in Settings. Still (and calm) with Reduce Motion.
struct AssistantOrb: View {
    var size: CGFloat = 30
    /// Brighter while the pointer is over it or its card is open.
    var lit = false
    /// Faster while the Assistant is working.
    var busy = false

    private var still: Bool { Motion.still || Motion.reduceMotion }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: still)) { context in
            let t = still ? 0.0 : context.date.timeIntervalSinceReferenceDate
            let speed = busy ? 2.2 : 1.0
            let pulse = still ? 0.6 : 0.5 + 0.5 * sin(t * speed * 2 * .pi / 3.2)
            let spin = still ? 0.0 : (t * speed * 360 / 9).truncatingRemainder(dividingBy: 360)
            orb(pulse: pulse, spin: spin)
        }
        .frame(width: size, height: size)
        .animation(Motion.still ? nil : .easeOut(duration: 0.25), value: lit)
        .accessibilityHidden(true)
    }

    /// How far the glow reaches past the disc. Callers give the orb a cell at least this wide so the glow never meets a box edge.
    static let glowScale: CGFloat = 1.45

    private func orb(pulse: Double, spin: Double) -> some View {
        let accent = Theme.accent.color
        let glow = (lit ? 0.55 : 0.32) * (0.7 + 0.3 * pulse)
        let ring = max(1.1, size * 0.045)
        return ZStack {
            // The disc, a faint accent wash over the canvas.
            Circle().fill(Theme.canvas.color)
                .overlay(Circle().fill(accent.opacity(0.08 + 0.06 * pulse)))
                .frame(width: size, height: size)
            // The ring, brightest at one end, turning.
            Circle()
                .strokeBorder(AngularGradient(colors: [accent, accent.opacity(0.06), accent.opacity(0.06), accent],
                                              center: .center), lineWidth: ring)
                .frame(width: size, height: size)
                .rotationEffect(.degrees(spin))
            // A bright point riding just inside the ring.
            Circle().fill(accent).frame(width: size * 0.09, height: size * 0.09)
                .offset(y: -size / 2 + ring + size * 0.05)
                .rotationEffect(.degrees(-spin * 1.6))
            // The spark, with room around it.
            SparkShape()
                .stroke(accent, style: StrokeStyle(lineWidth: ClaudeMark.lineWidth(radius: size * 0.23), lineCap: .round))
                .frame(width: size * 0.46, height: size * 0.46)
                .scaleEffect(0.95 + 0.08 * pulse)
                .rotationEffect(.degrees(spin * 0.35))
                .shadow(color: accent.opacity(0.55), radius: size * 0.08)
        }
        .frame(width: size, height: size)
        // The glow sits behind and never takes part in layout, so the orb's frame is the disc itself.
        .background(
            Circle()
                .fill(RadialGradient(colors: [accent.opacity(glow), accent.opacity(0)], center: .center,
                                     startRadius: size * 0.3, endRadius: size * (Self.glowScale / 2) * (0.92 + 0.08 * pulse)))
                .frame(width: size * Self.glowScale, height: size * Self.glowScale)
                .allowsHitTesting(false)
        )
    }
}

/// A press that answers on the way down: a slight settle in scale (none with Reduce Motion).
private struct OrbPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !Motion.reduceMotion && !Motion.still ? 0.98 : 1)
            .animation(Motion.still ? nil : Motion.animation(Motion.small), value: configuration.isPressed)
    }
}

/// The Assistant's row under Sectors in the Library, and at the foot of the settings list.
struct AssistantOrbRow: View {
    var open = false
    var busy = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                // A 24 pt orb in a 36 pt cell: its glow (1.45x) ends inside the cell, so nothing meets the row's edge.
                AssistantOrb(size: 24, lit: hover || open, busy: busy).frame(width: 36, height: 36)
                // One line at rest. While it works, a second line says so: the orb's faster spin alone is easy to miss,
                // and Reduce Motion stops it.
                VStack(alignment: .leading, spacing: 1) {
                    Text("Assistant").font(.geist(13, .medium)).foregroundStyle(Theme.ink.color).lineLimit(1)
                    if busy {
                        Text("Working…").font(.geist(12)).foregroundStyle(Theme.inkSecondary.color).lineLimit(1)
                            .transition(.opacity)
                    }
                }
                .animation(Motion.still ? nil : Motion.animation(Motion.small), value: busy)
                Spacer(minLength: 0)
            }
            .padding(.leading, 5).padding(.trailing, 10).frame(height: 52)
            // Like the nav rows above it: nothing at rest, a soft fill under the pointer, the selected fill while open.
            .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(open ? Theme.surfaceSelected.color : (hover ? Theme.surfaceRaised.color : Color.clear)))
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        }
        .buttonStyle(OrbPressStyle())
        .onHover { hover = $0 }
        .animation(Motion.still ? nil : .easeOut(duration: 0.15), value: hover)
        .help("Assistant: find, tidy, star, file, change settings or shortcuts")
        .accessibilityLabel("Assistant")
        .accessibilityValue(busy ? "Working" : "")
    }
}

/// "Settings" at the bottom of the sidebar: the same size and style as the Assistant row above it, with a gear where the orb is.
struct SidebarSettingsRow: View {
    var open = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "gearshape").font(.system(size: 13, weight: .regular))
                    .foregroundStyle(hover || open ? Theme.ink.color : Theme.inkSecondary.color)
                    .frame(width: 24, height: 24).frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Settings").font(.geist(13, .medium)).foregroundStyle(Theme.ink.color)
                    Text("Rules, storage, shortcuts").font(.geist(11.5))
                        .foregroundStyle(open ? Theme.inkSecondary.color : Theme.inkTertiary.color).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 5).padding(.trailing, 10).frame(height: 52)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(open ? Theme.surfaceSelected.color : (hover ? Theme.surfaceRaised.color : Color.clear)))
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        }
        .buttonStyle(OrbPressStyle())
        .onHover { hover = $0 }
        .animation(Motion.still ? nil : .easeOut(duration: 0.15), value: hover)
        .help("Settings")
        .accessibilityLabel("Settings")
    }
}

// MARK: - Commands

/// Everything the Assistant can do for you, as things to pick. `fill` ones need your words, so they open the text box.
struct AssistantCommand: Identifiable {
    let title: String
    let symbol: String
    let prompt: String
    var fill = false
    var id: String { title }
}

struct AssistantCommandGroup: Identifiable {
    let name: String
    let commands: [AssistantCommand]
    var id: String { name }
}

enum AssistantCommands {
    static let groups: [AssistantCommandGroup] = [
        .init(name: "Find and ask", commands: [
            .init(title: "Find chats…", symbol: "magnifyingglass", prompt: "Find my chats about ", fill: true),
            .init(title: "Library stats", symbol: "chart.bar", prompt: "How many chats, notes and screenshots do I have, and how many did I save this month?"),
            .init(title: "About Merlin", symbol: "info.circle", prompt: "What can Merlin do, and what are its shortcuts?"),
        ]),
        .init(name: "Tidy up", commands: [
            .init(title: "Star this week's chats", symbol: "star", prompt: "Star my chats from this week"),
            .init(title: "Star chats about…", symbol: "star", prompt: "Star my chats about ", fill: true),
            .init(title: "File chats under…", symbol: "folder", prompt: "Move my chats from this week to ", fill: true),
            .init(title: "New sector…", symbol: "plus.rectangle", prompt: "Create a sector called ", fill: true),
            .init(title: "Clear out old chats", symbol: "trash", prompt: "Delete chats older than 30 days that aren't starred"),
        ]),
        .init(name: "Change Merlin", commands: [
            .init(title: "Dark mode", symbol: "moon", prompt: "Switch Merlin to dark mode"),
            .init(title: "Light mode", symbol: "sun.max", prompt: "Switch Merlin to light mode"),
            .init(title: "Accent colour…", symbol: "paintpalette", prompt: "Make the accent colour ", fill: true),
            .init(title: "Change a shortcut…", symbol: "keyboard", prompt: "Change the shortcut for the Library to ", fill: true),
            .init(title: "Learn mode", symbol: "graduationcap", prompt: "Turn on Learn mode"),
            .init(title: "Local mode", symbol: "lock.laptopcomputer", prompt: "Turn on Local mode"),
            .init(title: "Stop saving screenshots", symbol: "camera.viewfinder", prompt: "Turn off saving screenshots"),
        ]),
    ]

    static var all: [AssistantCommand] { groups.flatMap(\.commands) }
}

/// Three quiet examples under the empty Assistant. Every command is only a sentence the text box understands too, so the
/// rest need no list: typing them works the same. Shown at once (the card opens often); hover is an opacity-only highlight.
struct AssistantExampleRows: View {
    let choose: (AssistantCommand) -> Void
    @State private var hovered: String?
    private static let titles = ["Find chats…", "Library stats", "Star this week's chats"]
    static var examples: [AssistantCommand] { titles.compactMap { t in AssistantCommands.all.first { $0.title == t } } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Self.examples) { command in
                Button { choose(command) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: command.symbol).font(.system(size: 12)).foregroundStyle(Theme.inkTertiary.color).frame(width: 18)
                        Text(command.title).font(.geist(13)).foregroundStyle(Theme.inkSecondary.color)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8).frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                        .fill(Theme.surfaceSelected.color).opacity(hovered == command.id ? 1 : 0))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    withAnimation(Motion.still ? nil : Motion.animation(Motion.small)) { hovered = inside ? command.id : (hovered == command.id ? nil : hovered) }
                }
                .accessibilityLabel(command.title.replacingOccurrences(of: "…", with: ""))
                .accessibilityHint(command.fill ? "Starts a request for you to finish" : "Runs it")
            }
        }
    }
}

// MARK: - The Library's card

/// The Assistant floating beside the Library's sidebar, over whatever the Library shows.
struct AssistantCard: View {
    let close: () -> Void
    @ObservedObject private var chat = AssistantChat.shared
    @Environment(\.colorScheme) private var scheme
    @State private var closeHover = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.container, style: .continuous)
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                AssistantOrb(size: 18, lit: true, busy: chat.busy).frame(width: 28, height: 28)
                Text("Assistant").font(.geist(13, .semibold)).foregroundStyle(Theme.ink.color)
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(closeHover ? Theme.ink.color : Theme.inkTertiary.color)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(closeHover ? Theme.surfaceRaised.color : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).onHover { closeHover = $0 }
                .animation(Motion.still ? nil : .easeOut(duration: 0.12), value: closeHover)
                .help("Close (Esc)").accessibilityLabel("Close the Assistant")
            }
            .padding(.leading, 14).padding(.trailing, 12).padding(.top, 14).padding(.bottom, 8)
            LibraryAssistantView(chat: chat, compact: true)
        }
        .frame(width: 430)
        .background(shape.fill(Theme.surface.color))
        .overlay(shape.strokeBorder(Theme.hairline.color, lineWidth: 1))
        .clipShape(shape)
        // Two soft shadows: a close one that seats the card, a wide one that lifts it. Lighter in light mode.
        .shadow(color: .black.opacity(scheme == .dark ? 0.30 : 0.08), radius: 1.5, y: 1)
        .shadow(color: .black.opacity(scheme == .dark ? 0.38 : 0.14), radius: 28, y: 14)
        // At most 560 tall; less in a short window (the conversation scrolls). The card is drawn inside this frame, so with
        // nothing said yet it hugs its contents, resting at the bottom beside the orb, instead of standing 560 tall half empty.
        .frame(maxHeight: 560, alignment: .bottom)
        .onExitCommand(perform: close)
    }
}

/// The orb row, watching the Assistant so the orb speeds up while it works.
struct AssistantOrbButton: View {
    var open = false
    let action: () -> Void
    @ObservedObject private var chat = AssistantChat.shared
    var body: some View { AssistantOrbRow(open: open, busy: chat.busy, action: action) }
}
