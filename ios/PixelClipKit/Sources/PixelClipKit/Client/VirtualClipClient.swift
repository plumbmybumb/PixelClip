import CoreGraphics
import Foundation

/// An in-memory emulation of the clip: storage, playlist, config, clock, screenshot and a
/// playback engine that renders what the screen would show. Lets the whole app run on the
/// simulator with no hardware, and backs the SyncEngine tests.
///
/// Mirrors firmware/README.md "Protocol interpretations":
/// - 409 `exists` only for the same id with the same SHA-256 and size.
/// - 400 `invalid_id`, 422 `malformed` (bad .hca, a non-atlas asset that isn't 536×240, or a
///   strip that isn't one frame 240 px tall and 537–8192 px wide), 413 `no_space` / `too_many_assets` (> 256).
/// - PUT /playlist: unknown id or a glyph atlas → 422 `unknown_asset`; bad values (negative
///   durations, `from == until`, a bad `scroll` block, > 64 queue entries, bad queue ids, `clock`/`text`
///   in the queue) → 422 `invalid_playlist`.
/// - PROTOCOL §3 "Display during a session": by default (`display_during_upload` true) the panel keeps
///   playing during an upload session and `/show`, `/next`, `/brightness` and `/screenshot` are live.
///   With `display_during_upload:false` the panel is off for the whole session: queue entries don't
///   fire then (they fire when the session ends if still within 600 s), see `PlaybackEngine`.
/// - The Bluetooth doorbell (§3, `VirtualDoorbell`): `bleWake()` turns the Wi‑Fi on and starts a
///   session like a long press (refused below 3.5 V off USB; not advertising when `ble_wake` is false),
///   `bleStatus()` is the `status` characteristic, `bleEnd()` the `0x02` write.
/// - Strips (`is_strip`) scroll a 536-px window per the item's `scroll` block (`StripScroller`);
///   without one they show their first 536 px.
/// - /show without a duration plays 60 s; unknown id → 404 `unknown_asset`.
/// - Panel-off mode only: /show, /next, /prev, /brightness become visible (and "show" timers start)
///   when the session ends; /screenshot returns the frame that will appear on resume.
/// - Config limits → 422 `invalid_config`.
/// - Reader mode (§5c): `PUT /texts/{id}` (UTF-8, ≤ 1 MB → 413 `too_large`, bad UTF-8 → 422 `malformed`,
///   409 for an identical text), `PUT /fonts/{id}` needs its atlases on the clip as glyph atlases of
///   the document's cell size with a frame per glyph (422 `unknown_asset` / `invalid_font`); a reader
///   item needs its text and font (422 `unknown_text` / `unknown_font`) and a wpm of 50–1500. The
///   panel shows the words through `ReaderPreview` (the port of `core/src/rsvp_paint.c`), from the
///   stored atlases; `POST /reader` pauses, resumes and seeks the reading on screen (409 `no_reader`
///   when there is none, 422 `invalid_word` past the end), as `firmware/components/net/http_api.c`. Texts and fonts count towards storage.
/// - Oracle (§5f.2–§5f.11): an `oracle` item names its phrase bundle (`id`, a stored text; 422 `unknown_text`, and 422
///   `invalid_playlist` without `[prompt]` or a card's reading), its body font (`font`, required) and optional big
///   font (`font_big`; 422 `unknown_font`), its deck `D` 108×206 (§5f.12) of `1 + cards` frames (a glyph atlas; absent → 422
///   `unknown_asset`, another size → 422 `invalid_playlist`), optional keys `K` 160×34 (§5f.12) of `cards` frames (same
///   errors; absent: no keyword row; notes `N` ignored); `cards` 3–78, `shake_g`
///   0.4–2.0, timings ≥ 0.
///   While one shows, `OracleMachine` runs (a tap arms, then a shake from `setShakeSource` or a tap deals; `POST
///   /oracle/draw {"cards"}`, `/turn`, `/back`; 409 `not_showing` when none is on screen, 422 `invalid_cards`) and
///   `OracleCompositor` draws the screens. §5f.8: while a draw is in progress (any state but waits) the item's end,
///   queue entries and windows wait until it is back at waits.
///   `/status` reports `oracle:<id>` and `"oracle":{…}` while one shows.
public actor VirtualClipClient: ClipClient {

    public struct Options: Sendable {
        public var latency: Duration
        /// Simulated WiFi throughput for uploads (bytes/second); 0 = instant.
        public var bytesPerSecond: Int
        public var storageTotal: Int
        public var maxAssets: Int
        public var deviceID: String
        public var firmware: String
        public init(latency: Duration = .milliseconds(60), bytesPerSecond: Int = 400_000,
                    storageTotal: Int = 12_582_912, maxAssets: Int = 256,
                    deviceID: String = "7c1e", firmware: String = "0.1.0-virtual") {
            self.latency = latency; self.bytesPerSecond = bytesPerSecond; self.storageTotal = storageTotal
            self.maxAssets = maxAssets; self.deviceID = deviceID; self.firmware = firmware
        }
        /// No delays: for tests.
        public static let instant = Options(latency: .zero, bytesPerSecond: 0)
    }

    /// What the virtual screen shows right now.
    public struct Display: Sendable {
        public var frame: RGB565Frame
        /// Panel brightness (0…255) combined with any fade ramp, as a 0…1 factor.
        public var level: Double
        public var currentID: String?
        public var playlistIndex: Int?
        /// The queue entry (moment) on screen, if any.
        public var queueID: String?
        /// What's on screen in `/status` terms: an asset id, `"scene:<name>"`, or nil (idle).
        public var nowShowing: String?
        /// False during an upload session in panel-off mode (`display_during_upload:false`).
        public var isAwake: Bool
        /// Changes whenever the pixels do (cheap change detection for previews).
        public var key: String
        /// What the engine shows.
        public var content: PlaybackEngine.Content = .idle
        /// The panel shows the frame turned 180° (PROTOCOL §4 Orientation). `frame` stays upright,
        /// like the firmware's framebuffer; a preview rotates it.
        public var flipped = false
        /// `/status.oracle` while an oracle shows (the app's Home follows the draw and the paragraph with it).
        public var oracle: ClipStatus.OracleStatus?
    }

    struct Stored {
        var data: Data
        var info: ClipAsset
        var file: HCAFile
        var timing: PlaybackEngine.AssetTiming
    }

    private let options: Options
    private let clock: @Sendable () -> Date
    private let bootDate: Date

    private var assets: [String: Stored] = [:]
    private var decoded: [String: [RGB565Frame]] = [:]
    private var playlistDoc: Playlist = .empty
    private var cfg: ClipConfig = .deviceDefaults
    private var timeOffset: TimeInterval = 0
    private var synced = false
    private var liveBrightness: Int?
    private var engine: PlaybackEngine
    private var lastRequest: Date
    private var inSession = false
    private var reachable = true
    /// The doorbell can be heard (in range, powered). Separate from `reachable` (the Wi‑Fi).
    private var bluetoothPresent = true
    private var failingUploads: Set<String> = []
    private var idleFrame: RGB565Frame?
    private var sceneFrames: [String: RGB565Frame] = [:]
    private var batlog: [String] = []
    private var batteryMv = 3920
    private var batteryOverride: (pct: Int, usb: Bool)?
    private struct StoredText { var data: Data; var title: String; var words: [RSVPWord] }
    private var storedTexts: [String: StoredText] = [:]
    private var storedFonts: [String: ReaderFontDocument] = [:]
    private var boundFonts: [String: ReaderBoundFont] = [:]
    private var shakeSource: (@Sendable () -> Double?)?
    // Oracle (§5f)
    private var oracle: (item: OracleItem, machine: OracleMachine)?
    private var oracleSeed: UInt32?
    /// §5f.1: parsed phrase bundles by `/texts` id, and the last paragraph's layout (the costly part of a frame).
    private var oracleReaders: [String: SentenceReader] = [:]

    /// Requests received over Wi‑Fi (HTTP), as "METHOD /path" (for tests and the debug log).
    public private(set) var requestLog: [String] = []
    /// Requests received over the Bluetooth fast lane (`VirtualFastLane`), as "METHOD /path".
    public private(set) var fastLaneLog: [String] = []

    /// How a request reaches the virtual clip. `VirtualFastLane` runs its requests with
    /// `.bluetooth`: like the firmware's fast lane they need the clip to be heard over Bluetooth
    /// (not its Wi‑Fi), never start a session and never touch the session idle timer.
    public enum Transport: Sendable { case wifi, bluetooth }
    @TaskLocal public static var transport: Transport = .wifi
    public private(set) var sessionEndCount = 0
    public private(set) var otaImages: [Data] = []

    public init(options: Options = Options(), clock: @escaping @Sendable () -> Date = { Date() }) {
        self.options = options
        self.clock = clock
        let now = clock()
        bootDate = now
        lastRequest = now
        engine = PlaybackEngine(now: now)
    }

    // MARK: Test & debug controls

    /// False = the clip is not in upload mode (requests fail like an unjoined hotspot).
    public func setReachable(_ value: Bool) { reachable = value }
    /// False = the doorbell isn't heard (out of range): `bleStatus()` is nil and `bleWake()` refuses.
    public func setBluetoothPresent(_ value: Bool) { bluetoothPresent = value }
    public func failUploads(of ids: Set<String>) { failingUploads = ids }
    public func setBatteryMillivolts(_ mv: Int) { batteryMv = mv }
    /// Debug/screenshots: report a fixed percentage (voltage from the firmware's curve) and USB state.
    public func setBattery(pct: Int, usb: Bool) {
        batteryOverride = (min(max(pct, 0), 100), usb)
        batteryMv = Self.millivolts(forPct: pct)
    }

    /// The firmware's mV → % curve (`components/power/power.c`), inverted.
    static func millivolts(forPct pct: Int) -> Int {
        let curve: [(mv: Int, pct: Int)] = [(4200, 100), (4150, 95), (4110, 90), (4080, 85), (4020, 80), (3980, 75), (3950, 70),
                                            (3910, 65), (3870, 60), (3850, 55), (3840, 50), (3820, 45), (3800, 40), (3790, 35),
                                            (3770, 30), (3750, 25), (3730, 20), (3710, 15), (3690, 10), (3610, 5), (3400, 0)]
        let p = min(max(pct, 0), 100)
        for i in 1..<curve.count where p >= curve[i].pct {
            let hi = curve[i - 1], lo = curve[i]
            return lo.mv + (p - lo.pct) * (hi.mv - lo.mv) / max(1, hi.pct - lo.pct)
        }
        return 3400
    }
    public func storedAssetData(_ id: String) -> Data? { assets[id]?.data }
    public var isInSession: Bool { inSession }

    // MARK: Motion sensor controls

    /// Where the virtual clip's gravity comes from: a closure returning the display-frame gravity
    /// (the app feeds the iPhone's own CoreMotion tilt when it has one), else `simulatedPose`.
    public func setGravitySource(_ source: (@Sendable () -> IMUVector?)?) { gravitySource = source }
    /// The pose the virtual clip is "held" in when no gravity source answers (default upright).
    public func setSimulatedPose(_ g: IMUVector) { simulatedPose = g }
    /// False = no accelerometer found (`present:false`, 409 `no_imu`).
    public func setIMUPresent(_ value: Bool) { imuPresent = value }
    /// True = it's being moved: readings wobble and a capture answers 422 `not_still`.
    public func setIMUShaking(_ value: Bool) { imuShaking = value }

    /// Wipe everything back to factory state.
    public func reset() {
        assets = [:]; decoded = [:]; playlistDoc = .empty; cfg = .deviceDefaults
        synced = false; liveBrightness = nil; requestLog = []; fastLaneLog = []; sessionEndCount = 0; inSession = false
        idleFrame = nil; timeOffset = 0
        storedTexts = [:]; storedFonts = [:]; boundFonts = [:]
        lastBLEWake = .none
        imuMap = .identity; imuCalibrated = false; imuCaptures = (nil, nil)
        oracle = nil; oracleReaders = [:]
        engine = PlaybackEngine(now: deviceNow)
    }

    // MARK: ClipClient

    public func status() async throws -> ClipStatus {
        try await enter("GET /status")
        let now = clock()
        let used = usedBytes
        let st = playbackState()
        let uptime = Int(now.timeIntervalSince(bootDate))
        let mv = batteryOverride == nil ? max(3400, batteryMv - uptime / 20) : batteryMv
        let pct = batteryOverride?.pct ?? min(100, max(0, (mv - 3500) * 100 / 650))
        let current: String?
        switch st.content {
        case .scene(let name): current = "scene:\(name)"
        case .words: current = "scene:words"
        case .board(let sheet, _, _, _, _, _): current = "board:\(sheet)"
        case .reader(let text, _, _, _), .readerEnd(let text, _, _, _): current = "reader:\(text)"
        case .oracle(let o): current = "oracle:\(o.id)"
        default: current = st.currentID
        }
        let oracleMachine = oracleTick(st)
        let pending = engine.pendingQueue()
        return ClipStatus(
            device: .init(name: cfg.name ?? "PixelClip", id: options.deviceID, fw: options.firmware,
                          hw: "virtual", protocolVersion: clipProtocolVersion),
            battery: .init(mv: mv, pct: pct, charging: batteryOverride?.usb ?? false, usbPresent: batteryOverride?.usb ?? false),
            storage: .init(total: options.storageTotal, used: used, free: options.storageTotal - used),
            playlist: .init(count: playlistDoc.items.count, index: playlistDoc.items.isEmpty ? -1 : (st.playlistIndex ?? 0),
                            current: current),
            time: .init(epoch: Int(now.timeIntervalSince1970 + timeOffset), tzOffsetS: cfg.tzOffsetS ?? 0, synced: synced),
            session: .init(idleS: 0, timeoutS: cfg.uploadTimeoutS ?? 120, alwaysOn: cfg.wifiAlwaysOn ?? false),
            uptimeS: uptime,
            queue: .init(pending: pending.count, nextAt: pending.first?.at, done: engine.doneQueueIDs.count),
            clockOk: synced,
            orientation: .init(mode: cfg.orientation ?? .auto, flipped: isFlipped),
            oracle: oracleMachine?.status(at: deviceNow))
    }

    /// PROTOCOL §4 Orientation. The virtual clip is never worn, so `auto` keeps it the right way up;
    /// only a forced `flipped` turns it.
    private var isFlipped: Bool { cfg.orientation == .flipped }

    public func assets() async throws -> [ClipAsset] {
        try await enter("GET /assets")
        return assets.values.map(\.info).sorted { $0.id < $1.id }
    }

    public func putAsset(id: String, data: Data, progress: ProgressHandler?) async throws -> AssetPutResult {
        try await enter("PUT /assets/\(id)")
        guard HCA.isValidAssetID(id) else { throw err(400, "invalid_id", "Asset ids are [a-z0-9][a-z0-9-]{0,31}.") }
        let sha = Hashing.sha256Hex(data)
        // Decided from the headers, before the body.
        if let existing = assets[id], existing.info.sha256 == sha, existing.info.size == data.count { return .alreadyPresent }
        if options.bytesPerSecond > 0 {
            let steps = 10
            let total = Double(data.count) / Double(options.bytesPerSecond)
            for i in 1...steps {
                try await Task.sleep(for: .seconds(total / Double(steps)))
                progress?(Double(i) / Double(steps))
            }
        } else {
            progress?(1)
        }
        if failingUploads.contains(id) { throw err(500, "internal", "Simulated write failure.") }
        let file: HCAFile
        do { file = try HCAFile(data: data) } catch {
            throw err(422, "malformed", "Not a valid .hca file (\(error)).")
        }
        if file.isStrip {
            guard !file.isGlyphAtlas, file.frameCount == 1, file.height == ClipCanvas.height,
                  PlaylistItem.Scroll.stripWidths.contains(file.width) else {
                throw err(422, "malformed", "A strip is one frame, 240 px tall and 537–8192 px wide.")
            }
        } else if !file.isGlyphAtlas, file.width != ClipCanvas.width || file.height != ClipCanvas.height {
            throw err(422, "malformed", "Assets must be 536×240 unless they are glyph atlases or strips.")
        }
        if assets[id] == nil, assets.count >= options.maxAssets {
            throw err(413, "too_many_assets", "The clip holds at most \(options.maxAssets) assets.")
        }
        let used = usedBytes - (assets[id]?.info.size ?? 0)
        guard used + data.count <= options.storageTotal else { throw err(413, "no_space", "Not enough space on the clip.") }
        let info = ClipAsset(id: id, size: data.count, sha256: sha, width: file.width, height: file.height,
                             frames: file.frameCount, atlas: file.isGlyphAtlas, strip: file.isStrip ? true : nil)
        assets[id] = Stored(data: data, info: info, file: file, timing: .init(file: file))
        decoded[id] = nil
        boundFonts = boundFonts.filter { !(storedFonts[$0.key]?.atlasIDs.contains(id) ?? false) }
        return .created(AssetPutResponse(id: id, size: data.count, sha256: sha))
    }

    public func deleteAsset(id: String) async throws {
        try await enter("DELETE /assets/\(id)")
        guard assets.removeValue(forKey: id) != nil else { throw err(404, "not_found", "No asset “\(id)”.") }
        decoded[id] = nil
        let filtered = playlistDoc.items.filter { !$0.assetRefs.contains(id) }
        if filtered.count != playlistDoc.items.count {
            playlistDoc.items = filtered
            engine.setPlaylist(playlistDoc, now: deviceNow)
        }
    }

    public func getAsset(id: String) async throws -> Data {
        try await enter("GET /assets/\(id)")
        guard let a = assets[id] else { throw err(404, "not_found", "No asset “\(id)”.") }
        return a.data
    }

    public func playlist() async throws -> Playlist {
        try await enter("GET /playlist")
        return playlistDoc
    }

    public func putPlaylist(_ playlist: Playlist) async throws {
        try await enter("PUT /playlist")
        guard playlist.version == 1 else { throw err(422, "invalid_playlist", "version must be 1.") }
        for item in playlist.items {
            if item.durationMs < 0 || (item.loops ?? 1) < 0 { throw err(422, "invalid_playlist", "Durations and loops must be ≥ 0.") }
            if let f = item.from, let u = item.until, f == u { throw err(422, "invalid_playlist", "Empty time window.") }
            try validateScroll(item.scroll)
            try validateContent(type: item.type, asset: item.id, scene: item.scene)
            if item.type == .reader { try validateReader(text: item.text, font: item.font, wpm: item.wpm, fromWord: item.fromWord) }
            if item.type == .oracle { try validateOracle(item) }
            if item.type == .board { try validateBoard(item) }
        }
        let queue = playlist.queue ?? []
        guard queue.count <= TonightPlan.maxMoments else { throw err(422, "invalid_playlist", "At most 64 queue entries.") }
        var queueIDs = Set<String>()
        for q in queue {
            guard Moment.isValidID(q.id) else { throw err(422, "invalid_playlist", "Queue ids are 1–40 printable characters.") }
            guard queueIDs.insert(q.id).inserted else { throw err(422, "invalid_playlist", "Queue ids must be unique.") }
            guard q.at > 0, (q.durationMs ?? 0) >= 0, [.asset, .scene, .reader, .oracle, .board].contains(q.type) else {
                throw err(422, "invalid_playlist", "Bad queue entry “\(q.id)”.")
            }
            try validateScroll(q.scroll)
            try validateContent(type: q.type, asset: q.asset, scene: q.scene)
            if q.type == .reader { try validateReader(text: q.text, font: q.font, wpm: q.wpm, fromWord: q.fromWord) }
            if q.type == .oracle { try validateOracle(q.asPlaylistItem) }
            if q.type == .board { try validateBoard(q.asPlaylistItem) }
        }
        playlistDoc = playlist
        engine.setPlaylist(playlist, now: deviceNow)
    }

    private func validateScroll(_ scroll: PlaylistItem.Scroll?) throws {
        guard let scroll else { return }
        guard PlaylistItem.Scroll.speedRange.contains(scroll.pxPerS), (0...PlaylistItem.Scroll.maxGap).contains(scroll.gapPx),
              (1...65535).contains(scroll.loops ?? 1) else {
            throw err(422, "invalid_playlist", "scroll: px_per_s is 10–400, gap_px 0–2000, loops ≥ 1.")
        }
    }

    private func validateContent(type: PlaylistItemType, asset: String?, scene: String?) throws {
        switch type {
        case .asset:
            guard let id = asset else { throw err(422, "invalid_playlist", "Asset entries need an asset id.") }
            guard let a = assets[id], !a.info.atlas,
                  a.info.isStrip || (a.info.width == ClipCanvas.width && a.info.height == ClipCanvas.height) else {
                throw err(422, "unknown_asset", "Unknown asset “\(id)”.")
            }
        case .scene:
            guard let scene, SceneCatalog.knownScenes.contains(scene) else {
                throw err(422, "invalid_playlist", "Unknown scene “\(scene ?? "")”.")
            }
            if scene == WordsScene.name {
                // §5b.1: `id` names the sheet: a stored .hca of 1…12 equal frames within the size limits.
                guard let id = asset, !id.isEmpty else { throw err(422, "invalid_playlist", "A words scene needs its sheet (`id`).") }
                guard let a = assets[id] else { throw err(422, "unknown_asset", "Unknown asset “\(id)”.") }
                guard WordsScene.isValidSheet(width: a.info.width, height: a.info.height, frames: a.info.frames), !a.info.isStrip else {
                    throw err(422, "invalid_playlist", "“\(id)” isn’t a words sheet (1–12 frames, ≤ 536×240, N·w·h ≤ 514 560).")
                }
            }
        default: break
        }
    }

    /// An oracle item (§5f.2): its fields; its phrase bundle (`id`, a `/texts` id; `reader`, when given, the same),
    /// its body font and optional big font (`/fonts`); its deck and keys with the frame counts `cards` implies. No
    /// text asset any more (`pages` is ignored), and no notes (§5f.7: ignored).
    private func validateOracle(_ item: PlaylistItem) throws {
        let cards = item.cards ?? 22
        guard Oracle.cardsRange.contains(cards), cards >= OracleItem.minCards else {
            throw err(422, "invalid_playlist", "cards is 3–78 (a row of three distinct cards).")
        }
        if let g = item.shakeG, !Oracle.shakeGRange.contains(g) { throw err(422, "invalid_playlist", "shake_g is 0.4–2.0.") }
        if [item.faceMs, item.pageMs, item.holdMs].contains(where: { ($0 ?? 0) < 0 }) {
            throw err(422, "invalid_playlist", "face_ms, page_ms and hold_ms must be ≥ 0.")
        }
        guard let id = item.id else { throw err(422, "invalid_playlist", "An oracle needs its phrase bundle (id).") }
        if let r = item.reader, r != id { throw err(422, "invalid_playlist", "“reader” is the same id as “id”.") }
        guard storedTexts[id] != nil else { throw err(422, "unknown_text", "Unknown text “\(id)” (the oracle's phrase bundle, PUT /texts first).") }
        // The bundle must carry what the clip writes: the prompt and every card's reading.
        if let bundle = oracleReaders[id] ?? storedTexts[id].map({ SentenceReader(bundle: $0.data) }) {
            oracleReaders[id] = bundle
            guard bundle.text("prompt") != nil, (0..<cards).allSatisfy({ bundle.field($0, .reading) != nil }) else {
                throw err(422, "invalid_playlist", "The phrase bundle “\(id)” lacks [prompt] or a card's reading.")
            }
        }
        guard let font = item.font else { throw err(422, "invalid_playlist", "An oracle needs its font.") }
        guard storedFonts[font] != nil else { throw err(422, "unknown_font", "Unknown font “\(font)” (PUT /fonts first).") }
        if let big = item.fontBig, storedFonts[big] == nil { throw err(422, "unknown_font", "Unknown font “\(big)” (PUT /fonts first).") }
        // §5f.12: the deck is 108×206 (frame 0 the back); another size is a misfitting atlas.
        guard let deck = item.deck else { throw err(422, "invalid_playlist", "An oracle needs its deck asset.") }
        guard let d = assets[deck] else { throw err(422, "unknown_asset", "Unknown asset “\(deck)”.") }
        let w = Oracle.cardWidth, h = Oracle.cardHeight, frames = Oracle.deckFrames(cards: cards)
        guard d.info.atlas, !d.info.isStrip, d.info.width == w, d.info.height == h, d.info.frames == frames else {
            throw err(422, "invalid_playlist", "“\(deck)” isn’t the oracle’s deck (\(w)×\(h), \(frames) frames).")
        }
        // §5f.12: the keys are optional (absent: no keyword row); given, a 160×34 atlas of `cards` frames.
        if let keys = item.keys {
            guard let k = assets[keys] else { throw err(422, "unknown_asset", "Unknown asset “\(keys)”.") }
            guard k.info.atlas, !k.info.isStrip, k.info.width == Oracle.keyWidth, k.info.height == Oracle.keyHeight,
                  k.info.frames == Oracle.keyFrames(cards: cards) else {
                throw err(422, "invalid_playlist", "“\(keys)” isn’t the oracle’s keys (\(Oracle.keyWidth)×\(Oracle.keyHeight), \(cards) frames).")
            }
        }
        // §5f.7: `notes` is accepted and ignored.
    }

    /// §5g: `id` names the sheet (1…48 equal frames, w ≤ 536, 16 ≤ h ≤ 240, N·w·h ≤ 1 048 576; the atlas flag unless
    /// 536×240), `rows` 1…47 with frames in range, `header` / `empty` in range, `scroll_px_s` 4…60.
    private func validateBoard(_ item: PlaylistItem) throws {
        guard let id = item.id, !id.isEmpty else { throw err(422, "invalid_playlist", "A board needs its sheet (`id`).") }
        guard let a = assets[id] else { throw err(422, "unknown_asset", "Unknown asset “\(id)”.") }
        let full = a.info.width == ClipCanvas.width && a.info.height == ClipCanvas.height
        guard Board.isValidSheet(width: a.info.width, height: a.info.height, frames: a.info.frames), !a.info.isStrip, full || a.info.atlas else {
            throw err(422, "invalid_playlist", "“\(id)” isn’t a board sheet (1–48 frames, w ≤ 536, 16 ≤ h ≤ 240, N·w·h ≤ 1 048 576).")
        }
        if let problem = Board.problem(item, sheetFrames: a.info.frames) { throw err(422, "invalid_playlist", problem) }
    }

    private func validateReader(text: String?, font: String?, wpm: Int?, fromWord: Int?) throws {
        guard let text, storedTexts[text] != nil else { throw err(422, "unknown_text", "Unknown text “\(text ?? "")”.") }
        guard let font, storedFonts[font] != nil else { throw err(422, "unknown_font", "Unknown reader font “\(font ?? "")”.") }
        if let wpm, !RSVPTiming.wpmRange.contains(wpm) { throw err(422, "invalid_playlist", "wpm is 50–1500.") }
        if let fromWord, fromWord < 0 { throw err(422, "invalid_playlist", "from_word must be ≥ 0.") }
    }

    public func config() async throws -> ClipConfig {
        try await enter("GET /config")
        return cfg
    }

    public func putConfig(_ patch: ClipConfig) async throws -> ClipConfig {
        try await enter("PUT /config")
        if let problem = patch.validationProblem { throw err(422, "invalid_config", problem) }
        let nameChanged = patch.name != nil && patch.name != cfg.name
        cfg = cfg.merging(patch)
        engine.tzOffsetS = cfg.tzOffsetS ?? 0
        // Switching the session display mode applies at once to a running session (over Wi‑Fi this
        // request is part of one; over Bluetooth there may be none, and the panel stays as it is).
        if patch.displayDuringUpload != nil, inSession { engine.setOutput(cfg.screenStaysOn, now: deviceNow) }
        if patch.brightness != nil { liveBrightness = nil }
        if nameChanged { idleFrame = nil }
        return cfg
    }

    public func setTime(_ time: TimeSync) async throws {
        try await enter("POST /time")
        guard (1_577_836_800...4_102_444_800).contains(time.epoch) else { throw err(422, "bad_request", "epoch must be in 2020…2100.") }
        timeOffset = TimeInterval(time.epoch) - clock().timeIntervalSince1970
        cfg.tzOffsetS = time.tzOffsetS
        synced = true
        engine.tzOffsetS = time.tzOffsetS
        engine.setClockSynced(now: deviceNow)
    }

    public func show(id: String, durationMs: Int?, scroll: PlaylistItem.Scroll?) async throws {
        try await enter("POST /show/\(id)")
        guard let stored = assets[id] else { throw err(404, "unknown_asset", "No asset “\(id)”.") }
        if var o = playlistDoc.oracleItem(for: id) {
            // An oracle's text asset shows as that oracle.
            o.durationMs = durationMs ?? 0
            o.transition = .cut
            o.from = nil; o.until = nil
            engine.show(o, now: deviceNow)
            return
        }
        let wordsUse = playlistDoc.items.contains { $0.isWords && $0.id == id }
            || (playlistDoc.queue ?? []).contains { $0.type == .scene && $0.scene == WordsScene.name && $0.asset == id }
        if wordsUse {
            // §5b.1: a sheet a words item or queue entry uses shows as that scene (like the oracle's borrow).
            engine.show(.words(sheet: id, durationMs: durationMs ?? 0, transition: .cut), now: deviceNow)
            return
        }
        if stored.info.atlas { throw err(404, "unknown_asset", "no such playable asset") }   // as http_api.c: an atlas nobody plays
        var item = PlaylistItem.asset(id, durationMs: durationMs ?? 0, transition: .cut)
        if stored.info.isStrip {
            // Like the firmware: the body's scroll, else the playlist item's for that asset, else defaults.
            // A show lasts its duration (60 s by default), so the strip runs as a tape.
            item.scroll = scroll ?? playlistDoc.showScroll(for: id) ?? PlaylistItem.Scroll(pxPerS: PlaylistItem.Scroll.defaultSpeed)
            item.scroll?.loops = nil
        }
        engine.show(item, now: deviceNow)
    }

    public func next() async throws {
        try await enter("POST /next")
        engine.next(now: deviceNow)
    }

    public func previous() async throws {
        try await enter("POST /prev")
        engine.previous(now: deviceNow)
    }

    public func setBrightness(_ value: Int) async throws {
        try await enter("POST /brightness")
        guard (0...255).contains(value) else { throw err(422, "bad_request", "value is 0–255.") }
        liveBrightness = value
    }

    public func screenshot() async throws -> RGB565Frame {
        try await enter("GET /screenshot")
        return render(playbackState())
    }

    public func ota(firmware: Data, progress: ProgressHandler?) async throws {
        try await enter("POST /ota")
        guard !firmware.isEmpty else { throw err(411, "length_required", "Empty image.") }
        let steps = 20
        for i in 1...steps {
            if options.bytesPerSecond > 0 {
                try await Task.sleep(for: .seconds(Double(firmware.count) / Double(options.bytesPerSecond) / Double(steps)))
            }
            progress?(Double(i) / Double(steps))
        }
        otaImages.append(firmware)
    }

    public func endSession() async throws {
        try await enter("POST /session/end")
        // Over Bluetooth with no session open there's nothing to end.
        guard inSession || Self.transport == .wifi else { return }
        sessionEndCount += 1
        inSession = false
        // Display comes back; anything queued during the session starts now (if within 600 s).
        engine.setOutput(true, now: deviceNow)
    }

    public func scenes() async throws -> SceneCatalog {
        try await enter("GET /scenes")
        let palette = SceneParamSpec.choices(["amber", "ocean", "forest", "candy", "mono"])
        // The app-side allow-list: the virtual clip never offers a scene the app has turned off.
        return SceneCatalog(scenes: SceneCatalog.enabledIDs.map { id in
            SceneCatalog.Scene(id: id, params: ["palette": palette, "density": .range(10, 100)])
        })
    }

    public func batteryLog() async throws -> String {
        try await enter("GET /batlog")
        let mv = max(3400, batteryMv - Int(clock().timeIntervalSince(bootDate)) / 20)
        let row = "\(Int(deviceNow.timeIntervalSince1970)),\(mv),\(min(100, max(0, (mv - 3500) * 100 / 650))),discharging,\(inSession ? "off" : "on"),\(cfg.brightness ?? 160)"
        return (["t,mv,pct,state,display,brightness"] + batlog + [row]).joined(separator: "\n") + "\n"
    }

    public func clearBatteryLog() async throws {
        try await enter("DELETE /batlog")
        batlog = []
    }

    // MARK: Reader (§5c)

    private var usedBytes: Int {
        assets.values.reduce(0) { $0 + $1.info.size } + storedTexts.values.reduce(0) { $0 + $1.data.count }
            + storedFonts.values.reduce(0) { $0 + ((try? ClipJSON.encoder().encode($1).count) ?? 0) }
    }

    public func texts() async throws -> [ClipText] {
        try await enter("GET /texts")
        _ = playbackState()
        return storedTexts.map { id, t in
            ClipText(id: id, bytes: t.data.count, words: t.words.count, title: t.title, progressWord: engine.savedProgress[id] ?? 0)
        }.sorted { $0.id < $1.id }
    }

    public func putText(id: String, data: Data) async throws -> AssetPutResult {
        try await enter("PUT /texts/\(id)")
        guard HCA.isValidAssetID(id) else { throw err(400, "invalid_id", "Text ids are [a-z0-9][a-z0-9-]{0,31}.") }
        if let existing = storedTexts[id], existing.data == data { return .alreadyPresent }
        guard data.count <= ReaderLimits.maxTextBytes else { throw err(413, "too_large", "Texts are at most 1 MB.") }
        guard String(data: data, encoding: .utf8) != nil else { throw err(422, "malformed", "Texts are UTF-8.") }
        let used = usedBytes - (storedTexts[id]?.data.count ?? 0)
        guard used + data.count <= options.storageTotal else { throw err(413, "no_space", "Not enough space on the clip.") }
        let words = RSVPText.tokenize(data, titleBreak: true)
        storedTexts[id] = StoredText(data: data, title: RSVPText.title(of: data), words: words)
        engine.setText(id, words: words)
        return .created(AssetPutResponse(id: id, size: data.count, sha256: Hashing.sha256Hex(data)))
    }

    public func deleteText(id: String) async throws {
        try await enter("DELETE /texts/\(id)")
        guard storedTexts.removeValue(forKey: id) != nil else { throw err(404, "not_found", "No text “\(id)”.") }
        engine.forgetText(id)
        oracleReaders[id] = nil
        // Reader items go, and an oracle whose phrase bundle this was (it can't write its screens without it).
        var doc = playlistDoc.withoutUnavailableOracles(missingTexts: [id], missingFonts: [])
        doc.items = doc.items.filter { !($0.type == .reader && $0.text == id) }
        if doc != playlistDoc {
            playlistDoc = doc
            engine.setPlaylist(playlistDoc, now: deviceNow)
        }
    }

    public func putFont(id: String, _ font: ReaderFontDocument) async throws {
        try await enter("PUT /fonts/\(id)")
        guard HCA.isValidAssetID(id) else { throw err(400, "invalid_id", "Font ids are [a-z0-9][a-z0-9-]{0,31}.") }
        if let problem = font.validationProblem { throw err(422, "invalid_font", problem) }
        if let size = try? ClipJSON.encoder().encode(font).count, size > ReaderFontDocument.maxJSONBytes {
            throw err(422, "invalid_font", "The font document is over 16 KB.")
        }
        for face in [font.normal] + [font.compact, font.large].compactMap({ $0 }) {
            for atlasID in [face.atlasWhite, face.atlasAccent] {
                guard let a = assets[atlasID] else { throw err(422, "unknown_asset", "Upload the atlas “\(atlasID)” first.") }
                guard a.info.atlas, a.info.width == face.cellW, a.info.height == face.cellH,
                      a.info.frames >= face.glyphs.unicodeScalars.count else {
                    throw err(422, "invalid_font", "“\(atlasID)” isn’t a \(face.cellW)×\(face.cellH) glyph atlas with a frame per glyph.")
                }
            }
        }
        storedFonts[id] = font
        boundFonts[id] = nil
    }

    public func font(id: String) async throws -> ReaderFontDocument {
        try await enter("GET /fonts/\(id)")
        guard let f = storedFonts[id] else { throw err(404, "not_found", "No font “\(id)”.") }
        return f
    }

    public func reader() async throws -> ReaderStatus {
        try await enter("GET /reader")
        _ = playbackState()
        guard let n = engine.readerNow else { return ReaderStatus(text: nil, word: 0, words: 0, paused: false, wpm: 0) }
        return ReaderStatus(text: n.text, word: n.word, words: n.words, paused: n.paused, wpm: n.wpm)
    }

    public func readerControl(_ command: ReaderCommand) async throws {
        try await enter("POST /reader")
        _ = playbackState()
        let ok: Bool
        switch command.action {
        case .pause: ok = engine.readerPause(now: deviceNow)
        case .resume: ok = engine.readerResume(now: deviceNow)
        case .seek:
            guard let w = command.word, w >= 0 else { throw err(422, "invalid_word", "seek needs \"word\": an integer ≥ 0.") }
            if let n = engine.readerNow, w >= n.words { throw err(422, "invalid_word", "word is beyond the end of the text") }
            ok = engine.readerSeek(word: w, now: deviceNow)
        }
        if !ok { throw err(409, "no_reader", "No reader item is playing.") }
    }

    /// Debug/tests: the reading on screen as the panel shows it (no request, no session).
    public func readerNow() -> PlaybackEngine.ReaderNow? {
        _ = playbackState()
        return engine.readerNow
    }

    /// Debug/tests: pause or resume without opening an upload session (the clip's BOOT short press).
    public func pressButton() {
        _ = playbackState()
        if engine.readerPaused { engine.readerResume(now: deviceNow) } else { engine.readerPause(now: deviceNow) }
    }

    private func bound(_ fontID: String) -> ReaderBoundFont? {
        if let b = boundFonts[fontID] { return b }
        guard let doc = storedFonts[fontID] else { return nil }
        func frames(_ id: String) -> [RGB565Frame]? { try? assets[id]?.file.decodeAllFrames() }
        guard let nw = frames(doc.normal.atlasWhite), let na = frames(doc.normal.atlasAccent) else { return nil }
        var compact: ReaderBoundFont.Face?
        if let c = doc.compact, let cw = frames(c.atlasWhite), let ca = frames(c.atlasAccent) {
            compact = ReaderBoundFont.Face(document: c, white: cw, accent: ca)
        }
        var large: ReaderBoundFont.Face?
        if let l = doc.large, let lw = frames(l.atlasWhite), let la = frames(l.atlasAccent) {
            large = ReaderBoundFont.Face(document: l, white: lw, accent: la)
        }
        let b = ReaderBoundFont(normal: .init(document: doc.normal, white: nw, accent: na), compact: compact, large: large)
        boundFonts[fontID] = b
        return b
    }

    /// Where the virtual clip's shake metric (g, decaying peak) comes from: the app feeds the iPhone's
    /// own motion. Nil = no shaking except `POST /oracle/draw`.
    public func setShakeSource(_ source: (@Sendable () -> Double?)?) { shakeSource = source }

    // MARK: Oracle (§5f)

    /// Tests: seed the card picker of the next oracle that shows.
    public func setOracleSeed(_ seed: UInt32?) { oracleSeed = seed }

    public func oracleDraw(cards: [Int]?) async throws {
        try await enter("POST /oracle/draw")
        let st = playbackState()
        guard var m = oracleTick(st) else { throw err(409, "not_showing", "No oracle is on screen.") }
        if let cards, !m.isRow(cards) { throw err(422, "invalid_cards", "cards is three distinct cards, 0–\(m.cards - 1).") }
        m.draw(at: deviceNow, cards: cards)
        oracle?.machine = m
    }

    /// `POST /oracle/back` (§5f.3, the clip's double-tap): the previous screen.
    public func oracleBack() async throws {
        try await enter("POST /oracle/back")
        let st = playbackState()
        guard var m = oracleTick(st) else { throw err(409, "not_showing", "No oracle is on screen.") }
        m.back(at: deviceNow)
        oracle?.machine = m
    }

    public func oracleTurn() async throws {
        try await enter("POST /oracle/turn")
        let st = playbackState()
        guard var m = oracleTick(st) else { throw err(409, "not_showing", "No oracle is on screen.") }
        m.turn(at: deviceNow)
        oracle?.machine = m
    }

    /// The oracle now (tests and debug), after catching up; nil when none shows.
    public func oracleNow() -> (status: ClipStatus.OracleStatus, view: OracleView, drawn: [[Int]])? {
        let st = playbackState()
        return oracleTick(st).map { ($0.status(at: deviceNow), $0.view(at: deviceNow), $0.drawn) }
    }

    /// The engine advanced to now, told first whether the oracle on screen is mid-draw (§5f.8: its end, queue
    /// entries and windows wait for the draw to come back to waits).
    private func playbackState() -> PlaybackEngine.State {
        let now = deviceNow
        if var m = oracle?.machine {
            m.advance(to: now)
            engine.setDrawInProgress(m.state != .waits, at: m.waitsSince)
        } else {
            engine.setDrawInProgress(false, at: now)
        }
        return engine.state(at: now, timing: timing)
    }

    /// Keeps the machine of the oracle on screen (a new one each time one comes on), fed with the shake
    /// metric and the clock, advanced to now. Nil when no oracle shows.
    @discardableResult
    private func oracleTick(_ st: PlaybackEngine.State) -> OracleMachine? {
        guard case .oracle(let item) = st.content, storedTexts[item.id] != nil, assets[item.deck] != nil else {
            oracle = nil
            return nil
        }
        let now = deviceNow
        if oracle?.item != item {
            let font = item.font.flatMap { bound($0) }
            // §5f.7: the "and" screen's fit is one lean page in the body font at the item's size.
            var fits: (@Sendable (String) -> Bool)?
            if let face = font?.normal { fits = { text in OracleScreens.fitsLeanPage(text, face: face) } }
            oracle = (item, OracleMachine(item: item, seed: oracleSeed, reader: oracleReader(item), fits: fits))
        }
        guard var m = oracle?.machine else { return nil }
        if imuPresent, let metric = shakeSource?() { m.sample(metric, at: now) } else { m.advance(to: now) }
        oracle?.machine = m
        return m
    }

    private func oracleAssets(_ o: OracleItem) -> OracleCompositor.Assets? {
        guard let d = frames(for: o.deck) else { return nil }
        return OracleCompositor.Assets(deck: d, keys: o.keys.flatMap { frames(for: $0) } ?? [],
                                       notes: [],
                                       font: o.font.flatMap { bound($0) }, bundle: oracleReader(o),
                                       fontBig: o.fontBig.flatMap { bound($0) }, flipped: isFlipped)
    }

    /// The item's phrase bundle, parsed once per text (nil when it isn't stored).
    private func oracleReader(_ o: OracleItem) -> SentenceReader? {
        let id = o.id
        if let r = oracleReaders[id] { return r }
        guard let t = storedTexts[id] else { return nil }
        let r = SentenceReader(bundle: t.data)
        oracleReaders[id] = r
        return r
    }


    // MARK: Motion sensor (firmware extension)

    /// How the pretend chip sits on the board: display = mounting · chip. The compiled map is the
    /// identity, so until calibrated the reported gravity is a quarter turn off (sand falls sideways),
    /// like `scripts/mock_clip.py`'s "pretend rotated chip".
    public static let imuMounting = IMUAxisMap([[0, -1, 0], [1, 0, 0], [0, 0, 1]])

    private var gravitySource: (@Sendable () -> IMUVector?)?
    private var simulatedPose: IMUVector = .upright
    private var imuPresent = true
    private var imuShaking = false
    private var imuMap: IMUAxisMap = .identity
    private var imuCalibrated = false
    private var imuCaptures: (up: IMUVector?, face: IMUVector?) = (nil, nil)
    private var imuSamples = 0

    /// The chip's reading now: true gravity (source or pose) seen from the rotated chip, plus a
    /// little sensor noise (a lot while shaking).
    private func chipReading() -> IMUVector {
        imuSamples += 25
        let truth = gravitySource?() ?? simulatedPose
        let raw = Self.imuMounting.inverse(truth)
        let t = Double(imuSamples)
        let amp = imuShaking ? 0.35 : 0.004
        func round3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
        return IMUVector(round3(raw.x + amp * sin(t * 0.37)), round3(raw.y + amp * sin(t * 0.53 + 1)), round3(raw.z + amp * sin(t * 0.71 + 2)))
    }

    public func imu() async throws -> IMUReading {
        try await enter("GET /imu")
        guard imuPresent else {
            return IMUReading(present: false, g: .upright, shake: 0, samples: 0, raw: IMUVector(0, 0, 0), calibrated: imuCalibrated,
                              axisMap: imuMap, addr: nil, flipped: isFlipped)
        }
        let raw = chipReading()
        let g = imuMap.apply(raw)
        return IMUReading(g: g, shake: imuShaking ? 0.8 : 0.003, samples: imuSamples, gLowPass: g, raw: raw,
                          calibrated: imuCalibrated, axisMap: imuMap, addr: "0x6B", flipped: isFlipped)
    }

    public func calibrateIMU(_ step: IMUCalibrationStep) async throws -> IMUCalibrationResult {
        try await enter("POST /imu/calibrate")
        if step == .reset {
            imuMap = .identity
            imuCalibrated = false
            imuCaptures = (nil, nil)
            return IMUCalibrationResult(step: .reset, calibrated: false, axisMap: imuMap)
        }
        guard imuPresent else { throw err(409, "no_imu", "no accelerometer detected") }
        // The firmware averages ~0.5 s of samples.
        if options.latency > .zero { try await Task.sleep(for: .milliseconds(500)) }
        if imuShaking { throw err(422, "not_still", "the clip moved during the reading: hold it still and retry") }
        let r = chipReading()
        guard r.isSquare else {
            throw err(422, "ambiguous_pose", "reading is not ~1 g along one chip axis: square the clip up and retry")
        }
        if step == .upright { imuCaptures.up = r } else { imuCaptures.face = r }
        guard let up = imuCaptures.up, let face = imuCaptures.face else {
            return IMUCalibrationResult(step: step, raw: r, next: imuCaptures.up == nil ? .upright : .faceup, calibrated: imuCalibrated)
        }
        imuCaptures = (nil, nil)   // a pair is used once, whatever the outcome
        guard let map = IMUAxisMap.calibrate(upright: up, faceUp: face) else {
            throw err(422, "calibration_failed", "upright and face-up readings are on the same chip axis: redo both steps")
        }
        imuMap = map
        imuCalibrated = true
        return IMUCalibrationResult(step: step, raw: r, calibrated: true, axisMap: map)
    }

    // MARK: Screen

    /// The virtual panel. Not a protocol call: no latency, not logged, doesn't start a session.
    public func display() -> Display {
        let st = playbackState()
        let bright = Double(liveBrightness ?? cfg.brightness ?? 160) / 255
        let key: String
        switch st.content {
        case .idle: key = "idle-\(cfg.name ?? "")"
        case .asset(let id, let f): key = "a-\(id)-\(f)-\(assets[id]?.info.sha256.prefix(8) ?? "")"
        case .strip(let id, let xs): key = "s-\(id)-\(xs.map(String.init).joined(separator: ","))-\(assets[id]?.info.sha256.prefix(8) ?? "")"
        case .scene(let n): key = "scene-\(n)"
        case .words(let sheet): key = "words-\(sheet)-\(assets[sheet]?.info.sha256.prefix(8) ?? "")"
        case .board(let sheet, _, _, let rows, let speed, let tMs):
            // The visible rows, and the scroll position (to the pixel) while it scrolls.
            let visible = Board.visibleRows(rows, now: deviceNow, clockSynced: synced).map(\.frame)
            key = "board-\(sheet)-\(visible.map(String.init).joined(separator: ","))-\(Int(Double(tMs) / 1000 * Double(speed)))"
        case .reader(let t, let f, let w, let p): key = "r-\(t)-\(f)-\(w.map(String.init) ?? "_")-\(p)"
        case .readerEnd(let t, let f, _, _): key = "rend-\(t)-\(f)"
        case .oracle(let o):
            let view = oracleTick(st)?.view(at: deviceNow) ?? .waits
            key = "or-\(o.id)-\(o.font ?? "")-\(o.fontBig ?? "")-\(assets[o.deck]?.info.sha256.prefix(8) ?? "")-\(view)\(isFlipped ? "-f" : "")"
        }
        let showing: String?
        switch st.content {
        case .scene(let n): showing = "scene:\(n)"
        case .words: showing = "scene:words"
        case .board(let sheet, _, _, _, _, _): showing = "board:\(sheet)"
        case .reader(let t, _, _, _), .readerEnd(let t, _, _, _): showing = "reader:\(t)"
        case .oracle(let o): showing = "oracle:\(o.id)"
        default: showing = st.currentID
        }
        let awake = !inSession || cfg.screenStaysOn
        return Display(frame: render(st), level: bright * st.fade, currentID: st.currentID,
                       playlistIndex: st.playlistIndex, queueID: st.queueID, nowShowing: showing, isAwake: awake, key: key,
                       content: st.content, flipped: isFlipped, oracle: oracle?.machine.status(at: deviceNow))
    }

    private func render(_ st: PlaybackEngine.State) -> RGB565Frame {
        switch st.content {
        case .idle:
            return idle()
        case .asset(let id, let index):
            guard let f = frames(for: id)?[safe: index] else { return idle() }
            return f.width == ClipCanvas.width ? f : StripScroller.firstScreen(f)
        case .strip(let id, let xs):
            guard let strip = frames(for: id)?.first else { return idle() }
            return StripScroller.window(strip, copies: xs)
        case .scene(let name):
            if let f = sceneFrames[name] { return f }
            let f = ClipRenderer.render(PlaceholderArt.scenePlaceholder(name), transform: CropTransform(scale: 1), adjustments: .neutral)
            sceneFrames[name] = f
            return f
        case .board(let sheet, let header, let empty, let rows, let speed, let tMs):
            // §5g: the header fixed, the rows still ahead of the clock (every row while unsynced), scrolling if taller.
            guard let frames = frames(for: sheet) else { return idle() }
            return Board.frame(sheet: frames, header: header, empty: empty, rows: Board.visibleRows(rows, now: deviceNow, clockSynced: synced),
                               speed: speed, tMs: tMs)
        case .words(let sheet):
            // §5b.1: the words resting along the bottom edge (the physics isn't mirrored).
            guard let sprites = frames(for: sheet) else { return idle() }
            return WordsSheetRenderer.restingStill(sprites)
        case .reader(let text, let fontID, let word, let paused):
            guard let font = bound(fontID) else { return idle() }
            let w = word.flatMap { storedTexts[text]?.words[safe: $0]?.text }
            return ReaderPreview.frame(word: w, font: font, paused: paused)
        case .readerEnd(_, let fontID, let words, let minutes):
            guard let font = bound(fontID) else { return idle() }
            return ReaderPreview.endCard(words: words, minutes: minutes, font: font)
        case .oracle(let o):
            let view = oracleTick(st)?.view(at: deviceNow) ?? .waits
            guard let a = oracleAssets(o) else { return idle() }
            return OracleCompositor.frame(view, a)
        }
    }

    private func idle() -> RGB565Frame {
        if let f = idleFrame { return f }
        let f = ClipRenderer.render(PlaceholderArt.idleScreen(name: cfg.name ?? "PixelClip"),
                                    transform: CropTransform(scale: 1), adjustments: .neutral)
        idleFrame = f
        return f
    }

    private func frames(for id: String) -> [RGB565Frame]? {
        if let d = decoded[id] { return d }
        guard let s = assets[id], let all = try? s.file.decodeAllFrames() else { return nil }
        decoded[id] = all
        return all
    }

    private func timing(_ id: String) -> PlaybackEngine.AssetTiming? { assets[id]?.timing }

    // MARK: Helpers

    /// The clip's own clock (phone time once synced).
    private var deviceNow: Date { clock().addingTimeInterval(timeOffset) }

    private func enter(_ line: String) async throws {
        if Self.transport == .bluetooth {
            // The fast lane: the link's own timing is modelled by `VirtualFastLane`.
            guard bleAdvertising else { throw ClipError.unreachable("Virtual clip isn’t heard over Bluetooth.") }
            fastLaneLog.append(line)
            return
        }
        if options.latency > .zero { try await Task.sleep(for: options.latency) }
        guard reachable, batteryMv >= ClipStatus.Battery.uploadCutoffMv || batteryOverride?.usb == true else {
            throw ClipError.unreachable("Virtual clip is not in upload mode.")
        }
        requestLog.append(line)
        lastRequest = clock()
        // Catch the panel up to now (queue entries due before the button press fire as they would
        // have), then switch it off for the session.
        startSession()
    }

    /// Upload mode on: catch the panel up to now (queue entries due before the button press fire as
    /// they would have), then, in panel-off mode, switch it off for the session.
    private func startSession() {
        if !inSession { _ = playbackState() }
        inSession = true
        if !cfg.screenStaysOn { engine.setOutput(false, now: deviceNow) }
    }

    // MARK: Bluetooth doorbell (PROTOCOL §3)

    public enum BLEWakeResult: Equatable, Sendable {
        case woke
        /// Upload mode was already on.
        case alreadyActive
        /// Below 3.5 V and not on USB: the firmware refuses to start Wi‑Fi.
        case lowBattery
        /// Not advertising (`ble_wake` false, or out of range): nothing hears the write.
        case notAdvertising
    }

    private var lastBLEWake: PixelClipBLEWakeResult = .none
    private var bleAdvertising: Bool { bluetoothPresent && cfg.bleWake != false }
    /// Heard over Bluetooth right now (in range, `ble_wake` on): the doorbell and the fast lane work.
    public var isAdvertising: Bool { bleAdvertising }
    private var bleBatteryLow: Bool { batteryMv < ClipStatus.Battery.uploadCutoffMv && batteryOverride?.usb != true }

    /// The `info` characteristic (no request, no session).
    public nonisolated var bleInfo: PixelClipBLEInfo { PixelClipBLEInfo(deviceID: options.deviceID, firmware: options.firmware) }

    /// `0x01` written to `wake`: Wi‑Fi on, session started, exactly like a long press.
    public func bleWake() -> BLEWakeResult {
        guard bleAdvertising else { return .notAdvertising }
        if inSession && reachable { lastBLEWake = .accepted; return .alreadyActive }
        if bleBatteryLow { lastBLEWake = .lowBattery; return .lowBattery }
        lastBLEWake = .accepted
        reachable = true
        lastRequest = clock()
        startSession()
        return .woke
    }

    /// `0x02` written to `wake`: the session ends (Wi‑Fi off, panel on) without an HTTP request.
    @discardableResult
    public func bleEnd() -> Bool {
        guard bleAdvertising else { return false }
        lastBLEWake = .accepted
        if inSession {
            sessionEndCount += 1
            inSession = false
            engine.setOutput(true, now: deviceNow)
        }
        return true
    }

    /// The `status` characteristic, or nil while the clip isn't advertising.
    public func bleStatus() -> PixelClipBLEStatus? {
        guard bleAdvertising else { return nil }
        let st = playbackState()
        let uptime = Int(clock().timeIntervalSince(bootDate))
        let mv = batteryOverride == nil ? max(3400, batteryMv - uptime / 20) : batteryMv
        let pct = batteryOverride?.pct ?? min(100, max(0, (mv - 3500) * 100 / 650))
        var flags: PixelClipBLEStatus.Flags = []
        if inSession && reachable { flags.insert(.sessionActive) }
        if batteryOverride?.usb == true { flags.insert(.usbPresent) }
        if synced { flags.insert(.clockOK) }
        if bleBatteryLow { flags.insert(.lowBattery) }
        if cfg.wifiAlwaysOn == true { flags.insert(.alwaysOn) }
        let kind: PixelClipBLEItemKind
        switch st.content {
        case .idle: kind = .none
        case .asset, .strip, .oracle, .board: kind = .asset
        case .scene, .words: kind = .scene
        case .reader, .readerEnd: kind = .reader
        }
        if kind != .none && (!inSession || cfg.screenStaysOn) { flags.insert(.playing) }
        return PixelClipBLEStatus(millivolts: mv, percent: pct, flags: flags, itemKind: kind, lastWake: lastBLEWake)
    }

    private func err(_ status: Int, _ code: String, _ message: String) -> ClipError {
        .http(status: status, envelope: ErrorEnvelope(error: code, message: message))
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
