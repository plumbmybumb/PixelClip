import SwiftUI
import PixelClipKit

/// Home: the one screen (docs/DESIGN.md ▸ Home). The clip's status, what's on it now (with Undo), the
/// four verbs, the Extras and the last things sent.
struct HomeView: View {
    @Environment(Router.self) private var router
    @Environment(ClipSession.self) private var session
    @Environment(Sender.self) private var sender
    @Environment(\.zoomNamespace) private var zoom

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        ScrollView {
            // Fits one iPhone screen (390×844 and up) down to the Extras at the default text size; only
            // the Recent strip may be below the fold. Larger text scrolls.
            VStack(alignment: .leading, spacing: typeSize.isAccessibilitySize ? 18 : 12) {
                header
                nowSection
                verbs
                ExtrasRow()
                RecentStrip()
            }
            .padding(.horizontal, 16)
            .padding(.top, 2)
            .padding(.bottom, 32)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .background(Z2.ground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        // The send-status capsule floats over Home from AppRoot (so it also shows right after a sheet closes).
        // The status line: a short Bluetooth look now and every 30 s (10 s while a send waits; never a
        // permission prompt), and what the clip plays now over a link that's up.
        .task {
            while !Task.isCancelled {
                await session.peekNearby()
                await session.refreshStatusIfLinked()
                try? await Task.sleep(for: sender.pending != nil ? Sender.lookEvery : .seconds(30))
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("PixelClip").font(.title.bold()).foregroundStyle(Z2.text)
                    .accessibilityAddTraits(.isHeader)
                StatusLine()
            }
            Spacer(minLength: 8)
            Button { router.open(.settings) } label: {
                Image(systemName: "gearshape")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 44, height: 44)
                    .background(Z2.card, in: .circle)
            }
            .buttonStyle(Z2Press(scale: 0.92))
            .accessibilityLabel("Settings")
            .accessibilityIdentifier("settingsButton")
        }
    }

    // MARK: Now

    private var nowSection: some View {
        VStack(spacing: 6) {
            Z2ClipFrame { NowPreview() }
            HStack(spacing: 10) {
                Text(nowLine).font(.footnote).foregroundStyle(Z2.secondary).lineLimit(1)
                    .accessibilityIdentifier("nowLine")
                if NowOnClip.shared.canUndo {
                    Button { sender.undo() } label: {
                        Text("Undo")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 32)
                            .background(Z2.card, in: .capsule)
                            .overlay { Capsule().strokeBorder(Z2.border, lineWidth: 1) }
                            .contentShape(.capsule)
                    }
                    .buttonStyle(Z2Press(scale: 0.94))
                    .accessibilityLabel("Undo")
                    .accessibilityHint("Puts back what was on the clip before")
                    .accessibilityIdentifier("homeUndo")
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity)
            .animation(Z2.spring, value: NowOnClip.shared.canUndo)
            if case .oracle(let o)? = NowOnClip.shared.item?.content {
                OracleButtons()
                    .transition(.opacity)
                // The sentence, larger than the clip shows it, once the row is drawn (§5f.1).
                OracleReadingCard(oracleID: o.libraryKey)
            }
        }
    }

    /// "On the clip now · playlist · Tarot" when the clip has said what it plays, else Now's title.
    private var nowLine: String {
        if let r = ClipReported.current(session: session) {
            return "On the clip now" + (r.fromPlaylist ? " · playlist" : "") + " · " + r.name
        }
        return NowOnClip.shared.item.map { "On the clip now · \($0.title)" } ?? "On the clip now"
    }

    // MARK: The four verbs

    private var verbs: some View {
        return Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                VerbTile(title: "Send", subtitle: "a photo, video or GIF", systemImage: "photo", prominent: true) {
                    router.picking = .send
                }
                .accessibilityIdentifier("tileSend")
                VerbTile(title: "Draw", subtitle: "doodle on the clip", systemImage: "pencil") {
                    router.open(.draw(.send))
                }
                .accessibilityIdentifier("tileDraw")
            }
            GridRow {
                VerbTile(title: "Write", subtitle: "a message on the clip", systemImage: "textformat") {
                    router.open(.write(.send))
                }
                .accessibilityIdentifier("tileWrite")
                VerbTile(title: "Playlist", subtitle: PlaylistStore.shared.tileLine, systemImage: "moon") {
                    router.open(.playlist)
                }
                .accessibilityIdentifier("tilePlaylist")
            }
        }
    }
}

