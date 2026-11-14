import Foundation

// The "Tonight" planner: edits the playlist's item windows (`from`/`until`) and its
// one-shot `queue[]` together, validates them, and produces the playlist document to PUT.
// Pure value types; the app persists and renders them.

/// What a moment shows.
public enum MomentContent: Codable, Sendable, Hashable {
    case asset(String)
    case scene(String, params: [String: SceneParam])
    /// A reading (PROTOCOL §5c): text id, reader font id, words per minute.
    case reader(text: String, font: String, wpm: Int)
    /// An oracle (PROTOCOL §5f): its bundle, fonts, deck, keys, notes and timings.
    case oracle(OracleItem)
    /// §5b.1: words that bounce as the clip moves: the `words` scene with its sheet (a library asset, one word per
    /// frame) and the text it was made from (for the playlist row; never sent).
    case words(sheet: String, text: String)
    /// §5g: a board: its sheet and rows.
    case board(BoardContent)

    public var type: PlaylistItemType {
        switch self {
        case .asset: .asset
        case .scene, .words: .scene
        case .board: .board
        case .reader: .reader
        case .oracle: .oracle
        }
    }

    /// The library item this shows: a picture's, or an oracle's (its library item, since §5f.2 a poster that
    /// isn't sent).
    public var assetID: String? {
        switch self {
        case .asset(let id): id
        case .oracle(let o): o.libraryKey
        case .words(let sheet, _): sheet
        case .board(let b): b.sheet
        default: nil
        }
    }

    /// Every library asset the clip needs for this (an oracle's deck, keys and notes).
    public var assetIDs: [String] {
        if case .oracle(let o) = self { return o.assetIDs }
        return assetID.map { [$0] } ?? []
    }

    public var isOracle: Bool { if case .oracle = self { true } else { false } }

    /// How `/status.playlist.current` names this while it plays: an asset's id, `scene:<name>`,
    /// `reader:<text>`, `oracle:<bundle id>`.
    public var clipCurrentID: String {
        switch self {
        case .asset(let id): id
        case .scene(let name, _): "scene:\(name)"
        case .words: "scene:words"
        case .board(let b): "board:\(b.sheet)"
        case .reader(let text, _, _): "reader:\(text)"
        case .oracle(let o): "oracle:\(o.id)"
        }
    }

}

/// A one-shot timed moment (one `queue[]` entry) plus the name the planner shows for it.
public struct Moment: Codable, Sendable, Hashable, Identifiable {
    /// The queue entry id (≤ 40 printable ASCII chars, firmware `sched_id_valid`).
    public var id: String
    /// Unix seconds.
    public var at: Int
    public var content: MomentContent
    public var durationS: Int
    public var transition: Transition
    public var title: String

    public init(id: String, at: Int, content: MomentContent, durationS: Int, transition: Transition = .fade, title: String) {
        self.id = id; self.at = at; self.content = content; self.durationS = durationS
        self.transition = transition; self.title = title
    }

    public var start: Date { Date(timeIntervalSince1970: TimeInterval(at)) }
    public var endS: Int { at + durationS }
    public var end: Date { Date(timeIntervalSince1970: TimeInterval(endS)) }

    /// The `queue[]` entry for the playlist document.
    public var entry: QueueEntry {
        switch content {
        case .asset(let id):
            QueueEntry(id: self.id, at: at, type: .asset, asset: id, durationMs: durationS * 1000, transition: transition)
        case .scene(let name, let params):
            QueueEntry(id: self.id, at: at, type: .scene, scene: name, params: params.isEmpty ? nil : params,
                       durationMs: durationS * 1000, transition: transition)
        case .reader(let text, let font, let wpm):
            QueueEntry(id: self.id, at: at, type: .reader, durationMs: durationS * 1000, transition: transition,
                       text: text, font: font, wpm: wpm, loop: false)
        case .board(let b):
            b.queueEntry(id: self.id, at: at, durationMs: durationS * 1000, transition: transition)
        case .words(let sheet, _):
            // In `queue[]` the sheet goes in `asset` (`id` is the entry's own id).
            QueueEntry(id: self.id, at: at, type: .scene, asset: sheet, scene: WordsScene.name, params: WordsScene.params,
                       durationMs: durationS * 1000, transition: transition)
        case .oracle(let o):
            QueueEntry(id: self.id, at: at, type: .oracle, asset: o.id, durationMs: durationS * 1000, transition: transition,
                       font: o.font, holdMs: o.holdMs, shakeG: o.shakeG, cards: o.cards,
                       faceMs: o.faceMs, pageMs: o.pageMs, deck: o.deck, keys: o.keys,
                       reader: o.id, fontBig: o.font == nil ? nil : o.fontBig)
        }
    }

