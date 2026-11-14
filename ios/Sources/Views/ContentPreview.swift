import SwiftUI
import PixelClipKit

// Small pieces shared by the app's screens: content thumbnails (Home, Recent, Playlist), swipe to
// remove outside a List, and the undo toast.

@MainActor
final class ContentThumbs {
    static let shared = ContentThumbs()
    private var cache: [String: ClipFrames] = [:]

    static func key(for content: MomentContent) -> String {
        switch content {
        case .asset(let id): "asset-\(id)"
        case .scene(let name, _): "scene-\(name)"
        case .reader(let text, let font, _): "reader-\(text)-\(font)"
        case .oracle(let o): "oracle-\(o.libraryKey)"
        case .words(let sheet, _): "words-\(sheet)"
        case .board(let b): "board-\(b.sheet)"
        }
    }

    func cached(_ content: MomentContent) -> ClipFrames? { cache[Self.key(for: content)] }

    func frames(for content: MomentContent) async -> ClipFrames? {
        let key = Self.key(for: content)
        if let hit = cache[key] { return hit }
        if case .reader(let text, let font, _) = content {
            // A word of the text in its typeface, as the clip paints it.
            guard let frame = await ReaderStore.shared.previewFrame(textID: text, fontID: font) else { return nil }
            let frames = ClipFrames(single: ClipRenderer.makeCGImage(frame))
            cache[key] = frames
            return frames
        }
        let frames: ClipFrames? = await Task.detached(priority: .userInitiated) { () -> ClipFrames? in
            switch content {
            case .asset, .oracle, .words, .board: return nil
            case .scene(let name, _):
                let frame = ClipRenderer.render(PlaceholderArt.scenePlaceholder(name), transform: CropTransform(scale: 1), adjustments: .neutral)
                return ClipFrames(single: ClipRenderer.makeCGImage(frame))
            case .reader:
                return nil
            }
        }.value
        if let frames { cache[key] = frames }
        return frames
    }
}

/// What a moment (or rotation extra) shows, as a clip screen.
struct ContentPreview: View {
    let content: MomentContent
    var bezel = false
    var glow = false
    var playing = false
    @State private var frames: ClipFrames?

    var body: some View {
        switch content {
        case .asset(let id):
            LibraryItemPreview(id: id, glow: glow, bezel: bezel, playing: playing)
        case .oracle(let o):
            LibraryItemPreview(id: o.libraryKey, glow: glow, bezel: bezel, playing: playing)
        case .words(let sheet, _):
            // The library decodes a sheet as the words resting along the bottom edge (the virtual clip's still).
            LibraryItemPreview(id: sheet, glow: glow, bezel: bezel, playing: playing)
        case .board(let b):
            // The header over the first rows, as the clip shows it at rest.
            LibraryItemPreview(id: b.sheet, glow: glow, bezel: bezel, playing: playing)
        case .scene(let name, let params):
            // Live scenes run on the clip; the app shows an animated illustration in their palette.
            SceneAnimation(scene: name, palette: { if case .string(let p)? = params["palette"] { p } else { nil } }(), bezel: bezel)
        default:
            ClipScreenPreview(frames: frames ?? ContentThumbs.shared.cached(content), glow: glow, bezel: bezel,
                              accessibilityLabel: ContentText.contentName(content))
                .task(id: ContentThumbs.key(for: content)) { frames = await ContentThumbs.shared.frames(for: content) }
        }
    }
}

enum ContentText {
    @MainActor static func contentName(_ content: MomentContent) -> String {
        switch content {
        case .asset: "Picture"
        case .scene(let name, let params):
            if case .string(let p)? = params["palette"] { "\(name.capitalized) · \(p)" } else { name.capitalized }
        case .reader(let text, _, _): ReaderStore.shared.document(clipTextID: text)?.title ?? "Reading"
        case .oracle: "Tarot"
        case .words(_, let text): text.isEmpty ? "Bouncing words" : "“\(text)” · bouncing"
        case .board: "Board"
        }
    }

