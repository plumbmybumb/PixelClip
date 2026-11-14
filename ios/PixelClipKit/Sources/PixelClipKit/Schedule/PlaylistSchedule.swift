import Foundation

// PixelClip's playlist (docs/DESIGN.md "Playlist"): one list of things, each a minute. When the playlist is
// on, the clip rotates through the untimed entries in order (60 s each, fade); an entry with a time is a
// one-off `queue[]` entry at that time (60 s) and is not in the rotation. When it's off, Now holds and
// the timed entries still fire. Built on the composer's Tonight layer, so the device protocol is
// unchanged: untimed entries become rotation items (no windows), timed entries become moments.

/// One thing in the playlist.
///
/// `content` is the clip's content enum. There is no separate text case: a written message (Write) is
/// rendered and saved to the Library as a still or a scrolling strip, so it is `.asset(id)` like a photo.
public struct PlaylistEntry: Identifiable, Codable, Sendable, Hashable {
    public var id: String
    public var content: MomentContent
    /// nil: in the rotation. Set: plays once at this time for a minute, then the clip goes back to
    /// what it was doing (not in the rotation).
    public var at: Date?
    public var name: String

    public init(id: String = PlaylistEntry.makeID(), content: MomentContent, at: Date? = nil, name: String) {
        self.id = id; self.content = content; self.at = at; self.name = name
    }

    public var isTimed: Bool { at != nil }

    /// The one-off has played (or started) already.
    public func isPast(now: Date = Date()) -> Bool { at.map { $0 <= now } ?? false }

    /// `p-` + 8 hex digits.
    public static func makeID() -> String {
        var rng = SystemRandomNumberGenerator()
        return makeID(using: &rng)
    }

    public static func makeID<R: RandomNumberGenerator>(using rng: inout R) -> String {
        "p-" + String(UInt32.random(in: 0...UInt32.max, using: &rng), radix: 16).leftPadded8
    }

    /// The `queue[]` id of a timed entry: `q-<entry id>-<at, base 36>` (a new time is a new id, so the
    /// clip doesn't treat it as already played). Valid for the firmware (≤ 40 printable ASCII).
    public var queueID: String? {
        guard let at else { return nil }
        let safe = String(id.unicodeScalars.filter { $0.value >= 0x21 && $0.value <= 0x7E && $0 != "\"" && $0 != "\\" }.map(Character.init))
        return "q-\(safe.prefix(24))-\(String(Int(at.timeIntervalSince1970.rounded(.down)), radix: 36))"
    }
}

public enum PlaylistSchedule {
    /// "A minute each".
    public static let entryDurationMs = 60_000
    public static let entryDurationS = entryDurationMs / 1000

    /// An item timed for the playlist's rotation: a minute (an oracle three, `Oracle.rotationMs`, so a
    /// whole three-card sentence fits before the item ends), fade, no loop or pass count, no window.
    public static func minute(_ item: PlaylistItem) -> PlaylistItem {
        var i = item
        i.durationMs = item.type == .oracle ? Oracle.rotationMs : entryDurationMs
        i.loops = nil
        i.scroll?.loops = nil
        i.transition = .fade
        i.from = nil
        i.until = nil
        return i
    }

    /// The playlist item that shows `content`; `asset` gives a library picture's item (nil: it's gone).
    public static func item(for content: MomentContent, asset: (String) -> PlaylistItem?) -> PlaylistItem? {
        NowItem(content: content, title: "").slot(asset: asset)?.item
    }

    /// The composer's layer for the playlist: the untimed entries (only when on) as rotation items in
    /// order, a minute each; every timed entry as a one-minute moment. Entries whose picture is gone drop out.
    public static func layer(_ entries: [PlaylistEntry], isOn: Bool, asset: (String) -> PlaylistItem?) -> TonightLayer {
        var layer = TonightLayer()
        for e in entries {
            guard let item = item(for: e.content, asset: asset) else { continue }
            if let at = e.at, let qid = e.queueID {
                layer.moments.append(Moment(id: qid, at: Int(at.timeIntervalSince1970.rounded(.down)), content: e.content,
                                            durationS: e.content.isOracle ? Oracle.rotationMs / 1000 : entryDurationS,
                                            transition: .fade, title: e.name))
            } else if isOn {
                layer.extras.append(.init(id: e.id, item: minute(item), title: e.name))
                layer.order.append(e.id)
            }
        }
        return layer
    }

    /// Everything the composer needs: Now (a minute too when it rotates with the playlist; held when
    /// alone) and the playlist's layer.
    ///
    /// When the playlist is on, Now plays first in the rotation, so what was just sent shows at once and
    /// then the playlist takes turns with it (an entry showing the same thing as Now isn't played twice).
    public static func inputs(now: NowItem?, entries: [PlaylistEntry], isOn: Bool,
                              scrolls: [String: PlaylistItem.Scroll] = [:],
                              asset: (String) -> PlaylistItem?) -> PlaylistComposer.Inputs {
        let layer = layer(entries, isOn: isOn, asset: asset)
        var slot = now?.slot(asset: asset)
        if !layer.extras.isEmpty, let s = slot { slot?.item = minute(s.item) }
        return PlaylistComposer.Inputs(now: slot, tonight: layer, scrolls: scrolls)
    }

    /// The next time `hour:minute` comes round on `calendar`'s clock (today if it's still ahead, else
    /// tomorrow): what "Play it once at 21:30" means.
    public static func upcoming(hour: Int, minute: Int, after now: Date = Date(), calendar: Calendar = .current) -> Date {
        var c = calendar.dateComponents([.year, .month, .day], from: now)
        c.hour = hour
        c.minute = minute
        c.second = 0
        let today = calendar.date(from: c) ?? now
        return today > now ? today : calendar.date(byAdding: .day, value: 1, to: today) ?? today
    }
}

/// From the earlier design's Tonight (and the even older library playlist) to the playlist, once.
public enum PlaylistMigration {
    /// Tonight's rotation items (pictures, live scenes, readings, 8 balls) become untimed
    /// entries in Tonight's order (windows dropped); moments that haven't ended become timed entries
    /// (their time, in time order, after the untimed ones). Ended moments are dropped.
    public static func entries(from layer: TonightLayer, now: Date) -> [PlaylistEntry] {
        let plan = PlaylistComposer.plan(.init(tonight: layer))
        var out = plan.slots.compactMap { s -> PlaylistEntry? in
            MomentContent(item: s.item).map { PlaylistEntry(content: $0, name: s.title) }
        }
        let n = Int(now.timeIntervalSince1970)
        out += plan.moments.filter { $0.endS > n }.map { PlaylistEntry(content: $0.content, at: $0.start, name: $0.title) }
        return out
    }

    /// The old library playlist's slots (beyond the one that becomes Now) as untimed entries.
    public static func entries(fromLegacy slots: [RotationSlot]) -> [PlaylistEntry] {
        slots.compactMap { s in MomentContent(item: s.item).map { PlaylistEntry(content: $0, name: s.title) } }
    }
}

extension String {
    fileprivate var leftPadded8: String { count >= 8 ? self : String(repeating: "0", count: 8 - count) + self }
}