    /// `t-<at in base 36>-<4 hex>`: unique, short, valid for the firmware.
    public static func makeID(at: Int, existing: Set<String>) -> String {
        var rng = SystemRandomNumberGenerator()
        return makeID(at: at, existing: existing, using: &rng)
    }

    public static func makeID<R: RandomNumberGenerator>(at: Int, existing: Set<String>, using rng: inout R) -> String {
        while true {
            let id = "t-\(String(at, radix: 36))-\(String(UInt16.random(in: 0...UInt16.max, using: &rng), radix: 16).leftPad(4))"
            if !existing.contains(id) { return id }
        }
    }

    /// Firmware rule for queue ids: 1…40 bytes, printable ASCII, no `"` or `\`.
    public static func isValidID(_ id: String) -> Bool {
        let bytes = Array(id.utf8)
        return (1...40).contains(bytes.count) && bytes.allSatisfy { $0 >= 0x21 && $0 <= 0x7E && $0 != 0x22 && $0 != 0x5C }
    }
}

/// One rotation item with a stable key (the app's playlist entry id) and a display name.
public struct RotationSlot: Sendable, Hashable, Identifiable {
    public var id: String
    public var item: PlaylistItem
    public var title: String

    public init(id: String, item: PlaylistItem, title: String) { self.id = id; self.item = item; self.title = title }

    public var hasWindow: Bool { item.from != nil || item.until != nil }

    /// "after 21:30", "until 01:00", "21:30–01:00", or nil when always on.
    public var windowText: String? { Self.windowText(from: item.from, until: item.until) }

    public static func windowText(from: TimeOfDay?, until: TimeOfDay?) -> String? {
        switch (from, until) {
        case (nil, nil): nil
        case (let f?, nil): "after \(f.string)"
        case (nil, let u?): "until \(u.string)"
        case (let f?, let u?): "\(f.string)–\(u.string)"
        }
    }

    /// Minutes per day the window is open (1440 when always on).
    public var activeMinutesPerDay: Int {
        (0..<1440).reduce(0) { $0 + (item.isActive(atMinuteOfDay: $1) ? 1 : 0) }
    }
}

public enum PlanError: Error, Sendable, Equatable {
    /// The moment would start at or before now.
    case inThePast
    /// Durations are 5 s … 30 min.
    case durationOutOfRange
    /// `from == until` (the firmware rejects it: 422 invalid_playlist "empty time window").
    case emptyWindow
    /// The firmware holds at most 64 queue entries.
    case tooManyMoments
    case unknownSlot
    case unknownMoment
}

extension PlanError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .inThePast: "That time has already passed."
        case .durationOutOfRange: "Moments last between 5 seconds and 30 minutes."
        case .emptyWindow: "Start and end can’t be the same time."
        case .tooManyMoments: "PixelClip can hold \(TonightPlan.maxMoments) moments at most."
        case .unknownSlot: "That item is no longer in the playlist."
        case .unknownMoment: "That moment no longer exists."
        }
    }
}

/// Something the planner wants the user to see before sending.
public struct PlanIssue: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        /// `later` starts before `earlier` ends. Fix: `stagger()`.
        case overlap(earlier: String, later: String)
        /// A moment that has already ended (not sent; shown greyed).
        case past(String)
        case durationOutOfRange(String)
        case clockNotSynced
        case clockUnknown
        case tooManyMoments
        case emptyWindow(String)
        /// Some hours have no rotation item active: the clip shows its idle screen then.
        case idleGap
    }
    public enum Severity: Sendable, Hashable, Comparable { case info, warning, blocking }

    public var kind: Kind
    public var severity: Severity
    public var message: String
    public var id: Kind { kind }
}

public struct TonightPlan: Sendable, Equatable {
    public static let durationRangeS = 5...1800
    /// `SCHED_QUEUE_MAX` in the firmware.
    public static let maxMoments = 64

    /// The base item ("Now"): plays until something else is sent; first in the rotation.
    public var nowItem: RotationSlot?
    /// Tonight's rotation items, around Now (each with its window, or none: "whenever").
    public var slots: [RotationSlot]
    /// Sorted by `at` (stable).
    public private(set) var moments: [Moment]

    public init(nowItem: RotationSlot? = nil, slots: [RotationSlot] = [], moments: [Moment] = []) {
        self.nowItem = nowItem
        self.slots = slots
        self.moments = Self.sorted(moments)
    }

