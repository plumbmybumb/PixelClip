import Foundation

/// Playlist timing as PROTOCOL §4 and firmware/README.md describe it, shared by the virtual clip
/// and previews.
///
/// - `duration_ms > 0` wins. Otherwise animations play `loops` complete loops (min 1), stills 5 s,
///   scenes 60 s; strips with a `scroll` block play `loops` passes (`StripScroller`);
///   `clock`/`text` items are accepted but skipped (firmware v0.1).
/// - Frames with `duration_ms == 0` last 100 ms.
/// - The only active rotation item plays on without restarting (firmware `single`): no fade-out
///   between its loops, and a strip scrolls as an endless tape.
/// - Items with a `from`/`until` window are skipped outside it (local time via `tzOffsetS`;
///   windows may cross midnight) and are treated as inactive while the clock is unsynced.
/// - "Show now" without a duration plays 60 s, then the interrupted item restarts. A show that
///   arrives while a queue entry plays waits for it to end.
/// - Queue entries (firmware `sched_poll` + `start_queue`): play **one at a time in `at` order**,
///   each for its full `duration_ms` (default 60 s) from when it actually starts; an entry that comes
///   due while another plays waits; an entry that would *start* more than 600 s late is skipped; the
///   default transition is fade; done ids are remembered. Nothing fires while the clock is unsynced
///   or the panel is off (upload session); an entry due by then starts when the session ends if
///   still within 600 s. When an entry ends the interrupted rotation item restarts.
/// - `fade` = 250 ms ramp down at the end of the outgoing item and 250 ms ramp up at the start of
///   the incoming one, inside the item's duration.
/// - Reader items (PROTOCOL §5c) show one word at a time from `readerTexts` with the §5c timing
///   (`RSVPSchedule`). A reading starts at the item's `from_word` the first time it plays after a
///   playlist load, else where that text stopped (live progress; `savedProgress` is what the clip
///   persists: every 50 words and on pause; a finished text saves 0 and starts over). `duration_ms` 0 = until
///   the end plus the 3 s "fin" card (endless with `loop`). Pause freezes the reading clock; seek
///   restarts it at a word. Texts the clip doesn't hold are skipped.
/// - §5f.8 no interruptions: while an oracle on screen has a draw in progress (`setDrawInProgress`), its end
///   (rotation, show or queue `duration_ms`, its time window) is deferred and no queue entry starts; when the draw
///   returns to waits they fire at once if still due (a queue entry more than 600 s late is skipped, as always). A
///   `/show` and a new playlist still take effect at once.
public struct PlaybackEngine: Sendable {

    /// What the engine needs to know about an asset to time it.
    public struct AssetTiming: Sendable, Equatable {
        public var frameDurationsMs: [Int]
        /// Set for a scrolling strip (`is_strip`): its width in pixels.
        public var stripWidth: Int?
        public init(frameDurationsMs: [Int], stripWidth: Int? = nil) {
            self.frameDurationsMs = frameDurationsMs; self.stripWidth = stripWidth
        }
        public init(file: HCAFile) {
            frameDurationsMs = file.frames.map { $0.effectiveDurationMs() }
            stripWidth = file.isStrip ? file.width : nil
        }
        public var isAnimation: Bool { frameDurationsMs.count > 1 }
        public var loopMs: Int { max(1, frameDurationsMs.reduce(0, +)) }

        /// Frame shown `t` ms into the asset (looping).
        public func frameIndex(atMs t: Int) -> Int {
            guard frameDurationsMs.count > 1 else { return 0 }
            var r = t % loopMs
            for (i, d) in frameDurationsMs.enumerated() {
                if r < d { return i }
                r -= d
            }
            return frameDurationsMs.count - 1
        }
    }

    public static let stillDefaultMs = 5_000
    public static let sceneDefaultMs = 60_000
    public static let showDefaultMs = 60_000

