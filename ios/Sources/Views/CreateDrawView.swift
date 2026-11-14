import PencilKit
import SwiftUI
import UniformTypeIdentifiers
import PixelClipKit

/// Draw (docs/DESIGN.md ▸ Draw): preview on top (the pipeline's output), the zoomable canvas, tools,
/// the frame timeline, then Send to the clip / Add to the playlist instead. Dark whatever the system
/// appearance.
///
/// In landscape (the phone turned, or "Rotate for a bigger canvas") the canvas gets the screen at
/// the largest whole zoom step that fits, the tools move to a rail on the leading edge (trailing
/// for left-handed drawing, Canvas Settings), the frames become a thin collapsible strip and the
/// preview shrinks to a thumbnail at the strip's end: the canvas is the preview at that size.
struct CreateDrawView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(Router.self) private var router
    @Environment(Sender.self) private var sender
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model: CreateDrawModel
    @State private var saving = false
    @State private var saved = 0
    @State private var showSettings = false
    @State private var textEntry = ""
    /// Landscape: the editor's size inside the safe area (picks two or three rail columns).
    @State private var area: CGSize = .zero
    @State private var stripCollapsed = false
    @State private var previewEnlarged = false
    @AppStorage(DrawPrefs.rotateHintSeen) private var rotateHintSeen = false
    @AppStorage(DrawPrefs.railOnRight) private var railOnRight = false

    let mode: ComposeMode
    /// Called when the screen goes away: the draft to pick up next time, or nil once it went to the clip
    /// or the playlist (the next Draw starts fresh).
    var onLeave: (String?) -> Void = { _ in }
    @State private var finished = false

    init(draftID: String?, mode: ComposeMode = .send, onLeave: @escaping (String?) -> Void = { _ in }) {
        _model = State(initialValue: CreateDrawModel(draftID: draftID))
        self.mode = mode
        self.onLeave = onLeave
    }

    /// iPhone landscape (compact height).
    private var landscape: Bool { verticalSizeClass == .compact }
    private var railColumns: Int {
        CanvasZoom.railColumns(available: area, scale: displayScale,
                               strip: stripCollapsed ? CanvasZoom.LandscapeChrome.stripCollapsed : CanvasZoom.LandscapeChrome.stripExpanded)
    }
    private var spring: Animation { reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.35, bounce: 0) }

    var body: some View {
        // One layout that changes axis, so the canvas (the middle child) keeps its identity, zoom and
        // in-progress state when the phone turns.
        let layout = landscape ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
        layout {
            if landscape {
                if !railOnRight { rail }
            } else {
                header
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }
            canvasColumn
            if landscape {
                if railOnRight { rail }
            } else {
                portraitControls
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { area = $0 }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .navigationTitle("Draw")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSettings = true } label: { Label("Canvas Settings", systemImage: "slider.horizontal.3") }
            }
            // Sideways there's no room for the big button: Send sits in the bar.
            if landscape {
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
                ToolbarItem(placement: .topBarTrailing) {
                    Button { save(toPlaylist: mode == .playlist) } label: {
                        if saving { ProgressView() } else { Text(mode == .playlist ? "Add" : "Send") }
                    }
                    .buttonStyle(.glassProminent)
                    .foregroundStyle(Z2.onAccent)
                    .disabled(saving)
                }
            }
        }
        .sensoryFeedback(.success, trigger: saved)
        .sheet(isPresented: $showSettings) { DrawSettingsSheet(model: model) }
        .alert("Add Text", isPresented: Binding(get: { model.pendingTextPoint != nil }, set: { if !$0 { model.pendingTextPoint = nil } })) {
            TextField("Words or emoji", text: $textEntry)
            Button("Cancel", role: .cancel) { model.pendingTextPoint = nil }
            Button("Add") {
                if let p = model.pendingTextPoint { model.addText(textEntry, at: p) }
                model.pendingTextPoint = nil
                textEntry = ""
            }
        } message: {
            Text("It’s placed where you tapped. Use Move to drag it.")
        }
        .alert("Couldn’t Save", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
        .onDisappear {
            model.saveNow()
            onLeave(finished ? nil : model.doc.id)
        }
        .allowsLandscape(.draw)
        .onChange(of: landscape, initial: true) { _, isLandscape in
            if isLandscape { rotateHintSeen = true } else { previewEnlarged = false }
        }
        .task {
            model.start()
            #if DEBUG
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-PixelClipCreateFrame"), i + 1 < args.count, let n = Int(args[i + 1]) { model.selectFrame(n - 1) }
            if args.contains("-PixelClipCreatePlay") { model.playing = true }
            if args.contains("-PixelClipDrawRotateHint") { rotateHintSeen = false }
            if args.contains("-PixelClipDrawOnionOff") { model.onionSkin = false }
            if args.contains("-PixelClipDrawPreview") {
                try? await Task.sleep(for: .milliseconds(1400))
                previewEnlarged = true
            }
            #endif
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { model.saveNow() } }
    }

    // MARK: Canvas

    private var canvasColumn: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                CreateCanvasView(model: model)
                // In landscape the canvas nearly fills its area; the readout moves to the frame strip.
                if !landscape {
                    Text(model.zoomLabel)
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.black.opacity(0.55), in: .capsule)
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(8)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .overlay(alignment: .topLeading) { rotateButton }
            .overlay(alignment: .top) {
                if showsRotateHint {
                    RotateHint(rotate: rotateForBiggerCanvas, dismiss: { withAnimation(spring) { rotateHintSeen = true } })
                        .padding(.top, 10)
                        .padding(.horizontal, 48)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                }
            }
            .frame(minHeight: landscape ? 0 : 200, maxHeight: .infinity)
            if landscape {
                DrawFrameStrip(model: model, collapsed: $stripCollapsed, previewEnlarged: $previewEnlarged, spring: spring)
                    .frame(height: stripCollapsed ? CanvasZoom.LandscapeChrome.stripCollapsed : CanvasZoom.LandscapeChrome.stripExpanded)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if landscape && previewEnlarged {
                EnlargedPreview(model: model) { withAnimation(spring) { previewEnlarged = false } }
                    .padding(.trailing, 8)
                    .padding(.bottom, (stripCollapsed ? CanvasZoom.LandscapeChrome.stripCollapsed : CanvasZoom.LandscapeChrome.stripExpanded) + 4)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.27, anchor: .bottomTrailing).combined(with: .opacity))
            }
        }
    }

    private var showsRotateHint: Bool { !landscape && !rotateHintSeen && OrientationLock.shared.allowsLandscape }

    /// Portrait: turn sideways for a bigger canvas (after the hint is dismissed). In landscape the
    /// way back to portrait is in the rail.
    @ViewBuilder private var rotateButton: some View {
        if !landscape && !showsRotateHint && OrientationLock.shared.allowsLandscape {
            Button(action: rotateForBiggerCanvas) {
                Image(systemName: "rectangle.landscape.rotate")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 30, height: 30)
                    .background(.black.opacity(0.55), in: .circle)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(PressableStyle(scale: 0.9))
            .accessibilityLabel("Rotate for a Bigger Canvas")
        }
    }

    private func rotateForBiggerCanvas() {
        rotateHintSeen = true
        Orientation.requestLandscape()
    }

    // MARK: Portrait

    private var portraitControls: some View {
        VStack(spacing: 0) {
            DrawOptionsBar(model: model)
                .frame(height: 52)
                .padding(.horizontal, 12)
            DrawToolStrip(model: model)
            Divider().overlay(.white.opacity(0.08))
            DrawTimeline(model: model)
            Z2SendButtons(mode: mode, working: saving, send: { save(toPlaylist: false) }, addToPlaylist: { save(toPlaylist: true) })
                .padding(.horizontal, 20)
                .padding(.top, 6)
        }
    }

    // MARK: Landscape

    private var rail: some View {
        DrawToolRail(model: model, columns: railColumns, edge: railOnRight ? .trailing : .leading,
                     toPortrait: { Orientation.requestPortrait() })
            .frame(width: CanvasZoom.LandscapeChrome.railWidth(columns: railColumns))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            ClipScreenPreview(frames: model.preview, glow: true, accessibilityLabel: "Preview of what the clip will show")
                .frame(maxWidth: 210)
            VStack(alignment: .leading, spacing: 8) {
                Text(model.infoLine)
                    .font(.footnote.weight(.medium).monospacedDigit())
                    .foregroundStyle(model.bytes > CreateBudget.warning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.numericText())
                Button {
                    model.playing.toggle()
                } label: {
                    Label(model.playing ? "Stop" : "Play", systemImage: model.playing ? "stop.fill" : "play.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .disabled(model.frameCount < 2)
                .accessibilityHint("Loops the animation in the preview")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func save(toPlaylist: Bool) {
        saving = true
        model.playing = false
        Task {
            await Task.yield()
            do {
                let out = try model.renderForSave()
                let item = try CreateLibrary.save(out.asset, original: out.original, name: model.name, recipe: model.recipe,
                                                  replacing: nil, library: library)
                model.markSaved(itemID: item.id)
                saved += 1
                saving = false
                if toPlaylist { sender.addToPlaylist(.asset(item.id), name: item.name) } else { sender.sendNow(.asset(item.id), title: item.name) }
                finished = true
                router.finish(mode)
            } catch {
                saving = false
                model.error = (error as? BudgetError)?.errorDescription ?? "Couldn’t save it. Try again."
            }
        }
    }
}

// MARK: - Tools

private struct DrawToolStrip: View {
    let model: CreateDrawModel
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)

    var body: some View {
        // Every tool visible at once: inks on the first row, paint tools on the second, undo/redo at
        // the ends.
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(Array(DrawTool.allCases.prefix(5))) { toolButton($0) }
            cell(title: "Undo", systemImage: "arrow.uturn.backward", enabled: model.canUndo) { model.undo() }
            cell(title: "Redo", systemImage: "arrow.uturn.forward", enabled: model.canRedo) { model.redo() }
            ForEach(Array(DrawTool.allCases.dropFirst(5))) { toolButton($0) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .sensoryFeedback(.selection, trigger: model.tool)
    }

    private func toolButton(_ t: DrawTool) -> some View {
        let on = model.tool == t
        return Button { model.tool = t } label: {
            label(t.title, t.systemImage)
                .foregroundStyle(on ? Color.accentColor : .white.opacity(0.78))
                .background(on ? Color.accentColor.opacity(0.16) : .clear, in: .rect(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(PressableStyle(scale: 0.92))
        .accessibilityLabel(t.title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func cell(title: String, systemImage: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { label(title, systemImage).foregroundStyle(.white.opacity(enabled ? 0.78 : 0.25)) }
            .buttonStyle(PressableStyle(scale: 0.92))
            .disabled(!enabled)
            .accessibilityLabel(title)
    }

    private func label(_ title: String, _ systemImage: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: systemImage).font(.system(size: 17, weight: .medium)).frame(height: 21)
            Text(title).font(.system(size: 10, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 46)
        .contentShape(.rect)
    }
}

/// What the current tool can change: colour and size for inks, grid for the pixel pen, shape kind,
/// sticker choice, the selected overlay…
private struct DrawOptionsBar: View {
    @Bindable var model: CreateDrawModel
    /// The landscape popover shows the colour on its own row.
    var showsColor = true
    @State private var showStickers = false
    @State private var showFonts = false

    var body: some View {
        HStack(spacing: 10) {
            if showsColor { colorButton }
            switch model.tool {
            case .eraser:
                widthSlider(range: 2...40, label: "Eraser size")
            case .pen, .marker, .highlighter, .crayon:
                widthSlider(range: 1...40, label: "Line width")
            case .fill:
                Toggle(isOn: $model.erasing) { Label("Clear", systemImage: "eraser") }.toggleStyle(.button)
                Text(model.erasing ? "Tap a filled area to clear it." : "Tap an area to fill it.").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            case .pixel:
                Picker("Grid", selection: $model.pixelCell) {
                    ForEach([1, 2, 4, 8], id: \.self) { Text("\($0) px").tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle(isOn: $model.erasing) { Image(systemName: "eraser") }.toggleStyle(.button).accessibilityLabel("Erase pixels")
            case .shape:
                Picker("Shape", selection: $model.shapeKind) {
                    ForEach(ShapeKind.allCases) { Image(systemName: $0.systemImage).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 150)
                Toggle(isOn: $model.shapeFilled) { Image(systemName: model.shapeFilled ? "circle.fill" : "circle") }
                    .toggleStyle(.button).accessibilityLabel("Filled")
                widthSlider(range: 1...24, label: "Line width")
            case .text:
                Button { showFonts = true } label: {
                    Text(CreateFonts.choice(model.textFont.familyID).name).lineLimit(1).frame(maxWidth: 120)
                }
                .buttonStyle(.bordered)
                sizeSlider
            case .sticker:
                Button { showStickers = true } label: { Image(systemName: model.sticker).frame(width: 36) }
                    .buttonStyle(.bordered).accessibilityLabel("Choose sticker")
                sizeSlider
            case .move:
                if model.selectedOverlay != nil {
                    sizeSlider
                    Button(role: .destructive) { model.deleteSelection() } label: { Image(systemName: "trash") }
                        .buttonStyle(.bordered).accessibilityLabel("Delete")
                } else {
                    Text("Drag a text or sticker to move it.").font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }
        }
        .controlSize(.small)
        .sheet(isPresented: $showStickers) { StickerPicker(selection: $model.sticker) }
        .sheet(isPresented: $showFonts) { CreateFontPicker(selection: $model.textFont, sample: "Aa") }
    }

    private var colorButton: some View {
        ColorPicker("Colour", selection: $model.color.color, supportsOpacity: false)
            .labelsHidden()
            .frame(width: 30)
    }

    private func widthSlider(range: ClosedRange<Double>, label: String) -> some View {
        HStack(spacing: 8) {
            Circle().fill(.white.opacity(0.8)).frame(width: max(3, min(22, model.width / 2)), height: max(3, min(22, model.width / 2)))
                .frame(width: 22)
            Slider(value: $model.width, in: range).accessibilityLabel(label)
            Text("\(Int(model.width))").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 22)
        }
    }

    private var sizeSlider: some View {
        HStack(spacing: 6) {
            Image(systemName: "textformat.size.smaller").foregroundStyle(.secondary)
            Slider(value: $model.stampSize, in: 12...200).accessibilityLabel("Size")
            Image(systemName: "textformat.size.larger").foregroundStyle(.secondary)
        }
    }
}

private struct StickerPicker: View {
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss
    private let columns = [GridItem(.adaptive(minimum: 56), spacing: 10)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(CreateStickers.all, id: \.self) { name in
                        Button { selection = name; dismiss() } label: {
                            Image(systemName: name)
                                .font(.system(size: 26))
                                .frame(width: 56, height: 56)
                                .background(selection == name ? Color.accentColor.opacity(0.2) : Color.white.opacity(0.06),
                                            in: .rect(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(PressableStyle(scale: 0.9))
                        .accessibilityLabel(name.replacingOccurrences(of: ".", with: " "))
                    }
                }
                .padding(20)
            }
            .navigationTitle("Stickers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Timeline

private struct DrawTimeline: View {
    let model: CreateDrawModel

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Text("Frames").font(.subheadline.weight(.semibold))
                Spacer()
                Toggle(isOn: Binding(get: { model.onionSkin }, set: { model.onionSkin = $0 })) {
                    Label("Onion Skin", systemImage: "circle.lefthalf.striped.horizontal")
                }
                .toggleStyle(.button)
                .controlSize(.small)
                Menu {
                    Picker("Speed", selection: Binding(get: { model.fps }, set: { model.fps = $0 })) {
                        ForEach([6, 8, 10, 12, 15, 18, 24], id: \.self) { Text("\($0) fps").tag($0) }
                    }
                } label: {
                    Label("\(model.fps) fps", systemImage: "speedometer").font(.subheadline.monospacedDigit())
                }
                .accessibilityLabel("Frame rate, \(model.fps) frames per second")
            }
            .padding(.horizontal, 16)
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(Array(model.frames.enumerated()), id: \.element.id) { i, f in
                            FrameThumb(model: model, index: i, frame: f)
                                .id(f.id)
                        }
                        Button { model.addFrame() } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 20, weight: .semibold))
                                .frame(width: 58, height: 52)
                                .background(.white.opacity(0.08), in: .rect(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(PressableStyle(scale: 0.92))
                        .disabled(model.frameCount >= DrawingDocument.maxFrames)
                        .accessibilityLabel("Add frame")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.hidden)
                .onChange(of: model.current) { _, _ in
                    withAnimation(.smooth) { proxy.scrollTo(model.currentFrame.id, anchor: .center) }
                }
            }
        }
        .padding(.vertical, 10)
    }
}

private struct FrameThumb: View {
    let model: CreateDrawModel
    let index: Int
    let frame: DrawingFrame
    /// 536:240, like the clip.
    var size = CGSize(width: 116, height: 52)
    @State private var targeted = false

    var body: some View {
        let selected = model.current == index
        Button { model.selectFrame(index) } label: {
            ZStack(alignment: .bottomLeading) {
                Color.black
                if let img = model.thumbnails[frame.id] {
                    Image(decorative: img, scale: 1).resizable().interpolation(.medium).aspectRatio(contentMode: .fill)
                }
                HStack(spacing: 3) {
                    Text("\(index + 1)")
                    if frame.hold > 1 { Text("×\(frame.hold)") }
                }
                .font(.system(size: 9, weight: .bold).monospacedDigit())
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(.black.opacity(0.6), in: .rect(cornerRadius: 4))
                .padding(3)
            }
            .frame(width: size.width, height: size.height)
            .clipShape(.rect(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : (targeted ? .white.opacity(0.6) : .white.opacity(0.12)),
                                  lineWidth: selected || targeted ? 2.5 : 0.5)
            }
        }
        .buttonStyle(PressableStyle(scale: 0.95))
        .accessibilityLabel("Frame \(index + 1)\(frame.hold > 1 ? ", held \(frame.hold) times" : "")")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu {
            Button("Duplicate", systemImage: "plus.square.on.square") { model.duplicateFrame(index) }
            Menu("Hold", systemImage: "timer") {
                ForEach(1...4, id: \.self) { h in
                    Button { model.setHold(index, h) } label: {
                        if frame.hold == h { Label("×\(h)", systemImage: "checkmark") } else { Text("×\(h)") }
                    }
                }
            }
            Button("Move Left", systemImage: "arrow.left") { model.moveFrame(from: index, to: index - 1) }.disabled(index == 0)
            Button("Move Right", systemImage: "arrow.right") { model.moveFrame(from: index, to: index + 1) }.disabled(index == model.frameCount - 1)
            Divider()
            Button(model.frameCount == 1 ? "Clear" : "Delete", systemImage: "trash", role: .destructive) { model.deleteFrame(index) }
        }
        .draggable(frame.id.uuidString) {
            Group {
                if let img = model.thumbnails[frame.id] { Image(decorative: img, scale: 1).resizable().frame(width: size.width, height: size.height) }
                else { Color.black.frame(width: size.width, height: size.height) }
            }
        }
        .dropDestination(for: String.self) { items, _ in
            guard let s = items.first, let id = UUID(uuidString: s) else { return false }
            model.moveFrame(id: id, before: frame.id)
            return true
        } isTargeted: { targeted = $0 }
    }
}

// MARK: - Settings

private struct DrawSettingsSheet: View {
    @Bindable var model: CreateDrawModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmClear = false
    @AppStorage(DrawPrefs.railOnRight) private var railOnRight = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $model.name)
                }
                Section {
                    ColorPicker("Background", selection: $model.background.color, supportsOpacity: false)
                    Toggle("Onion Skin", isOn: $model.onionSkin)
                    Toggle("Smooth Gradients", isOn: $model.dither)
                } footer: {
                    Text("True black is off on the clip’s screen (and saves battery). Smooth Gradients dithers colours the screen can’t show exactly; leave it off for flat art and pixel art.")
                }
                Section {
                    Toggle("Tools on the Right", isOn: $railOnRight)
                } header: {
                    Text("Landscape")
                } footer: {
                    Text("Turn your phone sideways for a bigger canvas. With the tools on the right, your left hand draws and your right hand picks tools.")
                }
                Section("Animation") {
                    Picker("Frame Rate", selection: $model.fps) {
                        ForEach([6, 8, 10, 12, 15, 18, 24], id: \.self) { Text("\($0) fps").tag($0) }
                    }
                    LabeledContent("Frames", value: "\(model.frameCount)")
                    LabeledContent("Loop", value: String(format: "%.1f s", Double(model.doc.loopMs) / 1000))
                }
                Section {
                    Button("Clear This Frame", role: .destructive) { confirmClear = true }
                }
            }
            .navigationTitle("Canvas")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Clear frame \(model.current + 1)?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear Frame", role: .destructive) { model.clearFrame() }
            } message: { Text("You can undo this.") }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Landscape

enum DrawPrefs {
    /// The portrait "Rotate your phone for a bigger canvas" hint was dismissed (or landscape used).
    static let rotateHintSeen = "draw.rotateHintSeen"
    /// Landscape rail on the trailing edge (left-handed drawing).
    static let railOnRight = "draw.railOnRight"
}

/// The one-time portrait hint. Tapping it rotates; the cross dismisses it for good.
private struct RotateHint: View {
    let rotate: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: rotate) {
                HStack(spacing: 10) {
                    Image(systemName: "rectangle.landscape.rotate")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.tint)
                    Text("Rotate your phone for a bigger canvas")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 14)
                .padding(.vertical, 10)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Turns the editor sideways now")
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 30, height: 30)
                    .background(.white.opacity(0.1), in: .circle)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(PressableStyle(scale: 0.9))
            .accessibilityLabel("Dismiss")
        }
        .padding(.trailing, 2)
        .glassEffect(.regular, in: .capsule)
    }
}

/// Landscape tools: a compact vertical rail. Colour & size first (a popover from its cell), every
/// tool one tap away, then undo/redo, onion skin, play and back to portrait, all at 44 pt.
private struct DrawToolRail: View {
    @Bindable var model: CreateDrawModel
    let columns: Int
    /// The screen edge the rail sits on (the popover opens toward the canvas).
    let edge: HorizontalEdge
    let toPortrait: () -> Void
    @State private var showOptions = false

    private typealias Chrome = CanvasZoom.LandscapeChrome

    private enum Item: Hashable {
        case options, tool(DrawTool), undo, redo, onion, play, portrait
    }

    private var sections: [[Item]] {
        [[.options] + DrawTool.allCases.map(Item.tool), [.undo, .redo, .onion, .play, .portrait]]
    }

    private func rows(_ items: [Item]) -> [[Item]] {
        stride(from: 0, to: items.count, by: columns).map { Array(items[$0..<min($0 + columns, items.count)]) }
    }

    var body: some View {
        ScrollView(.vertical) {
            Grid(horizontalSpacing: Chrome.railSpacing, verticalSpacing: Chrome.railRowSpacing) {
                ForEach(Array(sections.enumerated()), id: \.offset) { i, section in
                    if i > 0 {
                        Divider().overlay(.white.opacity(0.1))
                            .gridCellColumns(columns)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 3)
                    }
                    ForEach(Array(rows(section).enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(row, id: \.self) { cell($0) }
                        }
                    }
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, Chrome.railPadding)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .background(Color(white: 0.05))
        .overlay(alignment: edge == .leading ? .trailing : .leading) {
            Rectangle().fill(.white.opacity(0.08)).frame(width: 0.5)
        }
        .sensoryFeedback(.selection, trigger: model.tool)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tools")
        #if DEBUG
        .task {
            if ProcessInfo.processInfo.arguments.contains("-PixelClipDrawPopover") {
                try? await Task.sleep(for: .milliseconds(900))
                showOptions = true
            }
        }
        #endif
    }

    @ViewBuilder private func cell(_ item: Item) -> some View {
        switch item {
        case .options: optionsCell
        case .tool(let t):
            toggle(t.title, t.systemImage, on: model.tool == t) { model.tool = t }
        case .undo:
            action("Undo", "arrow.uturn.backward", enabled: model.canUndo) { model.undo() }
        case .redo:
            action("Redo", "arrow.uturn.forward", enabled: model.canRedo) { model.redo() }
        case .onion:
            toggle("Onion Skin", "circle.lefthalf.striped.horizontal", on: model.onionSkin) { model.onionSkin.toggle() }
        case .play:
            toggle(model.playing ? "Stop" : "Play", model.playing ? "stop.fill" : "play.fill", on: model.playing,
                   enabled: model.frameCount > 1) { model.playing.toggle() }
        case .portrait:
            action("Rotate to Portrait", "rectangle.portrait.rotate", enabled: true, run: toPortrait)
        }
    }

    /// The current colour in a spectrum ring: opens colour and size.
    private var optionsCell: some View {
        Button { showOptions = true } label: {
            Circle().fill(model.color.color)
                .frame(width: 24, height: 24)
                .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1))
                .padding(3)
                .overlay(Circle().strokeBorder(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center), lineWidth: 2.5))
                .frame(width: Chrome.railCell, height: Chrome.railCell)
                .background(showOptions ? Color.white.opacity(0.12) : .clear, in: .rect(cornerRadius: 12, style: .continuous))
                .contentShape(.rect)
        }
        .buttonStyle(PressableStyle(scale: 0.92))
        .accessibilityLabel("Colour and Size")
        .help("Colour and Size")
        .popover(isPresented: $showOptions, arrowEdge: edge == .leading ? .leading : .trailing) {
            DrawOptionsPopover(model: model)
                .presentationCompactAdaptation(.popover)
        }
    }

    private func action(_ title: String, _ systemImage: String, enabled: Bool, run: @escaping () -> Void) -> some View {
        Button(action: run) { icon(systemImage).foregroundStyle(.white.opacity(enabled ? 0.78 : 0.25)) }
            .buttonStyle(PressableStyle(scale: 0.92))
            .disabled(!enabled)
            .accessibilityLabel(title)
            .help(title)
    }

    private func toggle(_ title: String, _ systemImage: String, on: Bool, enabled: Bool = true, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            icon(systemImage)
                .foregroundStyle(on ? Color.accentColor : .white.opacity(enabled ? 0.78 : 0.25))
                .background(on ? Color.accentColor.opacity(0.18) : .clear, in: .rect(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(PressableStyle(scale: 0.92))
        .disabled(!enabled)
        .accessibilityLabel(title)
        .accessibilityAddTraits(on ? .isSelected : [])
        .help(title)
    }

    private func icon(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 18, weight: .medium))
            .frame(width: Chrome.railCell, height: Chrome.railCell)
            .contentShape(.rect)
    }
}

/// Colour and the current tool's options, in a popover from the rail.
private struct DrawOptionsPopover: View {
    @Bindable var model: CreateDrawModel
    private static let swatches: [UInt32] = [0xFFFFFF, BrandPalette.primary, 0xFF6FB5, 0xFF453A, 0xFF9F0A, 0xFFD60A, 0x30D158, 0x64D2FF, 0x0A84FF, 0x8E8E93]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(model.tool.title, systemImage: model.tool.systemImage)
                    .font(.headline)
                Spacer()
                ColorPicker("More Colours", selection: $model.color.color, supportsOpacity: false)
                    .labelsHidden()
            }
            HStack(spacing: 4) {
                ForEach(Self.swatches, id: \.self) { hex in
                    let c = RGBAColor(hex: hex)
                    let on = model.color == c
                    Button { model.color = c } label: {
                        Circle().fill(c.color)
                            .overlay(Circle().strokeBorder(.white.opacity(on ? 0.95 : 0.2), lineWidth: on ? 2.5 : 1))
                            .frame(width: 24, height: 24)
                            .frame(width: 26, height: 36)
                            .contentShape(.rect)
                    }
                    .buttonStyle(PressableStyle(scale: 0.88))
                    .accessibilityLabel("Colour \(String(format: "#%06X", hex))")
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            DrawOptionsBar(model: model, showsColor: false)
                .frame(height: 36)
        }
        .padding(16)
        .frame(width: 340)
        .preferredColorScheme(.dark)
    }
}

/// Landscape frames: a thin strip of thumbnails along the bottom that collapses to one line; the
/// clip preview is the thumbnail at its trailing end (tap to enlarge).
private struct DrawFrameStrip: View {
    let model: CreateDrawModel
    @Binding var collapsed: Bool
    @Binding var previewEnlarged: Bool
    let spring: Animation

    private var thumb: CGSize { CGSize(width: 89, height: 40) }

    var body: some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(spring) { collapsed.toggle() }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .semibold))
                    .rotationEffect(.degrees(collapsed ? 180 : 0))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 44)
                    .frame(maxHeight: .infinity)
                    .contentShape(.rect)
            }
            .buttonStyle(PressableStyle(scale: 0.9))
            .accessibilityLabel(collapsed ? "Show Frames" : "Hide Frames")
            if collapsed {
                Text(model.infoLine)
                    .font(.footnote.weight(.medium).monospacedDigit())
                    .foregroundStyle(model.bytes > CreateBudget.warning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .contentTransition(.numericText())
                Spacer(minLength: 8)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            ForEach(Array(model.frames.enumerated()), id: \.element.id) { i, f in
                                FrameThumb(model: model, index: i, frame: f, size: thumb).id(f.id)
                            }
                            Button { model.addFrame() } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 17, weight: .semibold))
                                    .frame(width: 48, height: thumb.height)
                                    .background(.white.opacity(0.08), in: .rect(cornerRadius: 10, style: .continuous))
                            }
                            .buttonStyle(PressableStyle(scale: 0.92))
                            .disabled(model.frameCount >= DrawingDocument.maxFrames)
                            .accessibilityLabel("Add frame")
                        }
                        .padding(.vertical, 4)
                        .padding(.trailing, 4)
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: model.current) { _, _ in
                        withAnimation(.smooth) { proxy.scrollTo(model.currentFrame.id, anchor: .center) }
                    }
                }
            }
            Text(model.zoomLabel)
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(.white.opacity(0.08), in: .capsule)
                .accessibilityLabel("Zoom \(model.zoomLabel)")
            Menu {
                Picker("Speed", selection: Binding(get: { model.fps }, set: { model.fps = $0 })) {
                    ForEach([6, 8, 10, 12, 15, 18, 24], id: \.self) { Text("\($0) fps").tag($0) }
                }
            } label: {
                Text("\(model.fps) fps")
                    .font(.footnote.weight(.semibold).monospacedDigit())
                    .frame(minWidth: 44, maxHeight: .infinity)
                    .contentShape(.rect)
            }
            .accessibilityLabel("Frame rate, \(model.fps) frames per second")
            Button {
                withAnimation(spring) { previewEnlarged.toggle() }
            } label: {
                ClipScreenPreview(frames: model.preview, glow: false, bezel: true, accessibilityLabel: "Preview of what the clip will show")
                    .frame(width: collapsed ? 56 : 80)
                    .opacity(previewEnlarged ? 0.4 : 1)
                    .frame(maxHeight: .infinity)
                    .contentShape(.rect)
            }
            .buttonStyle(PressableStyle(scale: 0.95))
            .accessibilityHint(previewEnlarged ? "Shrinks the preview" : "Enlarges the preview")
            .padding(.trailing, 8)
        }
        .padding(.leading, 2)
        .background(Color(white: 0.05))
        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.08)).frame(height: 0.5) }
    }
}

/// The preview, enlarged from the strip's thumbnail: what the clip will show, with the loop's
/// numbers. Tap to shrink it back.
private struct EnlargedPreview: View {
    let model: CreateDrawModel
    let dismiss: () -> Void

    var body: some View {
        Button(action: dismiss) {
            VStack(alignment: .leading, spacing: 8) {
                ClipScreenPreview(frames: model.preview, glow: true, accessibilityLabel: "Preview of what the clip will show")
                    .frame(width: 280)
                Text(model.infoLine)
                    .font(.footnote.weight(.medium).monospacedDigit())
                    .foregroundStyle(model.bytes > CreateBudget.warning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .contentTransition(.numericText())
            }
            .padding(12)
            .glassEffect(.regular, in: .rect(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(PressableStyle(scale: 0.98))
        .accessibilityHint("Shrinks the preview")
    }
}

/// Home ▸ Draw: picks up the doodle in progress (until it has been sent), else a fresh canvas.
struct DrawScreen: View {
    let mode: ComposeMode
    @AppStorage("draw.currentDraft") private var currentDraft = ""

    var body: some View {
        CreateDrawView(draftID: currentDraft.isEmpty ? nil : currentDraft, mode: mode) { draft in currentDraft = draft ?? "" }
    }
}