    /// Tonight adds nothing around Now (no rotation items, no moments that haven't ended).
    public func isTonightEmpty(now: Date) -> Bool {
        slots.isEmpty && !moments.contains { $0.endS > Int(now.timeIntervalSince1970) }
    }

    private static func sorted(_ m: [Moment]) -> [Moment] {
        m.enumerated().sorted { a, b in a.element.at != b.element.at ? a.element.at < b.element.at : a.offset < b.offset }.map(\.element)
    }

    // MARK: Moments

    @discardableResult
    public mutating func addMoment(_ content: MomentContent, at: Date, durationS: Int, transition: Transition = .fade,
                                   title: String, now: Date) throws(PlanError) -> Moment {
        let m = Moment(id: Moment.makeID(at: Int(at.timeIntervalSince1970), existing: Set(moments.map(\.id))),
                       at: Int(at.timeIntervalSince1970.rounded(.down)), content: content, durationS: durationS,
                       transition: transition, title: title)
        try Self.check(m, now: now)
        guard moments.filter({ $0.endS > Int(now.timeIntervalSince1970) }).count < Self.maxMoments else { throw .tooManyMoments }
        moments = Self.sorted(moments + [m])
        return m
    }

    /// Replace a moment (same id). Editing a moment that has started is refused like a new one would be.
    public mutating func updateMoment(_ m: Moment, now: Date) throws(PlanError) {
        guard let i = moments.firstIndex(where: { $0.id == m.id }) else { throw .unknownMoment }
        try Self.check(m, now: now)
        moments[i] = m
        moments = Self.sorted(moments)
    }

    /// Removes a moment; returns it (for Undo).
    @discardableResult
    public mutating func deleteMoment(id: String) -> Moment? {
        guard let i = moments.firstIndex(where: { $0.id == id }) else { return nil }
        return moments.remove(at: i)
    }

    /// Puts a deleted moment back as it was (Undo). No-op if a moment with its id is there.
    public mutating func restoreMoment(_ m: Moment) {
        guard !moments.contains(where: { $0.id == m.id }) else { return }
        moments = Self.sorted(moments + [m])
    }

    /// "Clear tonight": every moment and every rotation item Tonight added. Now stays.
    /// Returns how many of each went.
    @discardableResult
    public mutating func clearTonight() -> (slots: Int, moments: Int) {
        let removed = (slots.count, moments.count)
        slots = []
        moments = []
        return removed
    }

    /// Drop moments that ended before `now` (they can't fire again).
    public mutating func pruneEnded(now: Date) {
        let n = Int(now.timeIntervalSince1970)
        moments.removeAll { $0.endS <= n }
    }

    static func check(_ m: Moment, now: Date) throws(PlanError) {
        guard Self.durationRangeS.contains(m.durationS) else { throw .durationOutOfRange }
        guard TimeInterval(m.at) > now.timeIntervalSince1970 else { throw .inThePast }
    }

    /// Pairs whose time ranges intersect, in time order (each later moment against the one before it
    /// in playback order, i.e. what the clip would actually collide on).
    public func overlaps() -> [(earlier: Moment, later: Moment)] {
        var out: [(Moment, Moment)] = []
        var latest: Moment?
        for m in moments {
            if let p = latest, m.at < p.endS { out.append((p, m)) }
            if latest == nil || m.endS > latest!.endS { latest = m }
        }
        return out
    }

    /// Shift every overlapping moment (that hasn't started) to begin exactly when the one before it
    /// ends, keeping their order. Returns how many moved.
    @discardableResult
    public mutating func stagger(now: Date = .distantPast) -> Int {
        var moved = 0
        var cursor: Int?
        let n = Int(now.timeIntervalSince1970.rounded(.down))
        for i in moments.indices {
            if let c = cursor, moments[i].at < c, moments[i].at > n {
                moments[i].at = c
                moved += 1
            }
            cursor = max(cursor ?? .min, moments[i].endS)
        }
        moments = Self.sorted(moments)
        return moved
    }

    // MARK: Rotation

    public mutating func setWindow(slotID: String, from: TimeOfDay?, until: TimeOfDay?) throws(PlanError) {
        guard let i = slots.firstIndex(where: { $0.id == slotID }) else { throw .unknownSlot }
        if let f = from, let u = until, f == u { throw .emptyWindow }
        slots[i].item.from = from
        slots[i].item.until = until
    }

    public mutating func clearWindow(slotID: String) {
        guard let i = slots.firstIndex(where: { $0.id == slotID }) else { return }
        slots[i].item.from = nil
        slots[i].item.until = nil
    }