    public enum Content: Sendable, Equatable {
        case idle
        case asset(id: String, frame: Int)
        /// A strip scrolling: screen x of each visible copy's left edge.
        case strip(id: String, copies: [Int])
        case scene(String)
        /// §5b.1: the `words` scene and its sheet (the virtual clip shows the words resting along the bottom).
        case words(sheet: String)
        /// §5g: a board: its sheet, header / empty frames, rows, scroll speed, and ms into the item (the scroll clock).
        case board(sheet: String, header: Int?, empty: Int?, rows: [BoardRow], speed: Int, tMs: Int)
        /// A reading: `word` nil = the blank after a paragraph.
        case reader(text: String, font: String, word: Int?, paused: Bool)
        /// The "fin" card after the last word.
        case readerEnd(text: String, font: String, words: Int, minutes: Int)
        /// An oracle (PROTOCOL §5f): the virtual clip runs its state machine on the item's four assets.
        case oracle(OracleItem)
    }

    /// What the engine needs to know about a stored text.
    public struct ReaderText: Sendable {
        public var words: [RSVPWord]
        public init(words: [RSVPWord]) { self.words = words }
    }

    /// The reading on screen, in `GET /reader` terms.
    public struct ReaderNow: Sendable, Equatable {
        public var text: String
        public var word: Int
        public var words: Int
        public var paused: Bool
        public var wpm: Int
    }

    /// Which item instance a reading belongs to (a new instance starts a new run).
    struct ReaderRunKey: Equatable, Sendable {
        enum Source: Equatable, Sendable { case rotation(Int), show, queue(String) }
        var source: Source
        var start: Date
    }

    struct ReaderRun: Sendable {
        var key: ReaderRunKey
        var text: String
        var startWord: Int
    }

    public struct State: Sendable, Equatable {
        public var content: Content
        /// 0…1 multiplier from fade transitions.
        public var fade: Double
        /// Index in the playlist, or nil when idle / showing an override or queue entry.
        public var playlistIndex: Int?
        /// The queue entry on screen, if any.
        public var queueID: String?
        public var currentID: String? {
            switch content {
            case .asset(let id, _), .strip(let id, _): return id
            case .oracle(let o): return o.id
            default: return nil
            }
        }
    }

    public private(set) var playlist: Playlist = .empty
    public private(set) var index: Int = 0
    public private(set) var doneQueueIDs: Set<String> = []
    /// Local offset for time windows.
    public var tzOffsetS: Int = 0
    /// Queue entries only fire, and windowed items only play, while the clock is synced.
    public var clockSynced = false
    /// False while the panel is off (upload session): nothing fires then.
    public private(set) var outputEnabled = true
    /// §5f.8: an oracle on screen is mid-draw (any state but waits).
    public private(set) var drawInProgress = false
    /// When the last draw returned to waits, until the next computation uses it (deferred ends happen then).
    private var drawEndedAt: Date?
    private var itemStart: Date
    private var override: (item: PlaylistItem, start: Date)?
    /// A show that arrived while a queue entry was playing (starts when it ends).
    private var pendingShow: PlaylistItem?
    private var activeQueue: (entry: QueueEntry, start: Date)?
    /// Queue entries can't start before this (they would have been seen by a 1 Hz poll after it):
    /// the end of the previous entry, the playlist load, the session end, the clock sync.
    private var queueGate: Date

    /// Texts on the clip (id → words), set by the virtual clip.
    public var readerTexts: [String: ReaderText] = [:]
    /// Where each text is (the word on screen, or where it stopped).
    public private(set) var liveProgress: [String: Int] = [:]
    /// What the clip persists per text (every 50 words, on pause, at the end).
    public private(set) var savedProgress: [String: Int] = [:]
    public private(set) var readerPaused = false
    /// The reading on screen after the last `state(at:)`, nil when none.
    public private(set) var readerNow: ReaderNow?
    private var readerRun: ReaderRun?
    private var pausedAt: Date?
    /// `from_word` of rotation items, applied the first time each text plays after a playlist load.
    private var pendingFromWord: [String: Int] = [:]
    private var schedules: [String: RSVPSchedule] = [:]

    public init(now: Date = Date()) { itemStart = now; queueGate = now }

    /// §5f.8: the oracle on screen has a draw in progress (`on`), or it came back to waits at `at`.
    public mutating func setDrawInProgress(_ on: Bool, at: Date) {
        if on {
            drawInProgress = true
            drawEndedAt = nil
        } else if drawInProgress {
            drawInProgress = false
            drawEndedAt = at
        }
    }

