import Foundation

/// What the planner knows about the clip's clock.
public enum ClipClock: Sendable, Equatable {
    /// `time.synced` is true; `at` is when it was last set from a phone, if known.
    case synced(at: Date?)
    /// `time.synced` is false: queue entries do not fire (PROTOCOL §4).
    case unsynced
    /// No status read yet.
    case unknown

    public init(status: ClipStatus?, lastSetAt: Date?) {
        guard let status else { self = .unknown; return }
        self = (status.clockOk ?? status.time.synced) ? .synced(at: lastSetAt) : .unsynced
    }

    public var isSynced: Bool { if case .synced = self { true } else { false } }
}

/// "What will the clip do", hour by hour, from a playlist document and the clip's clock.
///
/// Queue semantics follow the firmware scheduler (`components/sched`, `player.c`):
/// - Nothing fires while the clock is unsynced.
/// - Entries are taken in `at` order (stable for equal times). One plays at a time, for its full
///   `duration_ms` (default 60 s); an entry that comes due while another is playing waits and
///   starts when that one ends — unless it is then more than 10 minutes late, in which case it is
///   skipped.
/// - The rotation resumes after each entry. Items outside their `from`/`until` window are skipped;
///   with nothing active the idle screen shows.
public struct TimelineProjection: Sendable, Equatable {

    public enum Fate: Sendable, Equatable {
        /// Plays at its time.
        case onTime
        /// Starts `seconds` late because `after` is still playing (then plays in full).
        case delayed(seconds: Int, after: String)
        /// Would be more than 10 min late behind `after`: skipped by the clip.
        case skipped(after: String)
        case playingNow
        /// Already over.
        case past
        /// The clock isn't set: it won't fire.
        case wontFireClockNotSet
        /// The clock state is unknown: it fires only if the clock is set.
        case needsClockCheck

        public var fires: Bool {
            switch self {
            case .onTime, .delayed, .playingNow: true
            default: false
            }
        }
    }

    public struct ProjectedMoment: Sendable, Equatable, Identifiable {
        public var entry: QueueEntry
        /// When it would actually appear and end (== scheduled when on time; scheduled when it won't fire).
        public var start: Date
        public var end: Date
        public var fate: Fate
        public var id: String { entry.id }
        public var scheduled: Date { Date(timeIntervalSince1970: TimeInterval(entry.at)) }
    }

    /// A contiguous stretch during which rotation item `itemIndex` is in its window.
    public struct Span: Sendable, Equatable {
        public var itemIndex: Int
        public var start: Date
        public var end: Date
    }

    public struct Hour: Sendable, Equatable, Identifiable {
        public var start: Date
        public var end: Date
        /// "21:00", clip-local.
        public var label: String
        /// Rotation items in their window at some minute of this hour.
        public var activeItems: [Int]
        /// …for the whole hour.
        public var fullItems: [Int]
        /// Minutes of this hour with no rotation item active (idle screen unless a moment plays).
        public var idleMinutes: Int
        /// Moments scheduled to start in this hour.
        public var moments: [ProjectedMoment]
        public var id: Date { start }
    }

    public var now: Date
    public var start: Date
    public var end: Date
    public var local: ClipLocalTime
    public var clock: ClipClock
    public var hours: [Hour]
    public var spans: [Span]
    /// Every queue entry, in playback order.
    public var moments: [ProjectedMoment]