    /// `Array.move(fromOffsets:toOffset:)` semantics (SwiftUI's), without SwiftUI.
    public mutating func moveSlots(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.sorted().map { slots[$0] }
        let before = source.filter { $0 < destination }.count
        var rest = slots.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        rest.insert(contentsOf: moving, at: max(0, min(rest.count, destination - before)))
        slots = rest
    }

    /// "Remove from tonight": takes an item out of the rotation; returns it.
    @discardableResult
    public mutating func deleteSlot(id: String) -> RotationSlot? {
        guard let i = slots.firstIndex(where: { $0.id == id }) else { return nil }
        return slots.remove(at: i)
    }

    // MARK: Validation

    public func issues(now: Date, clock: ClipClock) -> [PlanIssue] {
        var out: [PlanIssue] = []
        let n = Int(now.timeIntervalSince1970)
        let live = moments.filter { $0.endS > n }
        switch clock {
        case .unsynced where !live.isEmpty:
            out.append(PlanIssue(kind: .clockNotSynced, severity: .warning,
                                 message: "PixelClip’s clock isn’t set, so moments won’t fire. Sync it before you go."))
        case .unknown where !live.isEmpty:
            out.append(PlanIssue(kind: .clockUnknown, severity: .info,
                                 message: "Connect once to check PixelClip’s clock — moments only fire when it’s set."))
        default: break
        }
        for (a, b) in overlaps() where b.endS > n {
            out.append(PlanIssue(kind: .overlap(earlier: a.id, later: b.id), severity: .warning,
                                 message: "“\(b.title)” starts before “\(a.title)” ends."))
        }
        for m in moments {
            if m.endS <= n {
                out.append(PlanIssue(kind: .past(m.id), severity: .info, message: "“\(m.title)” is over."))
            } else if !Self.durationRangeS.contains(m.durationS) {
                out.append(PlanIssue(kind: .durationOutOfRange(m.id), severity: .blocking,
                                     message: "“\(m.title)” must last between 5 s and 30 min."))
            }
        }
        if live.count > Self.maxMoments {
            out.append(PlanIssue(kind: .tooManyMoments, severity: .blocking,
                                 message: "PixelClip can hold \(Self.maxMoments) moments; remove \(live.count - Self.maxMoments)."))
        }
        for s in slots {
            if let f = s.item.from, let u = s.item.until, f == u {
                out.append(PlanIssue(kind: .emptyWindow(s.id), severity: .blocking,
                                     message: "“\(s.title)” has an empty time window."))
            }
        }
        let playable = slots.filter { [.asset, .scene, .reader, .oracle].contains($0.item.type) }
        if nowItem == nil, !playable.isEmpty, playable.contains(where: \.hasWindow) {
            let covered = (0..<1440).allSatisfy { m in playable.contains { $0.item.isActive(atMinuteOfDay: m) } }
            if !covered {
                out.append(PlanIssue(kind: .idleGap, severity: .info,
                                     message: "At some hours nothing in the rotation is on; PixelClip shows its idle screen then."))
            }
        }
        return out.sorted { $0.severity > $1.severity }
    }

    public func canSend(now: Date) -> Bool {
        !issues(now: now, clock: .synced(at: nil)).contains { $0.severity == .blocking }
    }

    // MARK: Output

    /// The playlist document: items with their windows, and the queue of moments that haven't ended
    /// (ended ones are dropped: the firmware forgets their done-state, which is harmless since they
    /// can no longer be due). Sorted by `at` as the protocol says.
    ///
    /// Now comes first. Alone in the rotation it is *held*: `duration_ms` 0, no loops or transition,
    /// a strip without a pass count (the firmware plays a lone item on without re-transition, and a
    /// lone strip scrolls endlessly). Next to Tonight's items it keeps its rotation timing.
    public func playlist(now: Date, version: Int = 1) -> Playlist {
        let n = Int(now.timeIntervalSince1970)
        let queue = moments.filter { $0.endS > n }.map(\.entry)
        var items = slots.map(\.item)
        if var base = nowItem?.item {
            base.from = nil
            base.until = nil
            if slots.isEmpty { base = Self.held(base) }
            items.insert(base, at: 0)
        }
        return Playlist(version: version, items: items, queue: queue.isEmpty ? nil : queue)
    }

    /// The base item when it plays alone: indefinitely, no transition churn.
    static func held(_ item: PlaylistItem) -> PlaylistItem {
        var i = item
        i.durationMs = 0
        i.loops = nil
        i.transition = nil
        i.scroll?.loops = nil
        return i
    }
}

extension String {
    fileprivate func leftPad(_ n: Int) -> String { count >= n ? self : String(repeating: "0", count: n - count) + self }
}
