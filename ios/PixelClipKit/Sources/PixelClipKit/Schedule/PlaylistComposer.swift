import Foundation

// One playlist document for every sender (any "Send to PixelClip", Tonight's Send, the demo seeding):
// the one base item ("Now", which plays until something else is sent), then Tonight's
// rotation items (pictures, live scenes, readings — each with its window or none,
// "whenever") and Tonight's moments as `queue[]`. Pure value types; the app gathers the inputs.

/// The clip's base item: what it plays indefinitely ("Now"). Set by every plain send (a library
/// picture, a strip, a live scene, a reading); Tonight only adds around it.
public struct NowItem: Codable, Sendable, Hashable {
    public var content: MomentContent
    public var title: String
    public init(content: MomentContent, title: String) { self.content = content; self.title = title }

    /// Slot id of the base item in the planner.
    public static let slotID = "now"

    /// The base item as a rotation slot, timed for rotating with Tonight's items (the composer holds
    /// it, `duration_ms` 0, when it plays alone). `asset` gives a library picture's rotation item
    /// (durations, loops, scroll); nil drops the item (no longer in the library).
    public func slot(asset: (String) -> PlaylistItem?) -> RotationSlot? {
        let item: PlaylistItem
        switch content {
        case .asset(let id):
            guard let a = asset(id) else { return nil }
            item = a
        case .scene(let name, let params): item = .scene(name, params: params, durationMs: PlaybackEngine.sceneDefaultMs)
        case .words(let sheet, _): item = .words(sheet: sheet, durationMs: PlaybackEngine.sceneDefaultMs)
        case .board(let b): item = b.playlistItem()
        case .reader(let text, let font, let wpm): item = .reader(text: text, font: font, wpm: wpm)
        case .oracle(let o): item = o.playlistItem()
        }
        return RotationSlot(id: Self.slotID, item: item, title: title)
    }
}

extension MomentContent {
    /// What a playlist item shows (nil for types a moment can't show).
    public init?(item: PlaylistItem) {
        switch item.type {
        case .asset: guard let id = item.id else { return nil }; self = .asset(id)
        case .scene:
            if item.scene == WordsScene.name {
                guard let sheet = item.id else { return nil }
                self = .words(sheet: sheet, text: "")
            } else {
                self = .scene(item.scene ?? "sand", params: item.params ?? [:])
            }
        case .reader:
            guard let t = item.text, let f = item.font else { return nil }
            self = .reader(text: t, font: f, wpm: item.wpm ?? RSVPTiming.defaultWPM)
        case .oracle:
            guard let o = OracleItem(item: item) else { return nil }
            self = .oracle(o)
        case .board:
            guard let b = BoardContent(item: item) else { return nil }
            self = .board(b)
        default: return nil
        }
    }

    /// Same content, ignoring scene parameters and reading speed (what the clip shows).
    public func sameContent(as other: MomentContent) -> Bool {
        switch (self, other) {
        case (.asset(let a), .asset(let b)): a == b
        case (.scene(let a, _), .scene(let b, _)): a == b
        case (.words(let a, _), .words(let b, _)): a == b
        case (.board, .board): true
        case (.reader(let a, _, _), .reader(let b, _, _)): a == b
        case (.oracle(let a), .oracle(let b)): a.libraryKey == b.libraryKey
        default: false
        }
    }
}

/// Tonight's layer around the base item, as the app persists it.
public struct TonightLayer: Codable, Sendable, Equatable {
    public struct Window: Codable, Sendable, Hashable {
        public var from: TimeOfDay?
        public var until: TimeOfDay?
        public init(from: TimeOfDay?, until: TimeOfDay?) { self.from = from; self.until = until }
    }

    /// A rotation item Tonight adds next to Now: a library picture, a live scene, a reading.
    public struct Extra: Codable, Sendable, Hashable, Identifiable {
        public var id: String
        public var item: PlaylistItem
        public var title: String
        public init(id: String, item: PlaylistItem, title: String) { self.id = id; self.item = item; self.title = title }
    }

    /// Slot id → window (none: "whenever", it rotates with Now all day).
    public var windows: [String: Window]
    public var extras: [Extra]
    /// Slot ids in rotation order (slots not listed keep their relative order at the end).
    public var order: [String]
    public var moments: [Moment]

    public init(windows: [String: Window] = [:], extras: [Extra] = [], order: [String] = [], moments: [Moment] = []) {
        self.windows = windows; self.extras = extras; self.order = order; self.moments = moments
    }

    public static let empty = TonightLayer()

    /// Tonight adds nothing (no rotation items, no moments that haven't ended).
    public func isEmpty(now: Date) -> Bool {
        extras.isEmpty && !moments.contains { $0.endS > Int(now.timeIntervalSince1970) }
    }
}

public enum PlaylistComposer {
    /// Everything a send needs to know.
    public struct Inputs: Sendable, Equatable {
        /// The base item, timed for rotating (`NowItem.slot`); nil: only Tonight's items.
        public var now: RotationSlot?
        public var tonight: TonightLayer
        /// Asset id → scroll block, for strip assets (marquees); applied to rotation items and moments.
        public var scrolls: [String: PlaylistItem.Scroll]

