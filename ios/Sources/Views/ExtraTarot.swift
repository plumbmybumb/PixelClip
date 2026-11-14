import SwiftUI
import PixelClipKit

/// The Tarot (PROTOCOL §5f, §5f.6): Jean Dodal's 22 trumps with PixelClip's own readings, one way to play: hold a
/// question, shake, three cards answer. Français / English, the text size, "Edit readings ›", then Send to the
/// clip (or add to the playlist instead). On the clip: shake it, or tap its button; tap twice to go back.
struct TarotExtra: View {
    let mode: ComposeMode
    @Environment(LibraryStore.self) private var library
    @Environment(Router.self) private var router
    @Environment(Sender.self) private var sender
    @Environment(\.dismiss) private var dismiss
    @State private var settings = TarotSettings.shared
    @State private var saving = false
    @State private var openReadings = false

    var body: some View {
        ExtraLayout(extra: .tarot, subtitle: "Shake the clip, the cards answer", mode: mode, working: saving,
                    disabled: !TarotBundle.shared.isAvailable, send: { save(toPlaylist: false) }, addToPlaylist: { save(toPlaylist: true) }) {
            TarotHero()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            HStack(spacing: 8) {
                ForEach(TarotLanguage.allCases) { l in
                    Z2Chip(title: l.title, selected: settings.language == l) { settings.language = l }
                        .accessibilityIdentifier("tarotLanguage.\(l.rawValue)")
                }
            }
            // §5f.3: how big the clip writes (the body and numeral atlases; Large by default).
            VStack(alignment: .leading, spacing: 6) {
                Text("Text on the clip").font(.footnote).foregroundStyle(Z2.secondary)
                HStack(spacing: 8) {
                    ForEach(TarotTextSize.allCases) { size in
                        Z2Chip(title: size.title, selected: settings.textSize == size) { settings.textSize = size }
                            .accessibilityIdentifier("tarotTextSize.\(size.rawValue)")
                    }
                }
            }
            VStack(spacing: 0) {
                NavigationLink { TarotReadingsView() } label: {
                    HStack {
                        Text("Edit readings").foregroundStyle(Z2.text)
                        Spacer()
                        let n = (0..<22).filter { settings.edits.isEdited($0) }.count
                        Text(n == 0 ? "22 ›" : "\(n) edited ›").foregroundStyle(Z2.secondary)
                    }
                    .font(.body)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 52)
                    .contentShape(.rect)
                }
                .buttonStyle(Z2Press(scale: 0.98))
                .accessibilityIdentifier("editReadings")
            }
            .background(Z2.card, in: .rect(cornerRadius: 18, style: .continuous))
            Text("Hold your question. Press once to arm the deck, then shake. Three cards answer — what each says, where you come from and where you go, what their numbers say, what they say together; then a page for each card. Press for the next screen, press twice to go back.")
                .font(.footnote).foregroundStyle(Z2.hint)
            Text("Tarot de Marseille by Jean Dodal, Lyon 1701. The readings are PixelClip’s own.")
                .font(.caption).foregroundStyle(Z2.hint)
        }
        .sensoryFeedback(.selection, trigger: settings.textSize)
        .navigationDestination(isPresented: $openReadings) { TarotReadingsView() }
        #if DEBUG
        .task {
            if DemoContent.tarotPath != nil { openReadings = true }
        }
        #endif
    }

    private func save(toPlaylist: Bool) {
        saving = true
        let spec = settings.spec
        Task {
            do {
                let item = try await TarotMaker.make(spec: spec, settings: settings, library: library)
                saving = false
                let content = library.content(for: item.id)
                if toPlaylist { sender.addToPlaylist(content, name: item.name) } else { sender.sendNow(content, title: item.name) }
                dismiss()
            } catch {
                saving = false
                router.show("Couldn’t get the cards ready. Try again.", systemImage: "exclamationmark.triangle.fill")
            }
        }
    }
}

