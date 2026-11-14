import Foundation

/// Puts reader content on the clip in the order the firmware needs: font atlases (if missing) →
/// `PUT /fonts/{id}` → `PUT /texts/{id}` (if missing) → the composed playlist (same `SyncEngine`
/// path as every other send, so the library's pictures and Tonight's moments stay) → clean-up of
/// reader atlases nothing uses any more. A reader item whose text or font couldn't be stored is
/// left out of the playlist rather than failing the whole send (the clip would answer 422).
public struct ReaderPusher: Sendable {
    public struct Text: Sendable, Equatable {
        public var id: String
        public var data: Data
        public var title: String
        public init(id: String, data: Data, title: String) { self.id = id; self.data = data; self.title = title }
    }

    public enum Step: Sendable, Equatable {
        case reading
        case atlas(index: Int, of: Int, fraction: Double)
        case font
        case text(index: Int, of: Int, title: String)
        case playlist
        case cleaning
    }

    public struct Result: Sendable, Equatable {
        public var uploadedAtlases: [String] = []
        public var fontsPut: [String] = []
        public var textsPut: [String] = []
        public var textsUnchanged: [String] = []
        /// Content the clip refused (413 full, 422 rejected): reader items using it were left out.
        public var failedTexts: [String] = []
        public var failedFonts: [String] = []
        public var deletedAtlases: [String] = []
        public var bytesSent = 0
        /// The library/playlist sync, when `push` ran one.
        public var report: SyncReport?
        /// The playlist that was PUT.
        public var playlist: Playlist?
        public var firstClipError: ClipError?
    }

    public let client: any ClipClient
    public init(client: any ClipClient) { self.client = client }

    /// Make sure the clip holds these fonts and texts. Throws only when the clip stops answering.
    public func ensure(texts: [Text], fonts: [ReaderFont], progress: @escaping @Sendable (Step) -> Void = { _ in }) async throws -> Result {
        var result = Result()
        progress(.reading)
        let remote = try await client.assets()
        let remoteSHA = Dictionary(remote.map { ($0.id, $0.sha256.lowercased()) }, uniquingKeysWith: { a, _ in a })

        // Atlases, then the documents that point at them.
        var atlases: [LocalAsset] = []
        for f in fonts { for a in f.atlases where !atlases.contains(where: { $0.id == a.id }) { atlases.append(a) } }
        let missing = atlases.filter { remoteSHA[$0.id] != $0.sha256 }
        var failedAtlases = Set<String>()
        for (i, a) in missing.enumerated() {
            progress(.atlas(index: i + 1, of: missing.count, fraction: 0))
            do {
                let r = try await client.putAsset(id: a.id, data: a.data) { f in progress(.atlas(index: i + 1, of: missing.count, fraction: f)) }
                if case .created = r { result.uploadedAtlases.append(a.id); result.bytesSent += a.data.count }
            } catch {
                if (error as? ClipError)?.isUnreachable == true || error is URLError { throw error }
                failedAtlases.insert(a.id)
                result.firstClipError = result.firstClipError ?? (error as? ClipError)
            }
        }
        for f in fonts {
            progress(.font)
            guard f.document.atlasIDs.allSatisfy({ !failedAtlases.contains($0) }) else { result.failedFonts.append(f.id); continue }
            do {
                try await client.putFont(id: f.id, f.document)
                result.fontsPut.append(f.id)
            } catch {
                if (error as? ClipError)?.isUnreachable == true || error is URLError { throw error }
                result.failedFonts.append(f.id)
                result.firstClipError = result.firstClipError ?? (error as? ClipError)
            }
        }

        // Texts the clip doesn't have yet (same id = same content: the id is a hash of the file).
        let remoteTexts = (try? await client.texts()) ?? []
        let present = Set(remoteTexts.map(\.id))
        let needed = texts.filter { !present.contains($0.id) }
        result.textsUnchanged = texts.filter { present.contains($0.id) }.map(\.id)
        for (i, t) in needed.enumerated() {
            progress(.text(index: i + 1, of: needed.count, title: t.title))
            do {
                switch try await client.putText(id: t.id, data: t.data) {
                case .created: result.textsPut.append(t.id); result.bytesSent += t.data.count
                case .alreadyPresent: result.textsUnchanged.append(t.id)
                }
            } catch {
                if (error as? ClipError)?.isUnreachable == true || error is URLError { throw error }
                result.failedTexts.append(t.id)
                result.firstClipError = result.firstClipError ?? (error as? ClipError)
            }
        }
        return result
    }

    /// Reader items whose text or font isn't available are dropped.
    public static func filter(_ playlist: Playlist, failedTexts: Set<String>, failedFonts: Set<String>) -> Playlist {
        guard !failedTexts.isEmpty || !failedFonts.isEmpty else { return playlist }
        func ok(_ text: String?, _ font: String?) -> Bool {
            !(text.map(failedTexts.contains) ?? false) && !(font.map(failedFonts.contains) ?? false)
        }
        var p = playlist
        p.items = p.items.filter { $0.type != .reader || ok($0.text, $0.font) }
        p.queue = p.queue?.filter { $0.type != .reader || ok($0.text, $0.font) }
        if p.queue?.isEmpty == true { p.queue = nil }
        return p
    }

