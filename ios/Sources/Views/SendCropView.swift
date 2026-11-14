import SwiftUI
import PixelClipKit

/// Send ▸ the crop screen (docs/DESIGN.md ▸ Send): the picked (or shared) photo, video or GIF under the
/// clip-shaped frame. Drag and pinch it into place; a video or Live Photo gets a trim bar above the frame
/// (a few seconds, looping on the clip); one switch shows the whole photo (fit, black bars). Then Send
/// to the clip, or add it to the playlist instead.
struct SendCropView: View {
    let mode: ComposeMode
    @Environment(LibraryStore.self) private var library
    @Environment(Router.self) private var router
    @Environment(Sender.self) private var sender
    @State private var model: EditorModel
    @State private var saving = false

    init(media: ImportedMedia, mode: ComposeMode) {
        self.mode = mode
        _model = State(initialValue: EditorModel(media: media))
    }

    var body: some View {
        VStack(spacing: 16) {
            if model.isAnimated { trimBar }
            VStack(spacing: 10) {
                Text("Drag and pinch the photo into the frame")
                    .font(.footnote).foregroundStyle(Z2.secondary).multilineTextAlignment(.center)
                CropCanvas(model: model)
                    .frame(height: 240)
                    .background(Color(white: 0.06), in: .rect(cornerRadius: 14, style: .continuous))
                    .clipShape(.rect(cornerRadius: 14, style: .continuous))
                    .accessibilityIdentifier("cropCanvas")
            }
            Toggle(isOn: Binding(get: { wholePhoto }, set: { showWhole($0) })) {
                Text("Show the whole photo").font(.body).foregroundStyle(Z2.text)
            }
            .tint(Color.accentColor)
            .z2Card(radius: 18, padding: 16)
            .accessibilityIdentifier("wholePhotoToggle")
            if let warning {
                Label(warning, systemImage: "exclamationmark.circle")
                    .font(.footnote).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
            Z2SendButtons(mode: mode, working: saving, disabled: !ready, send: { save(toPlaylist: false) },
                          addToPlaylist: { save(toPlaylist: true) })
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .z2Screen("Send")
        .sensoryFeedback(.success, trigger: saving) { was, now in was && !now }
    }

    // MARK: Pieces

    private var ready: Bool { !model.sourceImages.isEmpty && model.preparing == nil && !model.isOverBudget }

    /// The frame shows the whole picture (fit) rather than filling the screen.
    private var wholePhoto: Bool { abs(model.transform.scale - model.fitScale) < 0.0005 && model.fitScale < model.fillScale - 0.0005 }

    private func showWhole(_ on: Bool) {
        CropAnimator.shared.animate(model, to: CropTransform(scale: on ? model.fitScale : model.fillScale))
    }

    private var warning: String? {
        if let error = model.error { return error }
        if model.isOverBudget { return "Too long for the clip: trim it to a few seconds." }
        return nil
    }

    private var trimBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(model.preparing ?? "Plays on a loop")
                    .font(.footnote).foregroundStyle(Z2.secondary)
                Spacer()
                Text(String(format: "%.1f s", model.trimEnd - model.trimStart))
                    .font(.footnote.weight(.semibold).monospacedDigit()).foregroundStyle(Z2.text)
                    .contentTransition(.numericText())
            }
            RangeSlider(lower: $model.trimStart, upper: $model.trimEnd, bounds: 0...max(model.sourceDuration, 0.1), minimumSpan: 0.3)
                .frame(height: 36)
                .accessibilityIdentifier("trimBar")
        }
        .padding(.horizontal, 4)
    }

    // MARK: Saving

    private func save(toPlaylist: Bool) {
        saving = true
        Task {
            do {
                let rendered = try await model.renderForSave()
                let name = model.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let item = try library.add(rendered, name: name.isEmpty ? "Photo" : name, source: model.media.kind,
                                           original: model.media.original, originalExtension: model.media.originalExtension)
                saving = false
                if toPlaylist {
                    sender.addToPlaylist(.asset(item.id), name: item.name)
                } else {
                    sender.sendNow(.asset(item.id), title: item.name)
                }
                router.finish(mode)
            } catch {
                model.error = "Couldn’t get it ready. Make sure this iPhone has some free space, then try again."
                saving = false
            }
        }
    }
}

/// Two-thumb slider for trimming.
struct RangeSlider: View {
    @Binding var lower: Double
    @Binding var upper: Double
    let bounds: ClosedRange<Double>
    var minimumSpan: Double = 0.1

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width - 28
            let span = bounds.upperBound - bounds.lowerBound
            let x0 = (lower - bounds.lowerBound) / span * w
            let x1 = (upper - bounds.lowerBound) / span * w
            ZStack(alignment: .leading) {
                Capsule().fill(Z2.border).frame(height: 6).padding(.horizontal, 14)
                Capsule().fill(Color.accentColor).frame(width: max(0, x1 - x0), height: 6).offset(x: 14 + x0)
                thumb.offset(x: x0)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("range")).onChanged { v in
                        let value = bounds.lowerBound + Double(min(max(0, v.location.x - 14), w)) / w * span
                        lower = min(max(bounds.lowerBound, value), upper - minimumSpan)
                    })
                    .accessibilityElement()
                    .accessibilityLabel("Trim start")
                    .accessibilityValue(String(format: "%.1f seconds", lower))
                    .accessibilityAdjustableAction { dir in
                        lower = dir == .increment ? min(lower + 0.1, upper - minimumSpan) : max(bounds.lowerBound, lower - 0.1)
                    }
                thumb.offset(x: x1)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("range")).onChanged { v in
                        let value = bounds.lowerBound + Double(min(max(0, v.location.x - 14), w)) / w * span
                        upper = max(min(bounds.upperBound, value), lower + minimumSpan)
                    })
                    .accessibilityElement()
                    .accessibilityLabel("Trim end")
                    .accessibilityValue(String(format: "%.1f seconds", upper))
                    .accessibilityAdjustableAction { dir in
                        upper = dir == .increment ? min(bounds.upperBound, upper + 0.1) : max(upper - 0.1, lower + minimumSpan)
                    }
            }
            .frame(maxHeight: .infinity)
            .coordinateSpace(.named("range"))
        }
    }

    private var thumb: some View {
        Circle().fill(.white).frame(width: 28, height: 28).shadow(color: .black.opacity(0.3), radius: 4, y: 2)
    }
}