/// The hero: the deck face down, three faces fanned out in front of it.
struct TarotHero: View {
    var body: some View {
        let b = TarotBundle.shared
        ZStack {
            card(b.back).rotationEffect(.degrees(-4)).offset(x: -96, y: 6)
            ForEach(Array([(1, -14.0, -28.0), (17, 0.0, 6.0), (19, 14.0, 40.0)].enumerated()), id: \.offset) { _, c in
                card(b.face(c.0))
                    .rotationEffect(.degrees(c.1), anchor: .bottom)
                    .offset(x: CGFloat(c.2) + 24)
            }
        }
        .frame(height: 176)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("The Tarot de Marseille: the deck face down and three cards, Le Bateleur, L’Étoile and Le Soleil")
    }

    private func card(_ image: UIImage?) -> some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().interpolation(.high)
            } else {
                Rectangle().fill(Z2.card)
            }
        }
        .aspectRatio(236.0 / 448.0, contentMode: .fit)
        .frame(height: 150)
        .clipShape(.rect(cornerRadius: 6, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color(red: 0.85, green: 0.71, blue: 0.48), lineWidth: 1) }
        .shadow(color: .black.opacity(0.45), radius: 8, y: 4)
    }
}

// MARK: - Edit readings

/// Tarot ▸ Edit readings: the 22 cards; tapping one opens it to edit its texts.
struct TarotReadingsView: View {
    @State private var settings = TarotSettings.shared
    @State private var openCard: Int?