    /// Project `playlist` from the start of the current local hour to `now + hours`.
    public static func project(_ playlist: Playlist, now: Date, hours: Int = 12, clock: ClipClock,
                               local: ClipLocalTime) -> TimelineProjection {
        let start = local.startOfHour(now)
        let end = now.addingTimeInterval(TimeInterval(hours * 3600))
        let items = playlist.items
        let playable = items.map { PlaybackEngine.isPlayableType($0) }
        let moments = projectQueue(playlist.queue ?? [], now: now, clock: clock)

        // Minute grid for windows.
        let totalMinutes = Int(end.timeIntervalSince(start) / 60) + 1
        var spans: [Span] = []
        var open: [Int: Date] = [:]
        var activeAt: [[Int]] = []
        activeAt.reserveCapacity(totalMinutes)
        for k in 0..<totalMinutes {
            let t = start.addingTimeInterval(TimeInterval(k * 60))
            let m = local.minuteOfDay(t)
            let active = items.indices.filter { playable[$0] && items[$0].isActive(atMinuteOfDay: m) }
            activeAt.append(active)
            for i in items.indices {
                let on = active.contains(i)
                if on, open[i] == nil { open[i] = t }
                if !on, let s = open[i] { spans.append(Span(itemIndex: i, start: s, end: t)); open[i] = nil }
            }
        }
        let gridEnd = start.addingTimeInterval(TimeInterval(totalMinutes * 60))
        for (i, s) in open { spans.append(Span(itemIndex: i, start: s, end: gridEnd)) }
        spans.sort { ($0.start, $0.itemIndex) < ($1.start, $1.itemIndex) }

        var rows: [Hour] = []
        var h = start
        var k = 0
        while h < end {
            let next = h.addingTimeInterval(3600)
            let slice = activeAt[min(k, activeAt.count)..<min(k + 60, activeAt.count)]
            let any = Set(slice.flatMap { $0 })
            let all = slice.isEmpty ? Set<Int>() : slice.dropFirst().reduce(Set(slice.first!)) { $0.intersection($1) }
            rows.append(Hour(start: h, end: next, label: local.string(h), activeItems: any.sorted(), fullItems: all.sorted(),
                             idleMinutes: slice.filter(\.isEmpty).count,
                             moments: moments.filter { $0.scheduled >= h && $0.scheduled < next }))
            h = next
            k += 60
        }
        return TimelineProjection(now: now, start: start, end: end, local: local, clock: clock, hours: rows, spans: spans,
                                  moments: moments)
    }

    /// Firmware queue rules applied to time (see the type comment).
    public static func projectQueue(_ queue: [QueueEntry], now: Date, clock: ClipClock) -> [ProjectedMoment] {
        let ordered = queue.enumerated()
            .sorted { $0.element.at != $1.element.at ? $0.element.at < $1.element.at : $0.offset < $1.offset }
            .map(\.element)
        let nowS = now.timeIntervalSince1970
        var out: [ProjectedMoment] = []
        // When the entry currently playing (in the chain) ends, and which one it is.
        var busyUntil: Double = -.infinity
        var busyID = ""
        for e in ordered {
            let at = Double(e.at)
            let dur = Double(e.effectiveDurationMs) / 1000
            func make(_ s: Double, _ f: Fate) -> ProjectedMoment {
                ProjectedMoment(entry: e, start: Date(timeIntervalSince1970: s), end: Date(timeIntervalSince1970: s + dur), fate: f)
            }
            switch clock {
            case .unsynced:
                out.append(make(at, at + dur <= nowS ? .past : .wontFireClockNotSet))
                continue
            case .unknown, .synced:
                break
            }
            let start = max(at, busyUntil)
            let late = start - at
            if late > Double(QueueEntry.lateLimitS) {
                out.append(make(at, .skipped(after: busyID)))
                continue
            }
            let previous = busyID
            busyUntil = start + dur
            busyID = e.id
            let fate: Fate
            if start + dur <= nowS { fate = .past }
            else if clock == .unknown { fate = .needsClockCheck }
            else if start <= nowS { fate = .playingNow }
            else if late > 0 { fate = .delayed(seconds: Int(late.rounded(.up)), after: previous) }
            else { fate = .onTime }
            out.append(make(start, fate))
        }
        return out
    }

    // MARK: Queries

    public enum Showing: Sendable, Equatable {
        case moment(String)
        /// Rotation items in their window (the clip cycles through them).
        case rotation([Int])
        case idle
    }

    /// What the clip shows at `date` (moments that fire win over the rotation).
    public func showing(at date: Date, items: [PlaylistItem]) -> Showing {
        if let m = moments.first(where: { $0.fate.fires && $0.start <= date && date < $0.end }) { return .moment(m.id) }
        let minute = local.minuteOfDay(date)
        let active = items.indices.filter { PlaybackEngine.isPlayableType(items[$0]) && items[$0].isActive(atMinuteOfDay: minute) }
        return active.isEmpty ? .idle : .rotation(active)
    }

    /// Moments still to come that will (or may) fire.
    public var upcoming: [ProjectedMoment] {
        moments.filter { $0.end > now && $0.start < end && $0.fate != .past }
    }
}