    /// Held on screen by a draw in progress (§5f.8): only an oracle is.
    private func held(_ item: PlaylistItem) -> Bool { drawInProgress && item.type == .oracle }

    /// The end of something whose end a draw deferred: no earlier than the draw's return to waits.
    private func deferred(_ end: Date) -> Date { drawEndedAt.map { max(end, $0) } ?? end }

    /// While held, the time into an item stays short of its fade-out.
    private func heldTime(_ t: Int, dur: Int) -> Int { max(0, min(t, dur - 300)) }

    public var activeQueueID: String? { activeQueue?.entry.id }

    public static func durationMs(of item: PlaylistItem, timing: AssetTiming?) -> Int {
        if item.durationMs > 0 { return item.durationMs }
        switch item.type {
        case .asset:
            guard let timing else { return stillDefaultMs }
            if let w = timing.stripWidth, let scroll = item.scroll { return StripScroller.durationMs(stripWidth: w, scroll: scroll) }
            return timing.isAnimation ? timing.loopMs * max(1, item.loops ?? 1) : stillDefaultMs
        case .scene: return sceneDefaultMs
        case .board: return sceneDefaultMs
        case .oracle: return stillDefaultMs      // as an asset's still (§5f: duration_ms works as for a still in a rotation)
        default: return 0   // clock/text: skipped; reader: until finished (needs the text, see `state`)
        }
    }

    static func isPlayableType(_ item: PlaylistItem) -> Bool { [.asset, .scene, .reader, .oracle, .board].contains(item.type) }

    func minuteOfDay(_ now: Date) -> Int {
        let local = Int(now.timeIntervalSince1970.rounded(.down)) + tzOffsetS
        return ((local / 60) % 1440 + 1440) % 1440
    }

    func isPlayable(_ item: PlaylistItem, at now: Date) -> Bool {
        guard Self.isPlayableType(item) else { return false }
        if item.type == .reader && (item.text.flatMap { readerTexts[$0] } == nil) { return false }
        if item.from != nil || item.until != nil {
            // Windowed items are inactive while the clock is unsynced (firmware `playlist_item_in_window`).
            guard clockSynced else { return false }
            return item.isActive(atMinuteOfDay: minuteOfDay(now))
        }
        return true
    }

    public mutating func setPlaylist(_ p: Playlist, now: Date) {
        playlist = p
        index = 0
        itemStart = now
        override = nil
        pendingShow = nil
        readerRun = nil
        readerPaused = false
        pausedAt = nil
        pendingFromWord = [:]
        for item in p.items where item.type == .reader {
            if let t = item.text, let w = item.fromWord, pendingFromWord[t] == nil { pendingFromWord[t] = max(0, w) }
        }
        if queueGate < now { queueGate = now }
        // Done ids persist (keyed by id); forget ones no longer in the queue.
        let ids = Set((p.queue ?? []).map(\.id))
        doneQueueIDs.formIntersection(ids)
        if let a = activeQueue {
            if let fresh = p.queue?.first(where: { $0.id == a.entry.id }) { activeQueue = (fresh, a.start) } else { activeQueue = nil }
        }
    }

    public mutating func show(_ item: PlaylistItem, now: Date) {
        var item = item
        if item.durationMs <= 0 { item.durationMs = Self.showDefaultMs }
        if activeQueue != nil { pendingShow = item; return }   // a queue entry wins; the show waits
        override = (item, now)
    }

    /// Restart timers from `now` (the firmware starts them when the upload session ends). A reading
    /// picks up at the word it was on.
    public mutating func restartTimers(now: Date) {
        if let ov = override { override = (ov.item, now) }
        if let a = activeQueue { activeQueue = (a.entry, now) }   // restart_current() replays it
        itemStart = now
        if queueGate < now { queueGate = now }
        // The same reading carries on from its word (and stays paused if it was).
        if var r = readerRun {
            r.startWord = liveProgress[r.text] ?? r.startWord
            r.key.start = now
            readerRun = r
        }
        if readerPaused { pausedAt = now }
    }

    /// Panel on/off (upload session). Turning it back on restarts the current item's timers.
    public mutating func setOutput(_ enabled: Bool, now: Date) {
        guard enabled != outputEnabled else { return }
        outputEnabled = enabled
        if enabled { restartTimers(now: now) }
    }