    /// The whole send: reader content, then the composed playlist with its library assets (orphans
    /// deleted, reader atlases protected), then unused reader atlases, then the session end.
    public func push(texts: [Text], fonts: [ReaderFont], playlist: Playlist, libraryAssets: [LocalAsset] = [],
                     time: TimeSync? = .now(), endSession: Bool = true, cleanUp: Bool = true,
                     progress: @escaping @Sendable (Step) -> Void = { _ in }) async throws -> Result {
        var result = try await ensure(texts: texts, fonts: fonts, progress: progress)
        let target = Self.filter(playlist, failedTexts: Set(result.failedTexts), failedFonts: Set(result.failedFonts))
        progress(.playlist)
        let options = SyncOptions(deleteOrphans: true, setTime: time != nil, endSession: false)
        let timeSync = time ?? .now()
        let report = await SyncEngine(client: client).sync(local: libraryAssets, playlist: target, options: options, timeSource: { timeSync })
        result.report = report
        if report.lostConnection { throw ClipError.unreachable(report.failures.last?.message ?? "Lost the clip.") }
        result.playlist = report.playlistUpdated ? target : nil
        if let f = report.failures.first(where: { $0.step == "playlist" }) {
            throw f.clipError ?? ClipError.badResponse(f.message)
        }
        if cleanUp {
            progress(.cleaning)
            result.deletedAtlases = try await cleanUnusedAtlases(keeping: target)
        }
        if endSession { try await client.endSession() }
        return result
    }

    /// Deletes `reader-font-*` atlases no reader item of `playlist` uses.
    public func cleanUnusedAtlases(keeping playlist: Playlist) async throws -> [String] {
        let keep = Set(playlist.fontIDs.compactMap { ReaderFontRenderer.hash(inID: $0) })
        var deleted: [String] = []
        for a in try await client.assets() where a.id.hasPrefix(ReaderFontRenderer.assetPrefix) {
            guard let h = ReaderFontRenderer.hash(inID: a.id), !keep.contains(h) else { continue }
            do { try await client.deleteAsset(id: a.id); deleted.append(a.id) } catch {
                if (error as? ClipError)?.isUnreachable == true { throw error }
            }
        }
        return deleted
    }
}

// MARK: - The Oracle's bundle and fonts (PROTOCOL §5f.1, §5f.2)

extension ReaderPusher {
    public struct OracleReaders: Sendable, Equatable {
        /// The playlist to PUT: oracles whose bundle or body font couldn't go on the clip are left out, one whose
        /// big font couldn't loses `font_big` (the clip would refuse them with 422).
        public var playlist: Playlist
        public var result: Result
        /// Older `tarot-reader-*` bundles deleted from the clip.
        public var deletedTexts: [String] = []
        /// Older `tarot-font-*` / `tarot-big-*` atlases deleted from the clip.
        public var deletedAtlases: [String] = []
    }

    /// Puts what the playlist's oracles need besides their deck, keys and notes on the clip, in the firmware's
    /// order (font atlases the clip lacks → `PUT /fonts` → `PUT /texts` for bundles it lacks), then leaves out
    /// oracles whose bundle or body font isn't there (not in `texts` / `fonts`, or refused) and strips a missing
    /// big font; and deletes the `tarot-reader-*` bundles and `tarot-font<pt>-*` / `tarot-big<pt>-*` atlases (any size) neither the
    /// new playlist nor `keep` (what the clip's current playlist names) uses; with `keep` nil (the clip's
    /// playlist unknown) nothing is deleted. Throws only when the clip stops answering.
    public func prepareOracleReaders(_ playlist: Playlist, texts: [Text], fonts: [ReaderFont], keep: Playlist?,
                                     progress: @escaping @Sendable (Step) -> Void = { _ in }) async throws -> OracleReaders {
        let wantedTexts = Set(playlist.oracleReaderIDs), wantedFonts = Set(playlist.oracleFontIDs)
        let texts = texts.filter { wantedTexts.contains($0.id) }, fonts = fonts.filter { wantedFonts.contains($0.id) }
        var result = Result()
        if !wantedTexts.isEmpty {
            result = try await ensure(texts: texts, fonts: fonts, progress: progress)
        }
        let missingTexts = wantedTexts.subtracting(texts.map(\.id)).union(result.failedTexts)
        let missingFonts = wantedFonts.subtracting(fonts.map(\.id)).union(result.failedFonts)
        let out = playlist.withoutUnavailableOracles(missingTexts: missingTexts, missingFonts: missingFonts)
        var deletedTexts: [String] = [], deletedAtlases: [String] = []
        if let keep {
            func unreachable(_ e: any Error) -> Bool { (e as? ClipError)?.isUnreachable == true || e is URLError }
            let keepTexts = Set(keep.oracleReaderIDs).union(out.oracleReaderIDs)
            for t in (try? await client.texts()) ?? [] where t.id.hasPrefix(ReaderBundle.textPrefix) && !keepTexts.contains(t.id) {
                do { try await client.deleteText(id: t.id); deletedTexts.append(t.id) } catch { if unreachable(error) { throw error } }
            }
            let keepFonts = Set((keep.oracleFontIDs + out.oracleFontIDs).compactMap(TarotFonts.fontKey(inID:)))
            for a in (try? await client.assets()) ?? [] {
                guard let key = TarotFonts.fontKey(inID: a.id), !keepFonts.contains(key) else { continue }
                do { try await client.deleteAsset(id: a.id); deletedAtlases.append(a.id) } catch { if unreachable(error) { throw error } }
            }
        }
        return OracleReaders(playlist: out, result: result, deletedTexts: deletedTexts, deletedAtlases: deletedAtlases)
    }
}
