import CoreGraphics
import Foundation
import Observation
import PixelClipKit

/// The Reader's state on the phone: saved texts (Application Support/Reader: `index.json` plus each
/// text's clip file), the reading settings (speed, typeface, accent ORP), rendered reader fonts
/// (cached on disk by content hash, re-renderable from the typeface they came from), the clip's
/// progress per text, and the Share Extension's inbox. A reading on the clip is Now (Read now) or a
/// playlist entry (`PlaylistStore.upsertReading`), so every sender composes it (`ClipDocument`).
@MainActor @Observable
final class ReaderStore {
    static let shared = ReaderStore()

    private(set) var documents: [ReaderDocument] = []
    /// `GET /texts` from the clip (by clip text id), read while connected.
    private(set) var clipTexts: [String: ClipText] = [:]
    /// The font for the current settings, once rendered or loaded.
    private(set) var currentFont: ReaderFont?
    private(set) var isRenderingFont = false
    /// Shared items that couldn't be imported yet (e.g. a link while offline).
    private(set) var inboxProblem: String?
    /// Bumped when documents change.
    private(set) var revision = 0

    var wpm: Int {
        didSet { defaults.set(wpm, forKey: Keys.wpm) }
    }
    var typeface: FontSelection {
        didSet {
            if let d = try? JSONEncoder().encode(typeface) { defaults.set(d, forKey: Keys.typeface) }
            if typeface != oldValue { currentFont = nil }
        }
    }
    var accentORP: Bool {
        didSet {
            defaults.set(accentORP, forKey: Keys.accent)
            currentFont = currentFont?.withAccentORP(accentORP)
        }
    }

    /// The default typeface: SF Pro Rounded Medium (clean, open counters, friendly at speed).
    static let defaultTypeface = FontSelection(familyID: FontCatalog.sfRounded, weight: 0.23)

    private enum Keys {
        static let wpm = "reader.wpm"
        static let typeface = "reader.typeface"
        static let accent = "reader.accentORP"
    }

    private struct Index: Codable {
        var version = 1
        var documents: [ReaderDocument] = []
        /// Typeface key → font hash, and hash → how to render it again.
        var fontHashes: [String: String] = [:]
        var fontSources: [String: FontSource] = [:]
    }

    struct FontSource: Codable, Hashable {
        var selection: FontSelection
        var name: String
    }

    /// What a cached font needs besides its atlases.
    private struct FontMeta: Codable {
        var name: String
        var normal: ReaderFontDocument.Face
        var compact: ReaderFontDocument.Face
        var normalSize: Double, compactSize: Double, normalCap: Double, compactCap: Double
    }

    @ObservationIgnored private let dir: URL
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var index = Index()
    @ObservationIgnored private var fonts: [String: ReaderFont] = [:]   // by hash
    @ObservationIgnored private var wordCache: [String: [RSVPWord]] = [:]
    @ObservationIgnored private var renderTask: Task<ReaderFont?, Never>?
    @ObservationIgnored private var importingInbox = false