    /// The clock was set (`POST /time`): windows and the queue start counting from `now`.
    public mutating func setClockSynced(now: Date) {
        clockSynced = true
        restartTimers(now: now)
    }

    public mutating func next(now: Date) {
        override = nil
        guard !playlist.items.isEmpty else { return }
        index = (index + 1) % playlist.items.count
        itemStart = now
    }

    public mutating func previous(now: Date) {
        override = nil
        guard !playlist.items.isEmpty else { return }
        index = (index - 1 + playlist.items.count) % playlist.items.count
        itemStart = now
    }

    /// Pending (not done) queue entries, sorted by time.
    public func pendingQueue() -> [QueueEntry] {
        (playlist.queue ?? []).filter { !doneQueueIDs.contains($0.id) }.sorted { $0.at < $1.at }
    }

    /// Advance to `now` and report what is on screen.
    public mutating func state(at now: Date, timing: (String) -> AssetTiming?) -> State {
        holdPausedReading(now: now)
        let st = computeState(at: now, timing: timing)
        switch st.content {
        case .reader(let text, _, let word, let paused):
            let words = readerTexts[text]?.words.count ?? 0
            readerNow = ReaderNow(text: text, word: word ?? liveProgress[text] ?? 0, words: words, paused: paused,
                                  wpm: readerRunWPM ?? RSVPTiming.defaultWPM)
        case .readerEnd(let text, _, let words, _):
            readerNow = ReaderNow(text: text, word: words, words: words, paused: false, wpm: readerRunWPM ?? RSVPTiming.defaultWPM)
        default:
            readerNow = nil
            if readerPaused { readerPaused = false; pausedAt = nil }
        }
        return st
    }

    private var readerRunWPM: Int?

    private mutating func computeState(at now: Date, timing: (String) -> AssetTiming?) -> State {
        defer { drawEndedAt = nil }
        if let e = drawEndedAt, queueGate < e { queueGate = e }   // deferred entries start from the draw's end
        // 1. Queue entries win over everything.
        if let (entry, t) = activeQueueEntry(at: now) {
            let item = entry.asPlaylistItem
            if item.type == .reader, let a = activeQueue {
                let key = ReaderRunKey(source: .queue(entry.id), start: a.start)
                let c = readerContent(item, key: key, atMs: t)
                return State(content: c, fade: fade(item, t: t, dur: entry.effectiveDurationMs), playlistIndex: nil, queueID: entry.id)
            }
            return State(content: content(for: item, atMs: t, timing: timing),
                         fade: fade(item, t: t, dur: entry.effectiveDurationMs), playlistIndex: nil, queueID: entry.id)
        }
        if !clockSynced || !outputEnabled, queueGate < now { queueGate = now }
        // 2. "Show now".
        if let ov = override {
            let dur = Self.durationMs(of: ov.item, timing: ov.item.id.flatMap(timing))
            var t = Int(now.timeIntervalSince(ov.start) * 1000)
            if held(ov.item) { t = heldTime(t, dur: dur) }
            if t < dur {
                return State(content: content(for: ov.item, atMs: t, timing: timing),
                             fade: fade(ov.item, t: t, dur: dur), playlistIndex: nil)
            }
            override = nil
            itemStart = deferred(ov.start.addingTimeInterval(Double(dur) / 1000))
        }
        // §5f.8: the oracle mid-draw stays, past its duration or its window.
        if index < playlist.items.count, held(playlist.items[index]) {
            let item = playlist.items[index]
            let dur = Self.durationMs(of: item, timing: item.id.flatMap(timing))
            let t = heldTime(Int(now.timeIntervalSince(itemStart) * 1000), dur: dur)
            return State(content: content(for: item, atMs: t, timing: timing), fade: fade(item, t: t, dur: .max), playlistIndex: index)
        }
        // 3. Rotation.
        guard playlist.items.contains(where: { isPlayable($0, at: now) }) else {
            return State(content: .idle, fade: 1, playlistIndex: nil)
        }
        if index >= playlist.items.count { index = 0 }
        // The only active item plays on without restarting (firmware `single`): no fade-out, and a
        // strip scrolls as an endless tape.
        let single = playlist.items.filter { isPlayable($0, at: now) }.count == 1
        var guardCount = 0
        while guardCount < 10_000 {
            let item = playlist.items[index]
            let playable = isPlayable(item, at: now)
            let t = Int(now.timeIntervalSince(itemStart) * 1000)
            if playable, item.type == .reader {
                let key = ReaderRunKey(source: .rotation(index), start: itemStart)
                let dur = readerDurationMs(item, key: key)
                if t < dur || t < 0 {
                    let tt = max(0, t)
                    return State(content: readerContent(item, key: key, atMs: tt),
                                 fade: fade(item, t: tt, dur: dur >= Int.max / 4 ? .max : dur), playlistIndex: index)
                }
                finishReading(item, key: key, atMs: dur)
                if single {
                    // The only active item: the next reading starts right away (from the top if finished).
                    itemStart = itemStart.addingTimeInterval(Double(dur) / 1000)
                    guardCount += 1
                    continue
                }
                itemStart = itemStart.addingTimeInterval(Double(dur) / 1000)
                index = (index + 1) % playlist.items.count
                guardCount += 1
                continue
            }
            let dur = playable ? Self.durationMs(of: item, timing: item.id.flatMap(timing)) : 0
            if playable, single || t < dur || t < 0 {
                let tt = max(0, t)
                return State(content: content(for: item, atMs: tt, timing: timing, endless: single),
                             fade: single ? fade(item, t: tt, dur: .max) : fade(item, t: tt, dur: dur), playlistIndex: index)
            }
            // §5f.8: an oracle whose end a draw deferred ends when the draw did; the next item starts then.
            itemStart = item.type == .oracle ? deferred(itemStart.addingTimeInterval(Double(dur) / 1000))
                                             : itemStart.addingTimeInterval(Double(dur) / 1000)
            index = (index + 1) % playlist.items.count
            guardCount += 1
        }
        itemStart = now
        return State(content: .idle, fade: 1, playlistIndex: index)
    }