        public init(now: RotationSlot? = nil, tonight: TonightLayer = .empty, scrolls: [String: PlaylistItem.Scroll] = [:]) {
            self.now = now; self.tonight = tonight; self.scrolls = scrolls
        }
    }

    /// The planner model: the base item, Tonight's rotation slots with their windows in Tonight's
    /// order, and the moments.
    public static func plan(_ inputs: Inputs) -> TonightPlan {
        let t = inputs.tonight
        func withScroll(_ slot: RotationSlot) -> RotationSlot {
            var s = slot
            if s.item.type == .asset, s.item.scroll == nil, let id = s.item.id, let scroll = inputs.scrolls[id] { s.item.scroll = scroll }
            return s
        }
        let slots = t.extras.map { x -> RotationSlot in
            var s = withScroll(RotationSlot(id: x.id, item: x.item, title: x.title))
            s.item.from = t.windows[x.id]?.from
            s.item.until = t.windows[x.id]?.until
            return s
        }
        let rank = Dictionary(t.order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let ordered = slots.enumerated().sorted { a, b in
            (rank[a.element.id] ?? t.order.count + a.offset) < (rank[b.element.id] ?? t.order.count + b.offset)
        }.map(\.element)
        var now = inputs.now.map(withScroll)
        now?.item.from = nil
        now?.item.until = nil
        // A rotation item showing what Now shows would only play it twice.
        let nowContent = now.flatMap { MomentContent(item: $0.item) }
        let slotsAroundNow = ordered.filter { s in
            guard let n = nowContent, let c = MomentContent(item: s.item) else { return true }
            return !c.sameContent(as: n)
        }
        return TonightPlan(nowItem: now, slots: slotsAroundNow, moments: t.moments)
    }

    /// The playlist document every sender PUTs: Now first (held, `duration_ms` 0, when it's alone),
    /// Tonight's items with windows, moments that haven't ended as `queue[]`, scroll blocks on strips.
    public static func playlist(_ inputs: Inputs, now: Date) -> Playlist {
        playlist(plan: plan(inputs), scrolls: inputs.scrolls, now: now)
    }

    /// Same, from an already-built plan (the Tonight screen edits one).
    public static func playlist(plan: TonightPlan, scrolls: [String: PlaylistItem.Scroll], now: Date) -> Playlist {
        var pl = plan.playlist(now: now)
        for i in pl.items.indices where pl.items[i].type == .asset && pl.items[i].scroll == nil {
            if let id = pl.items[i].id, let s = scrolls[id] { pl.items[i].scroll = s }
        }
        if var q = pl.queue {
            for i in q.indices where q[i].type == .asset && q[i].scroll == nil {
                if let id = q[i].asset, let s = scrolls[id] { q[i].scroll = s }
            }
            pl.queue = q
        }
        return pl
    }

    /// Identity of what a send would put on the clip: every moment (ended or not, so the clock passing
    /// doesn't look like an edit) plus the content hash of each asset.
    public static func fingerprint(_ inputs: Inputs, assetSHA: (String) -> String?) -> String {
        let pl = playlist(inputs, now: .distantPast)
        let json = (try? ClipJSON.encoder().encode(pl)) ?? Data()
        let shas = pl.assetIDs.compactMap(assetSHA).joined(separator: ",")
        return Hashing.sha256Hex(json + Data(shas.utf8))
    }
}

/// From the old model (a library playlist of N entries, plus Tonight's extras, all in one rotation)
/// to Now + Tonight: the first item without a window becomes Now (else the first item), every other
/// item becomes a Tonight rotation item with its window (none: "whenever"), in the same order, so
/// nothing disappears. Moments are kept.
public enum NowMigration {
    public struct Result: Sendable, Equatable {
        public var now: NowItem?
        public var tonight: TonightLayer
        /// Items that moved into Tonight's rotation.
        public var moved: Int
    }

    /// - Parameters:
    ///   - library: the old playlist's slots (keyed by entry id), with durations.
    public static func migrate(library: [RotationSlot], tonight: TonightLayer) -> Result {
        // The old composer's rotation.
        var slots = library + tonight.extras.map { RotationSlot(id: $0.id, item: $0.item, title: $0.title) }
        let rank = Dictionary(tonight.order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        slots = slots.enumerated().sorted { a, b in
            (rank[a.element.id] ?? tonight.order.count + a.offset) < (rank[b.element.id] ?? tonight.order.count + b.offset)
        }.map(\.element)
        guard !slots.isEmpty else { return Result(now: nil, tonight: tonight, moved: 0) }
        let pick = slots.firstIndex { tonight.windows[$0.id] == nil && MomentContent(item: $0.item) != nil }
            ?? slots.firstIndex { MomentContent(item: $0.item) != nil }
        var now: NowItem?
        if let pick, let content = MomentContent(item: slots[pick].item) {
            now = NowItem(content: content, title: slots[pick].title)
            slots.remove(at: pick)
        }
        var out = TonightLayer(moments: tonight.moments)
        for s in slots {
            let id = s.id
            var item = s.item
            item.from = nil
            item.until = nil
            out.extras.append(.init(id: id, item: item, title: s.title))
            if let w = tonight.windows[s.id] { out.windows[id] = w }
            out.order.append(id)
        }
        return Result(now: now, tonight: out, moved: slots.count)
    }
}
