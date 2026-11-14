import SwiftUI
import PixelClipKit

/// The clip's AMOLED, emulated: true black, 536:240, softly rounded glass with a faint bezel,
/// and (in dark mode) the spill of light a lit OLED throws on its surroundings.
/// Frames must already be quantised RGB565 (decoded `.hca` or `ClipRenderer` output), so this
/// shows exactly what the clip shows. Animations play with their real per-frame timing; a strip
/// scrolls a 536-px window across itself at its `px_per_s`, with `gap_px` of black between repeats
/// (`StripScroller`, the same rule the virtual clip and the playback engine use).
struct ClipScreenPreview: View {
    var frames: ClipFrames?
    /// Panel brightness 0…1 (AMOLED dims by emitting less light: we darken, never grey out).
    var level: Double = 1
    var glow = true
    /// False shows the panel as switched off (e.g. during an upload session).
    var awake = true
    var bezel = true
    var playing = true
    /// The panel shows its frame turned 180° (PROTOCOL §4 Orientation; frames themselves stay upright).
    var flipped = false
    var accessibilityLabel: String = "Clip screen preview"

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let radius = w * 0.045
            let ring = bezel ? max(2, w * 0.014) : 0
            ZStack {
                if bezel {
                    RoundedRectangle(cornerRadius: radius + ring, style: .continuous)
                        .fill(Color(white: scheme == .dark ? 0.09 : 0.13))
                        .overlay {
                            RoundedRectangle(cornerRadius: radius + ring, style: .continuous)
                                .strokeBorder(LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.03)],
                                                             startPoint: .top, endPoint: .bottom), lineWidth: 0.75)
                        }
                }
                screen(radius: radius)
                    .padding(ring)
            }
            .background {
                if glow && scheme == .dark && awake, let img = frames?.images.first {
                    Image(decorative: img, scale: 1)
                        .resizable()
                        .rotationEffect(.degrees(flipped ? 180 : 0))
                        .scaleEffect(1.08)
                        .blur(radius: w * 0.07)
                        .opacity(0.55 * level)
                        .allowsHitTesting(false)
                }
            }
            .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.18), radius: 12, y: 8)
        }
        .aspectRatio(ClipCanvas.aspect, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isImage)
    }

    @ViewBuilder
    private func screen(radius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            Color.black
            if awake {
                Group {
                    if let strip = frames?.strip, let scroll = strip.scroll, playing, !reduceMotion {
                        TimelineView(.animation(minimumInterval: 1.0 / 60)) { ctx in
                            StripWindow(strip: strip.image, scroll: scroll, elapsed: ctx.date.timeIntervalSince(start))
                        }
                    } else if let frames, frames.isAnimated, playing, !reduceMotion {
                        TimelineView(.animation(minimumInterval: 1.0 / 60)) { ctx in
                            frameImage(frames.images[frames.index(at: ctx.date.timeIntervalSince(start))])
                        }
                    } else if let img = frames?.images.first {
                        frameImage(img)
                    }
                }
                // The panel turns the whole picture (MADCTL), so the preview turns the content.
                .rotationEffect(.degrees(flipped ? 180 : 0))
                .animation(reduceMotion ? nil : .smooth(duration: 0.4), value: flipped)
                // AMOLED brightness: less light, still true black. sqrt ≈ perceived brightness of a
                // linear PWM/current level.
                Color.black.opacity(1 - min(max(level, 0.04), 1).squareRoot())
            } else {
                Image(systemName: "wifi")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.18))
            }
        }
        .clipShape(shape)
        .overlay {
            // Glass: a whisper of reflection on the top edge.
            shape.strokeBorder(.white.opacity(0.06), lineWidth: 0.5)
        }
    }

    private func frameImage(_ img: CGImage) -> some View {
        Image(decorative: img, scale: 1)
            .resizable()
            .interpolation(.medium)
            .aspectRatio(contentMode: .fill)
    }
}

/// One moment of a scrolling strip: the copies visible after `elapsed` seconds, drawn in the
/// screen's 536-px coordinate space. With `loops` the preview replays the item's passes; without,
/// it repeats forever (what the clip does for a timed item).
private struct StripWindow: View {
    let strip: CGImage
    let scroll: PlaylistItem.Scroll
    let elapsed: TimeInterval

    var body: some View {
        Canvas(rendersAsynchronously: false) { gc, size in
            let scale = size.width / CGFloat(ClipCanvas.width)
            var t = Int(elapsed * 1000)
            var limit: Int?
            if scroll.loops != nil {
                let dur = StripScroller.durationMs(stripWidth: strip.width, scroll: scroll)
                t %= max(1, dur)
                limit = StripScroller.loops(scroll)
            }
            let xs = StripScroller.copies(offset: StripScroller.offsetPx(atMs: t, scroll: scroll), stripWidth: strip.width,
                                          scroll: scroll, limit: limit)
            let image = Image(decorative: strip, scale: 1).interpolation(.medium)
            for x in xs {
                gc.draw(image, in: CGRect(x: CGFloat(x) * scale, y: 0, width: CGFloat(strip.width) * scale, height: size.height))
            }
        }
    }
}

/// Loads an item's frames from the library and shows them.
struct LibraryItemPreview: View {
    let id: String
    var glow = false
    var bezel = true
    var playing = true
    @Environment(LibraryStore.self) private var library
    @State private var frames: ClipFrames?

    var body: some View {
        ClipScreenPreview(frames: frames ?? library.cachedFrames(id), glow: glow, bezel: bezel, playing: playing,
                          accessibilityLabel: library.item(id).map { "\($0.name), \($0.isStrip ? "scrolling" : ($0.isAnimation ? "animation" : "still"))" } ?? "")
            .task(id: "\(id)-\(library.revision)") {
                frames = await library.frames(for: id)
            }
    }
}