    private mutating func activeQueueEntry(at now: Date) -> (QueueEntry, Int)? {
        if let a = activeQueue {
            let dur = a.entry.effectiveDurationMs
            if !outputEnabled { return (a.entry, 0) }   // panel off: it replays from the start when the session ends
            var t = Int(now.timeIntervalSince(a.start) * 1000)
            let item = a.entry.asPlaylistItem
            if held(item) { t = heldTime(t, dur: dur) }
            if t < dur { return (a.entry, max(0, t)) }
            let end = a.start.addingTimeInterval(Double(dur) / 1000)
            finishQueue(a.entry, end: item.type == .oracle ? deferred(end) : end)
        }
        // §5f.8: no entry starts during a draw; they count from its end.
        if drawInProgress {
            if queueGate < now { queueGate = now }
            return nil
        }
        guard clockSynced, outputEnabled else { return nil }
        // Sorted by `at`; each entry starts when it is due or when the previous one ended (one at a time).
        for e in pendingQueue() {
            let at = Date(timeIntervalSince1970: TimeInterval(e.at))
            if now < at { break }
            let start = max(at, queueGate)
            if start.timeIntervalSince(at) > Double(QueueEntry.lateLimitS) {
                doneQueueIDs.insert(e.id)   // would start more than 10 minutes late: skipped
                continue
            }
            let end = start.addingTimeInterval(Double(e.effectiveDurationMs) / 1000)
            if end <= now {
                finishQueue(e, end: end)   // played in full while nobody was looking
                continue
            }
            activeQueue = (e, start)
            override = nil   // a queue entry wins over a running /show
            return (e, Int(now.timeIntervalSince(start) * 1000))
        }
        if queueGate < now { queueGate = now }
        return nil
    }

    private mutating func finishQueue(_ e: QueueEntry, end: Date) {
        doneQueueIDs.insert(e.id)
        activeQueue = nil
        itemStart = end   // back to the interrupted rotation item (it restarts)
        if queueGate < end { queueGate = end }
        if let show = pendingShow {
            pendingShow = nil
            override = (show, end)
        }
    }