    static func sceneSymbol(_ name: String) -> String {
        switch name {
        case "sand": "hourglass"
        case "water": "drop.fill"
        case "fire": "flame.fill"
        case "balls": "circle.grid.3x3.fill"
        case "snow": "snowflake"
        case "lava": "mountain.2.fill"
        default: "sparkles"
        }
    }

    /// "in 3 h 50 min", "in 40 s".
    static func countdown(to date: Date, now: Date) -> String {
        let s = Int(date.timeIntervalSince(now).rounded(.up))
        if s <= 0 { return "now" }
        if s < 60 { return "in \(s) s" }
        let m = (s + 59) / 60
        if m < 60 { return "in \(m) min" }
        return m % 60 == 0 ? "in \(m / 60) h" : "in \(m / 60) h \(m % 60) min"
    }
}

// MARK: - Swipe to delete (outside a List)

/// A horizontal-only pan: begins only when the finger moves more sideways than up/down, so the
/// page keeps scrolling vertically.
struct HorizontalPan: UIGestureRecognizerRepresentable {
    var onChange: (CGFloat) -> Void
    var onEnd: (CGFloat, CGFloat) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let g = UIPanGestureRecognizer()
        g.delegate = context.coordinator
        return g
    }

    func handleUIGestureRecognizerAction(_ g: UIPanGestureRecognizer, context: Context) {
        let dx = g.translation(in: g.view).x
        switch g.state {
        case .changed: onChange(dx)
        case .ended, .cancelled, .failed: onEnd(dx, g.velocity(in: g.view).x)
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let pan = g as? UIPanGestureRecognizer else { return false }
            let v = pan.velocity(in: pan.view)
            return abs(v.x) > abs(v.y) * 1.3
        }
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { false }
    }
}

/// Swipe left to reveal Delete; a long swipe deletes at once (like a List row). Haptic on delete.
struct SwipeToDelete: ViewModifier {
    var enabled = true
    var onDelete: () -> Void
    @State private var offset: CGFloat = 0
    @State private var open = false
    @State private var deleted = 0
    private let reveal: CGFloat = 84

    func body(content: Content) -> some View {
        if enabled {
            ZStack(alignment: .trailing) {
                Button(role: .destructive) { commit() } label: {
                    Label("Delete", systemImage: "trash.fill")
                        .labelStyle(.iconOnly)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: max(reveal - 8, -offset - 8))
                        .frame(maxHeight: .infinity)
                        .background(.red, in: .rect(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .opacity(offset < -8 ? 1 : 0)
                .accessibilityHidden(true)
                content
                    .offset(x: offset)
                    .gesture(HorizontalPan(onChange: { dx in
                        offset = min(0, (open ? -reveal : 0) + dx)
                    }, onEnd: { dx, vx in
                        let final = (open ? -reveal : 0) + dx
                        if final < -220 || vx < -1400 { commit(); return }
                        withAnimation(.snappy) {
                            open = final < -reveal / 2
                            offset = open ? -reveal : 0
                        }
                    }))
                    .simultaneousGesture(TapGesture().onEnded {
                        if open { withAnimation(.snappy) { open = false; offset = 0 } }
                    }, isEnabled: open)
            }
            .sensoryFeedback(.impact(weight: .medium), trigger: deleted)
            .accessibilityAction(named: "Delete") { commit() }
        } else {
            content
        }
    }

    private func commit() {
        deleted += 1
        withAnimation(.snappy) { offset = -600 }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            onDelete()
            offset = 0
            open = false
        }
    }
}

/// "Removed “Birthday”" with Undo, for 5 seconds.
struct UndoToast: View {
    let text: String
    var onUndo: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "trash").foregroundStyle(.secondary)
            Text(text).font(.subheadline.weight(.semibold)).lineLimit(1)
            Spacer(minLength: 8)
            Button("Undo", action: onUndo).font(.subheadline.weight(.bold))
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 20)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
