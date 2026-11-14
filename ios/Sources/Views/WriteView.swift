import SwiftUI
import PixelClipKit

/// One of Write's four looks: a bundled font (and, for DOTS, the LED dot-matrix pattern).
enum WriteLook: String, CaseIterable, Identifiable {
    case bold, script, typewriter, dots

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bold: "Bold"
        case .script: "Script"
        case .typewriter: "Typewriter"
        case .dots: "DOTS"
        }
    }

    /// Fredoka Bold, Pacifico, VT323 and DotGothic16 (all bundled, SIL OFL).
    var font: FontSelection {
        switch self {
        case .bold: FontSelection(familyID: "fredoka", weight: 0.4)
        case .script: FontSelection(familyID: "pacifico", weight: 0)
        case .typewriter: FontSelection(familyID: "vt323", weight: 0)
        case .dots: FontSelection(familyID: "dotgothic16", weight: 0)
        }
    }

    var led: Bool { self == .dots }

    static let stillShare = 0.9
    static let scrollShare = 0.4

    /// The message in this look: still when it fits on the screen at a good size, else a strip the clip
    /// scrolls by itself (the app decides; there's no Scroll/Still choice).
    func spec(_ text: String) -> MarqueeSpec {
        var spec = MarqueeSpec(text: text, font: font, sizePercent: 1, tracking: led ? 0.04 : 0, fill: .solid(.accent),
                               motion: .still, led: led, ledPitch: 5, speed: 120, spacing: 0.35)
        let ct = CreateFonts.ctFont(font, size: 100)
        let stillFit = MarqueeRenderer.summary(spec, font: ct).fontSize
        var scrolling = spec
        scrolling.motion = .scroll
        let scrollFit = MarqueeRenderer.summary(scrolling, font: ct).fontSize
        // Still when, fitted to the screen, it's at least as big as a scrolling line would be; a
        // scrolling line is 40 % of the full height (about the mockup's size).
        if stillFit * Self.stillShare >= scrollFit * Self.scrollShare {
            spec.sizePercent = Self.stillShare
        } else {
            spec.motion = .scroll
            spec.sizePercent = Self.scrollShare
        }
        return spec
    }

    /// §5b.1: the words sheet in this look (one word per frame, the look's font and colour on black).
    func wordsSpec(_ text: String) -> WordsSheetSpec {
        WordsSheetSpec(text: text, font: font, led: led, ledPitch: 5, tracking: led ? 0.04 : 0, color: .accent)
    }
}

/// Write (docs/DESIGN.md ▸ Write): the live clip preview, a text box, four looks, Send. Nothing else.
struct WriteView: View {
    let mode: ComposeMode
    @Environment(LibraryStore.self) private var library
    @Environment(Router.self) private var router
    @Environment(Sender.self) private var sender
    @AppStorage("write.look") private var lookRaw = WriteLook.bold.rawValue
    @AppStorage("write.text") private var text = "bonne nuit ✦"
    /// §5b.1: "Bounce around": the words become sprites the clip bounces as it moves.
    @AppStorage("write.bounce") private var bounce = false
    /// The words at rest along the bottom edge (the preview while Bounce around is on).
    @State private var wordsPreview: ClipFrames?
    @State private var model = CreateTextModel(spec: MarqueeSpec(text: " ", motion: .still))
    @State private var saving = false
    @FocusState private var typing: Bool

    static let maxCharacters = 160
    static let maxWords = WordsSheetRenderer.maxWords