    private func content(for item: PlaylistItem, atMs t: Int, timing: (String) -> AssetTiming?, endless: Bool = false) -> Content {
        switch item.type {
        case .asset:
            guard let id = item.id else { return .idle }
            let tm = timing(id)
            if let w = tm?.stripWidth, let scroll = item.scroll {
                let limit = item.durationMs > 0 || endless ? nil : StripScroller.loops(scroll)
                return .strip(id: id, copies: StripScroller.copies(offset: StripScroller.offsetPx(atMs: t, scroll: scroll),
                                                                   stripWidth: w, scroll: scroll, limit: limit))
            }
            return .asset(id: id, frame: tm?.frameIndex(atMs: t) ?? 0)
        case .scene: return item.isWords ? .words(sheet: item.id ?? "") : .scene(item.scene ?? "sand")
        case .oracle: return OracleItem(item: item).map { .oracle($0) } ?? .idle
        case .board:
            guard let id = item.id, let rows = item.rows else { return .idle }
            return .board(sheet: id, header: item.header, empty: item.empty, rows: rows, speed: item.scrollPxS ?? Board.defaultSpeed, tMs: t)
        default: return .idle
        }
    }

    // MARK: Reader

    private mutating func schedule(_ text: String, wpm: Int) -> RSVPSchedule? {
        guard let words = readerTexts[text]?.words else { return nil }
        let key = "\(text)@\(RSVPTiming.clampWPM(wpm))"
        if let s = schedules[key] { return s }
        let s = RSVPSchedule(words: words, wpm: wpm)
        schedules[key] = s
        return s
    }

    /// Establishes the run for this item instance (where the reading starts) and returns it.
    private mutating func run(_ item: PlaylistItem, key: ReaderRunKey) -> ReaderRun? {
        guard let text = item.text, let words = readerTexts[text]?.words else { return nil }
        if let r = readerRun, r.key == key, r.text == text { return r }
        var start: Int
        if case .queue = key.source, let w = item.fromWord {
            start = w
        } else if let w = pendingFromWord.removeValue(forKey: text) {
            start = w
        } else {
            start = liveProgress[text] ?? savedProgress[text] ?? 0
        }
        if start >= words.count || start < 0 { start = 0 }
        let r = ReaderRun(key: key, text: text, startWord: start)
        readerRun = r
        readerPaused = false
        pausedAt = nil
        return r
    }

    /// The item's length from its run start: `duration_ms` when set, else the rest of the text plus
    /// the end card (endless with `loop`).
    private mutating func readerDurationMs(_ item: PlaylistItem, key: ReaderRunKey) -> Int {
        if item.durationMs > 0 { return item.durationMs }
        if item.loop == true { return Int.max / 4 }
        guard let r = run(item, key: key), let s = schedule(r.text, wpm: item.wpm ?? RSVPTiming.defaultWPM) else { return 0 }
        return s.remainingMs(from: r.startWord) + RSVPTiming.endCardMs
    }

    private mutating func readerContent(_ item: PlaylistItem, key: ReaderRunKey, atMs t: Int) -> Content {
        guard let r = run(item, key: key), let font = item.font,
              let s = schedule(r.text, wpm: item.wpm ?? RSVPTiming.defaultWPM) else { return .idle }
        readerRunWPM = s.wpm
        // The panel is off during an upload session: the reading waits on its word.
        var tt = outputEnabled ? t : 0
        var startWord = r.startWord
        let firstPass = s.remainingMs(from: startWord) + RSVPTiming.endCardMs
        if item.loop == true, tt >= firstPass {
            // Start over from the top after the card, again and again.
            tt -= firstPass
            startWord = 0
            let period = max(1, s.totalMs + RSVPTiming.endCardMs)
            tt %= period
        }
        switch s.position(from: startWord, elapsedMs: tt) {
        case .word(let i, let blank):
            record(r.text, word: i)
            return .reader(text: r.text, font: font, word: blank ? nil : i, paused: readerPaused)
        case .end:
            record(r.text, word: s.count, finished: true)
            return .readerEnd(text: r.text, font: font, words: s.count,
                              minutes: RSVPTiming.minutes(totalMs: RSVPTiming.totalMs(readerTexts[r.text]?.words ?? [], wpm: s.wpm)))
        }
    }

