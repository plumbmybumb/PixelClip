import SwiftUI
import UniformTypeIdentifiers
import PixelClipKit

/// Reader (docs/DESIGN.md ▸ Extras ▸ Reader): paste a text or pick one already here (texts shared from
/// Safari or Notes land here), a speed, Send. The clip shows it one word at a time.
struct ReaderExtra: View {
    let mode: ComposeMode
    var openDocID: String?
    @Environment(Router.self) private var router
    @Environment(Sender.self) private var sender
    @Environment(\.dismiss) private var dismiss
    @State private var store = ReaderStore.shared
    @State private var player = ReaderPlayer()
    @State private var chosen: String?
    @State private var picking = false
    @State private var working = false
    /// Why the last file couldn't be read (shown under the buttons until the next import).
    @State private var importProblem: String?

    static let speeds = [250, 350, 500]
    /// The biggest file read from Files (a novel is a few MB; an illustrated EPUB some tens).
    static let maxFileBytes = 256 << 20

    private var doc: ReaderDocument? { chosen.flatMap { store.document($0) } }

    var body: some View {
        ExtraLayout(extra: .reader, subtitle: "A text, one word at a time", mode: mode, working: working, disabled: doc == nil,
                    send: send, addToPlaylist: addToPlaylist) {
            Z2ClipFrame {
                ClipScreenPreview(frames: player.frame, glow: true, bezel: false, accessibilityLabel: doc?.title ?? "Reader preview")
                    .overlay {
                        if doc == nil {
                            Text("Paste a text to start").font(.footnote).foregroundStyle(.white.opacity(0.5))
                        } else if !player.hasFont {
                            ProgressView().tint(.white)
                        }
                    }
                    .onTapGesture { player.toggle() }
                    .accessibilityAction(named: "Play or pause") { player.toggle() }
            }
            HStack(spacing: 8) {
                PasteButton(payloadType: String.self) { strings in paste(strings) }
                    .buttonBorderShape(.capsule)
                    .tint(Color.accentColor)
                    .labelStyle(.titleAndIcon)
                Button { picking = true } label: {
                    Label("A file", systemImage: "doc")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .frame(minHeight: 44)
                        .background(Z2.card, in: .capsule)
                        .overlay { Capsule().strokeBorder(Z2.border, lineWidth: 1) }
                }
                .buttonStyle(Z2Press(scale: 0.95))
            }
            if let importProblem {
                Label(importProblem, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote).foregroundStyle(.orange)
                    .accessibilityIdentifier("readerImportProblem")
            }
            if !store.documents.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(store.documents.prefix(6).enumerated()), id: \.element.id) { i, d in
                        if i > 0 { Z2Divider() }
                        Button { chosen = d.id } label: {
                            HStack(spacing: 12) {
                                Image(systemName: d.id == chosen ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(d.id == chosen ? Color.accentColor : Z2.hint)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(d.title).font(.body).foregroundStyle(Z2.text).lineLimit(1)
                                    Text("\(store.minutes(d)) min at \(store.wpm) words a minute").font(.footnote).foregroundStyle(Z2.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .contentShape(.rect)
                        }
                        .buttonStyle(Z2Press(scale: 0.98))
                        .accessibilityAddTraits(d.id == chosen ? .isSelected : [])
                    }
                }
                .background(Z2.card, in: .rect(cornerRadius: 18, style: .continuous))
            }
            Z2SectionLabel(text: "Speed")
            HStack(spacing: 8) {
                ForEach(Self.speeds, id: \.self) { w in
                    Z2Chip(title: "\(w) wpm", selected: store.wpm == w) { store.wpm = w }
                }
            }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.plainText, UTType(filenameExtension: "md") ?? .plainText,
                                                                     UTType(filenameExtension: "epub") ?? .data]) { result in
            guard case .success(let url) = result else { return }
            Task { await importFile(url) }
        }
        .onChange(of: store.wpm) { _, w in player.wpm = w }
        .task {
            // A shared item that couldn't be opened, when the Reader was opened for one that could.
            if let problem = store.inboxProblem {
                importProblem = problem
                store.dismissInboxProblem()
            }
            if !Self.speeds.contains(store.wpm) { store.wpm = 350 }
            chosen = openDocID ?? chosen ?? store.documents.first?.id
        }
        .task(id: chosen) {
            guard let doc else { return }
            player.pause()
            player.wpm = store.wpm
            player.load(words: store.words(doc), position: doc.position >= doc.wordCount - 1 ? 0 : doc.position)
            player.setFont(await store.prepareCurrentFont())
            player.play()
        }
        .onDisappear { player.pause() }
    }

    private func paste(_ strings: [String]) {
        guard let text = strings.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return }
        importProblem = nil
        chosen = store.add(TextImporter.plain(text, fallbackTitle: nil)).id
    }

    /// Reads and converts the picked file off the main actor (a book takes a moment; the screen stays live).
    private func importFile(_ url: URL) async {
        let limit = Self.maxFileBytes
        let result: Result<ImportedText, any Error> = await Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                if let size = InboxClaims.size(of: url), size > limit { throw TextImportError.tooLarge }
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                return .success(try TextImporter.file(data, name: url.lastPathComponent))
            } catch {
                return .failure(error)
            }
        }.value
        switch result {
        case .success(let imported):
            importProblem = nil
            chosen = store.add(imported).id
        case .failure(let error):
            importProblem = (error as? TextImportError)?.errorDescription ?? "That file couldn’t be opened."
        }
    }

    private func send() {
        guard let doc else { return }
        player.pause()
        sender.read(docID: doc.id)
        dismiss()
    }

    private func addToPlaylist() {
        guard let doc else { return }
        working = true
        Task {
            guard let font = await store.prepareCurrentFont() else { working = false; return }
            _ = PlaylistStore.shared.upsertReading(.reader(text: doc.clipTextID, font: font.id, wpm: store.wpm), name: doc.title)
            working = false
            sender.send(.playlist, kind: .playlist)
            dismiss()
        }
    }
}