    private var look: WriteLook { WriteLook(rawValue: lookRaw) ?? .bold }
    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(spacing: 8) {
                    Z2ClipFrame {
                        let frames = bounce ? wordsPreview : model.preview
                        ClipScreenPreview(frames: frames, glow: true, bezel: false,
                                          accessibilityLabel: bounce ? "Preview: the words resting at the bottom: \(text)" : "Preview: \(text)")
                            .overlay { if frames == nil { ProgressView().tint(.white) } }
                            .accessibilityIdentifier("writePreview")
                    }
                    Text(bounce ? "On the clip the words fall and bounce as it moves." : "Too long for the screen? It scrolls by itself.")
                        .font(.caption).foregroundStyle(Z2.hint)
                        .frame(maxWidth: .infinity)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Z2SectionLabel(text: "Your message")
                    TextField("A message for the clip", text: $text, axis: .vertical)
                        .font(.title3)
                        .foregroundStyle(Z2.text)
                        .lineLimit(2...5)
                        .focused($typing)
                        .padding(14)
                        .background(Z2.card, in: .rect(cornerRadius: 16, style: .continuous))
                        .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Z2.border, lineWidth: 1) }
                        .accessibilityLabel("Your message")
                        .accessibilityIdentifier("writeMessage")
                        .onChange(of: text) { _, t in
                            if t.count > Self.maxCharacters { text = String(t.prefix(Self.maxCharacters)) }
                            if bounce, let cut = Self.cutAfterMaxWords(t) { text = cut }
                        }
                    if bounce, wordCount >= Self.maxWords - 4 {
                        Text("\(min(wordCount, Self.maxWords)) of \(Self.maxWords) words")
                            .font(.caption.monospacedDigit()).foregroundStyle(Z2.secondary)
                            .accessibilityIdentifier("writeWordCount")
                    } else if text.count > Self.maxCharacters - 30 {
                        Text("\(Self.maxCharacters - text.count) letters left")
                            .font(.caption.monospacedDigit()).foregroundStyle(Z2.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    Z2SectionLabel(text: "Look")
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { chips }
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) { chip(.bold); chip(.script) }
                            HStack(spacing: 8) { chip(.typewriter); chip(.dots) }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: Binding(get: { bounce }, set: { on in
                        bounce = on
                        if on, let cut = Self.cutAfterMaxWords(text) { text = cut }
                    })) {
                        Text("Bounce around").font(.headline).foregroundStyle(Z2.text)
                    }
                    .tint(Color.accentColor)
                    .accessibilityIdentifier("writeBounce")
                    Text("The words move as the clip moves")
                        .font(.footnote).foregroundStyle(Z2.secondary)
                }
                .z2Card(radius: 16, padding: 14)
                if let error = model.error {
                    Label(error, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 20)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            Z2SendButtons(mode: mode, working: saving, disabled: trimmed.isEmpty || (!bounce && model.rendering),
                          send: { save(toPlaylist: false) }, addToPlaylist: { save(toPlaylist: true) })
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 4)
                .background(Z2.ground)
        }
        .z2Screen("Write")
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { typing = false }
            }
        }
        .task {
            model.spec = look.spec(text)
            model.start()
        }
        .task(id: "\(lookRaw)|\(text)|\(bounce)") {
            // A beat after the last keystroke (the model renders off the main actor, latest wins).
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            if bounce {
                let spec = look.wordsSpec(trimmed)
                let still = await Task.detached(priority: .userInitiated) { () -> ClipFrames? in
                    guard let sheet = try? WordsSheetRenderer.render(spec) else { return nil }
                    return ClipFrames(single: ClipRenderer.makeCGImage(WordsSheetRenderer.restingStill(sheet.frames)))
                }.value
                guard !Task.isCancelled else { return }
                wordsPreview = still ?? ClipFrames(single: ClipRenderer.makeCGImage(RGB565Frame(width: ClipCanvas.width, height: ClipCanvas.height)))
            } else {
                model.spec = look.spec(text.isEmpty ? " " : text)
            }
        }
        .sensoryFeedback(.selection, trigger: lookRaw)
    }

    @ViewBuilder private var chips: some View {
        ForEach(WriteLook.allCases) { chip($0) }
    }

    private func chip(_ l: WriteLook) -> some View {
        Z2Chip(title: l.title, selected: l == look, font: Font(CreateFonts.uiFont(l.font, size: 16))) {
            lookRaw = l.rawValue
        }
        .accessibilityLabel("\(l.title) look")
        .accessibilityIdentifier("look.\(l.rawValue)")
    }

    private var wordCount: Int { WordsSheetRenderer.wordCount(text) }

    /// The text cut before its 13th word (nil: 12 words or fewer).
    static func cutAfterMaxWords(_ t: String) -> String? {
        var words = 0, inWord = false
        for i in t.indices {
            let space = t[i].isWhitespace || t[i].isNewline
            if !space && !inWord {
                words += 1
                if words > maxWords { return String(t[..<i]) }
            }
            inWord = !space
        }
        return nil
    }

    /// §5b.1: the words sheet → the library (like a written message) → Now or the playlist.
    private func saveWords(toPlaylist: Bool) {
        let text = trimmed, lookName = look.rawValue, spec = look.wordsSpec(trimmed)
        Task {
            do {
                let sheet = try await Task.detached(priority: .userInitiated) { try WordsSheetRenderer.render(spec) }.value
                let item = try library.addWords(sheet, text: text, look: lookName, name: "“\(String(text.prefix(28)))”")
                saving = false
                let content = library.content(for: item.id)
                if toPlaylist { sender.addToPlaylist(content, name: item.name) } else { sender.sendNow(content, title: item.name) }
                router.finish(mode)
            } catch {
                saving = false
                model.error = "Couldn’t get the words ready. Try fewer or shorter words."
            }
        }
    }

    private func save(toPlaylist: Bool) {
        guard !trimmed.isEmpty else { return }
        typing = false
        saving = true
        if bounce { saveWords(toPlaylist: toPlaylist); return }
        model.spec = look.spec(trimmed)
        Task {
            do {
                let out = try await model.renderForSave()
                let item = try CreateLibrary.save(out.asset, original: out.original, name: "“\(String(trimmed.prefix(28)))”",
                                                  recipe: model.recipe, replacing: nil, library: library)
                saving = false
                let content = library.content(for: item.id)
                if toPlaylist { sender.addToPlaylist(content, name: item.name) } else { sender.sendNow(content, title: item.name) }
                router.finish(mode)
            } catch {
                saving = false
                model.error = (error as? BudgetError)?.errorDescription ?? "Couldn’t get the message ready. Try a shorter one."
            }
        }
    }
}