    /// A reading that ran to its end (or its `duration_ms`) while nobody was looking.
    private mutating func finishReading(_ item: PlaylistItem, key: ReaderRunKey, atMs dur: Int) {
        guard item.loop != true else { return }
        _ = readerContent(item, key: key, atMs: max(0, dur - 1))
        if readerRun?.key == key { readerRun = nil }
    }

    /// A finished text saves word 0, so the next reading starts from the top (firmware `reader_save`).
    private mutating func record(_ text: String, word: Int, finished: Bool = false) {
        if finished {
            liveProgress[text] = 0
            savedProgress[text] = 0
            return
        }
        liveProgress[text] = word
        let saved = savedProgress[text] ?? 0
        if finished || word < saved || word - saved >= 50 { savedProgress[text] = word }
    }

    /// While paused the reading's clock stands still: its start moves forward with time.
    private mutating func holdPausedReading(now: Date) {
        guard readerPaused, let at = pausedAt, let r = readerRun else { return }
        let dt = now.timeIntervalSince(at)
        guard dt > 0 else { return }
        shiftRun(r, by: dt)
        pausedAt = now
    }

    private mutating func shiftRun(_ r: ReaderRun, by dt: TimeInterval) {
        var key = r.key
        switch r.key.source {
        case .rotation:
            itemStart = itemStart.addingTimeInterval(dt)
            key.start = itemStart
        case .show:
            if let ov = override { override = (ov.item, ov.start.addingTimeInterval(dt)); key.start = ov.start.addingTimeInterval(dt) }
        case .queue:
            if let a = activeQueue { activeQueue = (a.entry, a.start.addingTimeInterval(dt)); key.start = a.start.addingTimeInterval(dt) }
        }
        readerRun = ReaderRun(key: key, text: r.text, startWord: r.startWord)
    }

    /// `POST /reader pause`. False when no reading is on screen.
    @discardableResult
    public mutating func readerPause(now: Date) -> Bool {
        guard let n = readerNow, readerRun != nil else { return false }
        if !readerPaused {
            readerPaused = true
            pausedAt = now
            savedProgress[n.text] = n.word
        }
        return true
    }

    /// `POST /reader resume`.
    @discardableResult
    public mutating func readerResume(now: Date) -> Bool {
        guard readerNow != nil, readerRun != nil else { return false }
        holdPausedReading(now: now)
        readerPaused = false
        pausedAt = nil
        return true
    }

    /// `POST /reader seek`: the reading on screen continues from `word` (paused stays paused).
    @discardableResult
    public mutating func readerSeek(word: Int, now: Date) -> Bool {
        guard let r = readerRun, readerNow != nil, let count = readerTexts[r.text]?.words.count else { return false }
        let w = min(max(0, word), max(0, count - 1))
        var key = r.key
        switch r.key.source {
        case .rotation: itemStart = now; key.start = now
        case .show: if let ov = override { override = (ov.item, now) }; key.start = now
        case .queue: if let a = activeQueue { activeQueue = (a.entry, now) }; key.start = now
        }
        readerRun = ReaderRun(key: key, text: r.text, startWord: w)
        liveProgress[r.text] = w
        savedProgress[r.text] = w
        if readerPaused { pausedAt = now }
        return true
    }

    /// Forget a text (`DELETE /texts/{id}`).
    public mutating func forgetText(_ id: String) {
        readerTexts[id] = nil
        liveProgress[id] = nil
        savedProgress[id] = nil
        schedules = schedules.filter { !$0.key.hasPrefix("\(id)@") }
        if readerRun?.text == id { readerRun = nil }
    }

    /// A text was replaced: its words (and so its schedules) changed.
    public mutating func setText(_ id: String, words: [RSVPWord]) {
        readerTexts[id] = ReaderText(words: words)
        schedules = schedules.filter { !$0.key.hasPrefix("\(id)@") }
        if let p = savedProgress[id], p > words.count { savedProgress[id] = 0; liveProgress[id] = 0 }
    }

    private func fade(_ item: PlaylistItem, t: Int, dur: Int) -> Double {
        guard item.transition == .fade, dur > 2 * Transition.fadeHalfMs else { return 1 }
        let h = Double(Transition.fadeHalfMs)
        if Double(t) < h { return Double(t) / h }
        if dur != .max, Double(dur - t) < h { return Double(dur - t) / h }
        return 1
    }
}