    init(directory: URL? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        dir = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Reader", isDirectory: true)
        for sub in ["texts", "fonts"] {
            try? FileManager.default.createDirectory(at: dir.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        let stored = defaults.integer(forKey: Keys.wpm)
        wpm = stored == 0 ? RSVPTiming.defaultWPM : min(max(stored, RSVPTiming.appWPMRange.lowerBound), RSVPTiming.appWPMRange.upperBound)
        typeface = defaults.data(forKey: Keys.typeface).flatMap { try? JSONDecoder().decode(FontSelection.self, from: $0) } ?? Self.defaultTypeface
        accentORP = defaults.object(forKey: Keys.accent) as? Bool ?? true
        if let data = try? Data(contentsOf: dir.appendingPathComponent("index.json")),
           let i = try? JSONDecoder.iso.decode(Index.self, from: data) {
            index = i
            documents = i.documents
        }
    }

    private func save() {
        index.documents = documents
        revision += 1
        if let data = try? JSONEncoder.iso.encode(index) { try? data.write(to: dir.appendingPathComponent("index.json"), options: .atomic) }
    }

    // MARK: Documents

    func document(_ id: String) -> ReaderDocument? { documents.first { $0.id == id } }
    func document(clipTextID: String) -> ReaderDocument? { documents.first { $0.clipTextID == clipTextID } }

    private func fileURL(_ doc: ReaderDocument) -> URL { dir.appendingPathComponent("texts/\(doc.id).txt") }

    /// The exact bytes `PUT /texts` sends.
    func file(_ doc: ReaderDocument) -> Data? { try? Data(contentsOf: fileURL(doc)) }

    /// The clip's word index of this text (title first).
    func words(_ doc: ReaderDocument) -> [RSVPWord] {
        if let w = wordCache[doc.id] { return w }
        let w = file(doc).map { RSVPText.tokenize($0, titleBreak: true) } ?? []
        wordCache[doc.id] = w
        return w
    }

    /// Save an import. The same text (same clip file) isn't saved twice.
    @discardableResult
    func add(_ text: ImportedText) -> ReaderDocument {
        let (doc, file) = ReaderDocument.make(text)
        if let existing = documents.first(where: { $0.clipTextID == doc.clipTextID }) { return existing }
        try? file.write(to: fileURL(doc), options: .atomic)
        documents.insert(doc, at: 0)
        save()
        return doc
    }

    func delete(_ id: String) {
        guard let doc = document(id) else { return }
        try? FileManager.default.removeItem(at: fileURL(doc))
        PlaylistStore.shared.removeReadings(text: doc.clipTextID)
        documents.removeAll { $0.id == id }
        wordCache[id] = nil
        save()
    }

    func rename(_ id: String, to title: String) {
        guard let i = documents.firstIndex(where: { $0.id == id }) else { return }
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        documents[i].title = t
        save()
    }

    /// Where the phone's preview (or the clip) got to.
    func setPosition(_ id: String, _ word: Int) {
        guard let i = documents.firstIndex(where: { $0.id == id }), documents[i].position != word else { return }
        documents[i].position = max(0, min(word, documents[i].wordCount))
        save()
    }

    /// 0…1: the clip's `progress_word` when it has the text, else the phone's position.
    func fraction(_ doc: ReaderDocument) -> Double {
        // A finished text saves word 0 on the clip: then the phone's own position says more.
        if let c = clipTexts[doc.clipTextID], c.words > 0, c.progressWord > 0 { return c.fraction }
        return doc.fraction
    }

    func minutes(_ doc: ReaderDocument) -> Int {
        RSVPTiming.minutes(totalMs: RSVPTiming.totalMs(words(doc), wpm: wpm))
    }

    /// Read `GET /texts` (only while connected, so it never opens a session by itself).
    func refreshClipProgress(session: ClipSession) async {
        guard session.isConnected, let texts = try? await session.client.texts() else { return }
        clipTexts = Dictionary(texts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for t in texts {
            if let d = document(clipTextID: t.id), t.progressWord > 0 { setPosition(d.id, t.progressWord) }
        }
    }

    func recordClipTexts(_ texts: [ClipText]) {
        clipTexts = Dictionary(texts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: Fonts

    static func key(_ s: FontSelection) -> String { "\(s.familyID)|\((s.weight * 100).rounded() / 100)|\(s.italic)" }

    /// The display name of a typeface ("SF Pro Rounded Medium").
    static func name(_ s: FontSelection) -> String {
        let c = CreateFonts.choice(s.familyID)
        let weight = CreateFonts.weights(c).min { abs($0.weight - s.weight) < abs($1.weight - s.weight) }?.name
        return [c.name, weight == "Regular" ? nil : weight, s.italic ? "Italic" : nil].compactMap { $0 }.joined(separator: " ")
    }

    /// The font for the current typeface and ORP colour: memory, disk, else rendered (≈ 1 s).
    @discardableResult
    func prepareCurrentFont() async -> ReaderFont? {
        if let f = currentFont, f.accentORP == accentORP { return f }
        let sel = typeface
        let f = await font(for: sel)?.withAccentORP(accentORP)
        if sel == typeface { currentFont = f }
        return f
    }

    /// The font rendered from `selection` (white/accent atlases; the ORP colour is chosen per use).
    func font(for selection: FontSelection) async -> ReaderFont? {
        let key = Self.key(selection)
        if let h = index.fontHashes[key], let f = await font(hash: h) { return f }
        isRenderingFont = true
        defer { isRenderingFont = false }
        let name = Self.name(selection)
        let rendered: ReaderFont? = await Task.detached(priority: .userInitiated) {
            try? ReaderFontRenderer.render(name: name) { size in CreateFonts.ctFont(selection, size: size) }
        }.value
        guard let f = rendered else { return nil }
        fonts[f.hash] = f
        index.fontHashes[key] = f.hash
        index.fontSources[f.hash] = FontSource(selection: selection, name: name)
        save()
        let folder = dir.appendingPathComponent("fonts/\(f.hash)", isDirectory: true)
        let meta = FontMeta(name: name, normal: f.normal.document, compact: f.compact.document, normalSize: f.normal.pointSize,
                            compactSize: f.compact.pointSize, normalCap: f.normal.capHeight, compactCap: f.compact.capHeight)
        let atlases = f.allAtlases.map(\.data)
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (n, d) in zip(["n", "na", "c", "ca"], atlases) { try? d.write(to: folder.appendingPathComponent("\(n).hca"), options: .atomic) }
            if let m = try? JSONEncoder().encode(meta) { try? m.write(to: folder.appendingPathComponent("font.json"), options: .atomic) }
        }
        #if DEBUG
        print("READER_FONT \(name): normal \(f.normal.pointSize) pt (cap \(Int(f.normal.capHeight.rounded())) px) cell \(f.normal.document.cellW)×\(f.normal.document.cellH), compact \(f.compact.pointSize) pt cell \(f.compact.document.cellW)×\(f.compact.document.cellH); atlases " + f.allAtlases.map { "\($0.id.split(separator: "-").last!) \($0.data.count.byteString)" }.joined(separator: ", "))
        #endif
        return f
    }

    /// A font by hash: memory, then disk (decoded off the main actor), then re-rendered from its typeface.
    func font(hash: String) async -> ReaderFont? {
        if let f = fonts[hash] { return f }
        let folder = dir.appendingPathComponent("fonts/\(hash)", isDirectory: true)
        let loaded: ReaderFont? = await Task.detached(priority: .userInitiated) {
            guard let m = try? Data(contentsOf: folder.appendingPathComponent("font.json")),
                  let meta = try? JSONDecoder().decode(FontMeta.self, from: m) else { return nil }
            let datas = ["n", "na", "c", "ca"].compactMap { try? Data(contentsOf: folder.appendingPathComponent("\($0).hca")) }
            return try? ReaderFont.restore(hash: hash, name: meta.name, accentORP: true, normal: meta.normal, compact: meta.compact,
                                           normalSize: meta.normalSize, compactSize: meta.compactSize, normalCap: meta.normalCap,
                                           compactCap: meta.compactCap, atlases: datas)
        }.value
        if let loaded, loaded.hash == hash {
            fonts[hash] = loaded
            return loaded
        }
        if let src = index.fontSources[hash] {
            index.fontHashes[Self.key(src.selection)] = nil
            let f = await font(for: src.selection)
            return f?.hash == hash ? f : nil
        }
        return nil
    }

    /// A font by its `/fonts` id (`reader-font-<hash>` or `…-w`).
    func font(id: String) async -> ReaderFont? {
        guard let h = ReaderFontRenderer.hash(inID: id) else { return nil }
        return await font(hash: h)?.withAccentORP(!id.hasSuffix("-w"))
    }

    /// One frame as the clip would show it (thumbnails): a word of the text in that font.
    func previewFrame(textID: String, fontID: String, word: Int? = nil) async -> RGB565Frame? {
        guard let font = await font(id: fontID) else { return nil }
        let doc = document(clipTextID: textID)
        let ws = doc.map(words) ?? []
        let i = word ?? doc.map { d in min(d.position, max(0, ws.count - 1)) } ?? 0
        let text = ws.indices.contains(i) ? ws[i].text : "lecture"
        let bound = ReaderBoundFont(font)
        return await Task.detached { ReaderPreview.frame(word: text, font: bound) }.value
    }

    // MARK: Items and sending

    /// The rotation item for a text with the current settings (font must be ready).
    func item(for doc: ReaderDocument, font: ReaderFont) -> PlaylistItem {
        .reader(text: doc.clipTextID, font: font.id, wpm: wpm)
    }

    /// The texts and fonts a playlist's reader items need, from the phone's store.
    func content(for playlist: Playlist) async -> (texts: [ReaderPusher.Text], fonts: [ReaderFont]) {
        let texts: [ReaderPusher.Text] = playlist.textIDs.compactMap { id in
            guard let d = document(clipTextID: id), let data = file(d) else { return nil }
            return ReaderPusher.Text(id: id, data: data, title: d.title)
        }
        var fonts: [ReaderFont] = []
        for id in playlist.fontIDs { if let f = await font(id: id) { fonts.append(f) } }
        return (texts, fonts)
    }

    /// Puts what the playlist's reader items need on the clip (before a Send PUTs the playlist) and
    /// returns the playlist without reader items whose text or font couldn't go there.
    func prepare(_ playlist: Playlist, client: any ClipClient) async throws -> Playlist {
        guard !playlist.textIDs.isEmpty else { return playlist }
        let (texts, fonts) = await content(for: playlist)
        let r = try await ReaderPusher(client: client).ensure(texts: texts, fonts: fonts)
        let knownTexts = Set(texts.map(\.id)), knownFonts = Set(fonts.map(\.id))
        let missingTexts = Set(playlist.textIDs).subtracting(knownTexts).union(r.failedTexts)
        let missingFonts = Set(playlist.fontIDs).subtracting(knownFonts).union(r.failedFonts)
        return ReaderPusher.filter(playlist, failedTexts: missingTexts, failedFonts: missingFonts)
    }

    // MARK: Share inbox

    /// Import what the Share Extension saved (called when the app becomes active).
    func importInbox() async {
        guard !importingInbox else { return }
        importingInbox = true
        defer { importingInbox = false }
        var problem: String?
        for (url, item) in ReaderInbox.pending() {
            do {
                let text = try await Self.importedText(item)
                var t = text
                t.kind = .shared
                add(t)
                ReaderInbox.remove(url)
            } catch {
                problem = "Couldn’t open a shared link: \((error as? LocalizedError)?.errorDescription ?? "check your connection.")"
                // Keep a link for next time unless it's been waiting more than a day.
                if Date().timeIntervalSince(item.createdAt) > 86_400 { ReaderInbox.remove(url) }
            }
        }
        inboxProblem = problem
    }

    static func importedText(_ item: ReaderInboxItem) async throws -> ImportedText {
        if let html = item.html, !html.isEmpty {
            var t = TextImporter.html(html, url: item.url)
            if t.body.split(separator: " ").count < 30, let text = item.text, !text.isEmpty {
                t = TextImporter.plain(text, fallbackTitle: item.title, kind: .web)
                t.sourceURL = item.url
            }
            if let title = item.title, !title.isEmpty, t.title.isEmpty { t.title = title }
            return t
        }
        if let text = item.text, !text.isEmpty {
            var t = TextImporter.plain(text, fallbackTitle: nil)
            if let title = item.title, !title.isEmpty, title != TextImporter.firstWords(text) { t.title = title }
            t.sourceURL = item.url
            return t
        }
        if let url = item.url { return try await TextImporter.fetch(url) }
        throw TextImportError.empty
    }

    func dismissInboxProblem() { inboxProblem = nil }

    // MARK: Debug

    #if DEBUG
    /// `-PixelClipReaderDemo`: three texts (an article, a short story with chapters, a note).
    func seedDemo() {
        guard documents.isEmpty else { return }
        add(TextImporter.plain(ReaderDemoTexts.note, fallbackTitle: nil, kind: .pasted))
        var trains = TextImporter.plain(ReaderDemoTexts.trains, fallbackTitle: nil, kind: .web)
        trains.origin = "example.com"
        trains.sourceURL = URL(string: "https://example.com/trains-de-nuit")
        add(trains)
        add(TextImporter.markdown(ReaderDemoTexts.horla, fallbackTitle: "la-liseuse-de-minuit.md"))
        if let i = documents.firstIndex(where: { $0.kind == .markdown }) { documents[i].position = documents[i].wordCount / 3 }
        if let i = documents.firstIndex(where: { $0.kind == .web }) { documents[i].position = documents[i].wordCount * 3 / 4 }
        save()
    }
    #endif
}