    var body: some View {
        let b = TarotBundle.shared
        List {
            Section {
                ForEach(b.readings?.cards ?? []) { r in
                    NavigationLink { TarotCardEditor(index: r.index) } label: {
                        HStack(spacing: 12) {
                            if let img = b.face(r.index) {
                                Image(uiImage: img).resizable().interpolation(.high).aspectRatio(236.0 / 448.0, contentMode: .fit)
                                    .frame(height: 52).clipShape(.rect(cornerRadius: 3))
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(b.title(r.index, language: .fr)).font(.body).foregroundStyle(Z2.text)
                                Text("\(r.nameEN) · \(r.keyword(settings.language))").font(.footnote).foregroundStyle(Z2.secondary)
                            }
                            Spacer(minLength: 4)
                            if settings.edits.isEdited(r.index) {
                                Text("Edited").font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                    .accessibilityIdentifier("tarotCard.\(r.index)")
                }
            } footer: {
                Text("The texts are PixelClip’s own. Change any of them, in French and in English; “Restore the original” puts a card back.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Z2.sheet.ignoresSafeArea())
        .navigationTitle("Readings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .navigationDestination(item: $openCard) { TarotCardEditor(index: $0) }
        #if DEBUG
        .task {
            if DemoContent.tarotPath == "tarotcard" { openCard = 17 }
            DemoContent.tarotPath = nil
        }
        #endif
    }
}

/// One card: the picture large, its texts in both languages (name, keyword, last line, reading), a preview of how
/// the clip shows them, and "Restore the original". §5f.7: the number note (the notes asset) is no longer on the
/// clip, so it isn't edited here.
struct TarotCardEditor: View {
    let index: Int
    @State private var settings = TarotSettings.shared
    @State private var language: TarotLanguage = TarotSettings.shared.language
    @State private var shown = Shown.reading
    @State private var preview: CGImage?

    enum Shown: String, CaseIterable, Identifiable {
        case face, reading, numbers
        var id: String { rawValue }
        var title: String {
            switch self {
            case .face: "Card"
            case .reading: "Reading"
            case .numbers: "Keyword"
            }
        }
    }

    var body: some View {
        let b = TarotBundle.shared
        List {
            Section {
                VStack(spacing: 12) {
                    if let img = b.face(index) {
                        Image(uiImage: img).resizable().interpolation(.high).aspectRatio(236.0 / 448.0, contentMode: .fit)
                            .frame(height: 260)
                            .clipShape(.rect(cornerRadius: 8, style: .continuous))
                            .shadow(color: .black.opacity(0.4), radius: 10, y: 5)
                            .accessibilityLabel(b.title(index, language: language))
                    }
                    Text(b.title(index, language: language)).font(.title3.weight(.semibold)).foregroundStyle(Z2.text)
                    if let printed = b.readings?[index]?.namePrinted, !printed.isEmpty {
                        Text("Printed on the card: \(printed)").font(.footnote).foregroundStyle(Z2.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }
            Section {
                Picker("Language", selection: $language) {
                    ForEach(TarotLanguage.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
            }
            Section("Name on the clip") { field(\.name, original: { $0.displayName(language) }, lines: 1) }
            Section("Keyword") { field(\.keyword, original: { $0.keyword(language) }, lines: 1) }
            // §5f.6: no question card on the clip any more; the card's own question stays in the data, unedited here.
            Section {
                field(\.closing, original: { $0.closing(language) }, lines: 2)
            } header: {
                Text("Last line of a reading")
            } footer: {
                Text("When this card is in the centre of the row, the clip ends the reading with this line.")
            }
            Section("Reading") { field(\.reading, original: { $0.reading(language) }, lines: 6) }
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(Shown.allCases) { s in Z2Chip(title: s.title, selected: shown == s, minHeight: 36) { shown = s } }
                        }
                    }
                    .scrollIndicators(.hidden)
                    Z2ClipFrame {
                        ClipScreenPreview(frames: preview.flatMap { ClipFrames(single: $0) }, glow: true, bezel: false,
                                          accessibilityLabel: "How the clip shows it")
                    }
                }
                .listRowBackground(Color.clear)
            } header: {
                Text("On the clip")
            }
            Section {
                Button("Restore the original", role: .destructive) { settings.edits.restore(index) }
                    .disabled(!settings.edits.isEdited(index))
                    .accessibilityIdentifier("restoreOriginal")
            } footer: {
                Text("Puts back the original texts of this card, in both languages.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Z2.sheet.ignoresSafeArea())
        .navigationTitle(b.readings?[index]?.name(language) ?? "Card")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task(id: PreviewKey(edit: settings.edits[index, language], language: language, shown: shown)) { await renderPreview() }
    }

    private struct PreviewKey: Hashable { var edit: TarotCardEdit; var language: TarotLanguage; var shown: Shown }

    /// A text field bound to one field of the person's edit: showing the original until they change it; typing the
    /// original back (or clearing it) removes the edit.
    private func field(_ key: WritableKeyPath<TarotCardEdit, String?>, original: @escaping (TarotReading) -> String, lines: Int) -> some View {
        let r = TarotBundle.shared.readings?[index]
        let binding = Binding<String>(
            get: { settings.edits[index, language][keyPath: key] ?? r.map(original) ?? "" },
            set: { v in
                var e = settings.edits[index, language]
                let orig = r.map(original) ?? ""
                e[keyPath: key] = (v == orig || v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) ? nil : v
                settings.edits[index, language] = e
            })
        return TextField("", text: binding, axis: .vertical)
            .lineLimit(lines...max(lines, 12))
            .foregroundStyle(Z2.text)
    }

    private func renderPreview() async {
        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled, let deck = TarotBundle.shared.deck, let r = TarotBundle.shared.readings?[index] else { return }
        let text = TarotCardText(r, language: language, edit: settings.edits[index, language])
        let lang = language, shown = shown
        let box = DeckBox(deck: deck)
        let image = await Task.detached(priority: .userInitiated) { () -> ImageBox? in
            guard let p = TarotRenderer.cardPreview(deck: box.deck, text: text, language: lang, fonts: .bundled()) else { return nil }
            let frame: RGB565Frame
            switch shown {
            case .face: frame = p.face
            case .reading: frame = p.readings[0]
            case .numbers:
                // The keyword tile, as the three-card screen shows it under the card.
                var f = RGB565Frame(width: ClipCanvas.width, height: ClipCanvas.height)
                OracleCompositor.paste(p.key, into: &f, x: (ClipCanvas.width - Oracle.keyWidth) / 2, y: 107)
                frame = f
            }
            return ClipRenderer.makeCGImage(frame).map { ImageBox(image: $0) }
        }.value
        guard !Task.isCancelled else { return }
        preview = image?.image
    }

    private struct DeckBox: @unchecked Sendable { let deck: TarotDeck }
}