/// The Tarot is on the clip (§5f.8): on waits **Arm** (like a press of the clip's button), once armed **Deal**
/// (like the shake) and Back (disarm); while a draw shows, Back and Turn (the clip's double-tap and press). Over
/// Bluetooth when the clip is near; never repeated over Wi‑Fi.
private struct OracleButtons: View {
    @Environment(ClipSession.self) private var session
    @Environment(Router.self) private var router
    @State private var busy = false
    @State private var lastDraw: Date?
    @State private var armedAt: Date?
    @State private var taps = 0

    var body: some View {
        HStack(spacing: 10) {
            switch phase {
            case .waits:
                button("Arm", systemImage: "hand.tap", id: "oracleDraw") { await session.oracleTurn() }
            case .armed:
                button("Deal", systemImage: "sparkles", id: "oracleDraw") { await session.oracleDraw() }
                button("Back", systemImage: "arrow.uturn.backward", id: "oracleBack") { await session.oracleBack() }
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            case .drawing:
                EmptyView()
            }
            if showsTurn {
                // §5f.3: the clip's double-tap (`POST /oracle/back`).
                button("Back", systemImage: "arrow.uturn.backward", id: "oracleBack") { await session.oracleBack() }
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
            if showsTurn {
                button("Turn", systemImage: "arrow.turn.down.right", id: "oracleTurn") { await session.oracleTurn() }
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .animation(Z2.spring, value: showsTurn)
        .animation(Z2.spring, value: phase)
        .sensoryFeedback(.impact(weight: .medium), trigger: taps)
        // On the virtual clip, shaking this iPhone shakes the clip.
        .task(id: session.useVirtual) {
            guard session.useVirtual else { return }
            DeviceTilt.shared.start()
            defer { DeviceTilt.shared.stop() }
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
        }
    }

    private enum Phase { case waits, armed, drawing }

    /// Where the draw is: what the clip says, else what this phone did last (within the idle timeout).
    private var phase: Phase {
        if let o = session.oracleNow {
            switch o.state {
            case .waits: return .waits
            case .armed: return .armed
            default: return .drawing
            }
        }
        let recent = { (d: Date?) in d.map { Date().timeIntervalSince($0) < 300 } ?? false }
        if recent(lastDraw), (armedAt ?? .distantPast) <= (lastDraw ?? .distantPast) { return .drawing }
        return recent(armedAt) ? .armed : .waits
    }

    /// A card is up (the clip says so), or one was drawn in the last few minutes.
    private var showsTurn: Bool {
        if let o = session.oracleNow { return o.cardShowing }
        return phase == .drawing
    }

    private func button(_ title: String, systemImage: String, id: String, _ op: @escaping () async -> ClipSession.Ask) -> some View {
        Button {
            guard !busy else { return }
            busy = true
            taps += 1
            Task {
                let r = await op()
                busy = false
                switch r {
                case .asked:
                    if id == "oracleDraw" {
                        if title == "Arm" { armedAt = Date() } else { lastDraw = Date() }
                    } else if id == "oracleBack", phase == .armed {
                        armedAt = nil
                    }
                case .notShowing: router.show("The clip isn’t showing the Tarot right now", systemImage: "rectangle.portrait")
                case .failed: router.show("Can’t find the clip, is it on?", systemImage: "exclamationmark.triangle.fill")
                }
            }
        } label: {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .background(Z2.card, in: .capsule)
                .overlay { Capsule().strokeBorder(Z2.border, lineWidth: 1) }
                .contentShape(.capsule)
        }
        .buttonStyle(Z2Press(scale: 0.94))
        .accessibilityIdentifier(id)
    }
}

/// One of the four tiles: ~88 pt, the icon left of the title and subtitle (above them at the largest text
/// sizes), 20 pt corners; Send is accent-filled.
private struct VerbTile: View {
    let title: String
    let subtitle: String
    let systemImage: String
    var prominent = false
    let action: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Button(action: action) {
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                                                      : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
            layout {
                Image(systemName: systemImage)
                    .font(.title2.weight(.regular))
                    .foregroundStyle(prominent ? Z2.onAccent : Color.accentColor)
                    .frame(minWidth: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.title3.bold()).foregroundStyle(prominent ? Z2.onAccent : Z2.text)
                        .lineLimit(1).minimumScaleFactor(0.8)
                    Text(subtitle).font(.footnote).foregroundStyle(prominent ? Z2.onAccentSecondary : Z2.secondary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: typeSize.isAccessibilitySize ? 120 : 88, alignment: .leading)
            .background(prominent ? Color.accentColor : Z2.card, in: .rect(cornerRadius: 20, style: .continuous))
            .contentShape(.rect(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(Z2Press())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(subtitle)")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Status

/// "My clip · nearby · 82%" with a green dot, or "can't find the clip, is it on?" with a grey one.
struct StatusLine: View {
    @Environment(ClipSession.self) private var session
    @Environment(Sender.self) private var sender

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(isNear ? Z2.nearby : Z2.away).frame(width: 8, height: 8).accessibilityHidden(true)
            Text(line).font(.footnote).foregroundStyle(Z2.secondary).lineLimit(2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("statusLine")
    }

    private var isNear: Bool { session.isNearby }

    private var line: String {
        if sender.isSending { return "\(session.displayName) · sending…" }
        if sender.pending != nil && !isNear { return "waiting for the clip · looking every 10 s" }
        let status = session.statusLine
        // "My clip · nearby · 82%": the clip's name before what it's doing.
        return isNear || sender.isSending ? "\(session.displayName) · \(status)" : status
    }
}

// MARK: - Now preview

/// What the clip shows now: the virtual clip's live panel in the simulator, else the Now item.
struct NowPreview: View {
    @Environment(ClipSession.self) private var session

    var body: some View {
        Group {
            if session.useVirtual, let screen = session.screen {
                ClipScreenPreview(frames: screen, level: max(session.screenLevel, 0.6), glow: true, bezel: false,
                                  flipped: session.screenFlipped, accessibilityLabel: label)
            } else if let r = ClipReported.current(session: session) {
                // What the clip said it plays (the rotation's item while the playlist is on).
                ContentPreview(content: r.content, bezel: false, glow: true, playing: true)
            } else if let content = NowOnClip.shared.item?.content {
                ContentPreview(content: content, bezel: false, glow: true, playing: true)
            } else {
                ClipScreenPreview(frames: nil, glow: false, bezel: false, accessibilityLabel: "Nothing on the clip yet")
                    .overlay { Text("Nothing yet").font(.footnote).foregroundStyle(.white.opacity(0.4)) }
            }
        }
        .accessibilityIdentifier("nowPreview")
    }

    private var label: String {
        if let r = ClipReported.current(session: session) { return "On the clip now\(r.fromPlaylist ? ", from the playlist" : ""): \(r.name)" }
        return NowOnClip.shared.item.map { "On the clip now: \($0.title)" } ?? "The clip’s screen"
    }
}

/// What the clip last said it plays (`/status.playlist.current`, heard in the last 15 minutes), matched to
/// Now or a playlist entry; nil when it hasn't been heard (Home then shows Now).
@MainActor
struct ClipReported {
    var content: MomentContent
    var name: String
    /// It's the playlist's (the rotation), not Now.
    var fromPlaylist: Bool

    static let freshFor: TimeInterval = 15 * 60

    static func current(session: ClipSession, now: Date = Date()) -> ClipReported? {
        guard let current = session.status?.playlist.current, let at = session.lastUpdated,
              now.timeIntervalSince(at) < freshFor else { return nil }
        return match(current, now: NowOnClip.shared.item, entries: PlaylistStore.shared.entries, playlistOn: PlaylistStore.shared.isOn)
    }

    static func match(_ current: String, now: NowItem?, entries: [PlaylistEntry], playlistOn: Bool) -> ClipReported? {
        if let n = now, n.content.clipCurrentID == current {
            return ClipReported(content: n.content, name: n.title, fromPlaylist: false)
        }
        if let e = entries.first(where: { $0.content.clipCurrentID == current }) {
            return ClipReported(content: e.content, name: e.name, fromPlaylist: e.at == nil && playlistOn)
        }
        return nil
    }
}

// MARK: - Extras

struct ExtrasRow: View {
    @Environment(Router.self) private var router
    @Environment(\.zoomNamespace) private var zoom

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Z2SectionLabel(text: "Extras")
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(Extra.allCases) { extra in
                        Button { router.extra = ExtraRequest(extra: extra) } label: {
                            VStack(alignment: .leading, spacing: 0) {
                                ExtraGlyph(extra: extra)
                                Spacer(minLength: 4)
                                Text(extra.title).font(.subheadline.weight(.semibold)).foregroundStyle(Z2.text).lineLimit(1)
                            }
                            .padding(10)
                            .frame(width: 100, height: 66, alignment: .leading)
                            .background(Z2.card, in: .rect(cornerRadius: 16, style: .continuous))
                            .contentShape(.rect(cornerRadius: 16, style: .continuous))
                        }
                        .buttonStyle(Z2Press(scale: 0.95))
                        .zoomSource(extra.rawValue, zoom)
                        .accessibilityLabel(extra.title)
                        .accessibilityIdentifier("extra.\(extra.rawValue)")
                    }
                }
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        }
    }
}

/// The little mark on each Extra card.
struct ExtraGlyph: View {
    let extra: Extra
    var size: CGFloat = 22

    var body: some View {
        Group {
            switch extra {
            case .tarot:
                // A little card standing up, its border in the accent.
                RoundedRectangle(cornerRadius: size * 0.1, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .frame(width: size * 0.62, height: size)
                    .overlay { Image(systemName: "sparkle").font(.system(size: size * 0.36, weight: .semibold)).foregroundStyle(Color.accentColor) }
                    .frame(width: size, height: size)
            case .scenes: icon("water.waves")
            case .loops: icon("square.grid.2x2")
            case .reader: icon("text.book.closed")
            }
        }
        .accessibilityHidden(true)
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: size * 0.82, weight: .medium)).foregroundStyle(Color.accentColor)
            .frame(width: size, height: size)
    }
}

// MARK: - Recent

/// The last things sent (the Library, invisible as a concept): tap to send again, long-press to remove.
struct RecentStrip: View {
    @Environment(LibraryStore.self) private var library
    @Environment(Router.self) private var router
    @Environment(\.zoomNamespace) private var zoom
    @AppStorage("recents.hidden.v1") private var hiddenRaw = ""

    private var hidden: Set<String> { Set(hiddenRaw.split(separator: ",").map(String.init)) }

    private var items: [LibraryItem] {
        let h = hidden
        return library.items.filter { !h.contains($0.id) && $0.isListed }.sorted { $0.updatedAt > $1.updatedAt }.prefix(12).map { $0 }
    }

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Z2SectionLabel(text: "Recent")
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(items) { item in
                            Button { router.resend = item.id } label: {
                                LibraryItemPreview(id: item.id, bezel: false, playing: false)
                                    .frame(width: 110)
                                    .clipShape(.rect(cornerRadius: 8, style: .continuous))
                            }
                            .buttonStyle(Z2Press(scale: 0.95))
                            .zoomSource("recent-\(item.id)", zoom)
                            .contextMenu {
                                Button(role: .destructive) { remove(item) } label: {
                                    Label("Remove from recents", systemImage: "minus.circle")
                                }
                            } preview: {
                                LibraryItemPreview(id: item.id, bezel: false, playing: true)
                                    .frame(width: 300)
                                    .environment(library)
                            }
                            .accessibilityLabel(item.name)
                            .accessibilityHint("Send it again")
                            .accessibilityAction(named: "Remove from recents") { remove(item) }
                            .accessibilityIdentifier("recent.\(item.id)")
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
            }
        }
    }

    /// Hidden at once, with Undo for 5 s; then the library copy goes too, unless the clip or the
    /// playlist still uses it.
    private func remove(_ item: LibraryItem) {
        var h = hidden
        h.insert(item.id)
        hiddenRaw = h.sorted().joined(separator: ",")
        let id = item.id
        let flag = UndoFlag()
        router.show("Removed from recents", systemImage: "minus.circle", undo: {
            flag.undone = true
            var h = Set(UserDefaults.standard.string(forKey: "recents.hidden.v1")?.split(separator: ",").map(String.init) ?? [])
            h.remove(id)
            UserDefaults.standard.set(h.sorted().joined(separator: ","), forKey: "recents.hidden.v1")
        })
        let lib = library
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5.5))
            guard !flag.undone else { return }
            let used = NowOnClip.shared.item?.content.assetID == id
                || PlaylistStore.shared.entries.contains { $0.content.assetID == id }
            if !used { lib.delete(id) }
        }
    }
}

/// Set when a toast's Undo was tapped (checked by the delayed part of a removal).
@MainActor final class UndoFlag {
    var undone = false
}
