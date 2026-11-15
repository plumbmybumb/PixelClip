import Foundation

// JSON documents from docs/PROTOCOL.md §4–§5. Key names are spelled out in CodingKeys so they
// match the contract exactly, independent of any encoder key strategy.

/// Protocol major version this app speaks.
public let clipProtocolVersion = 1

// MARK: - Status

public struct ClipStatus: Codable, Sendable, Equatable {
    public var ok: Bool
    public var device: Device
    public var battery: Battery?
    public var storage: Storage
    public var playlist: PlaylistState
    public var time: TimeState
    public var session: Session?
    public var uptimeS: Int
    /// Scheduling extension: the tonight queue's state.
    public var queue: QueueState?
    /// True when time is synced (queue entries only fire then).
    public var clockOk: Bool?
    /// PROTOCOL §4 Orientation: absent on firmware that predates the 180° flip.
    public var orientation: Orientation?
    /// PROTOCOL §5f Oracle: absent on firmware that predates it (and, on the virtual clip, while no
    /// oracle is on screen).
    public var oracle: OracleStatus?

    enum CodingKeys: String, CodingKey {
        case ok, device, battery, storage, playlist, time, session, queue, orientation, oracle
        case uptimeS = "uptime_s"
        case clockOk = "clock_ok"
    }

    public init(ok: Bool = true, device: Device, battery: Battery?, storage: Storage,
                playlist: PlaylistState, time: TimeState, session: Session?, uptimeS: Int,
                queue: QueueState? = nil, clockOk: Bool? = nil, orientation: Orientation? = nil,
                oracle: OracleStatus? = nil) {
        self.ok = ok; self.device = device; self.battery = battery; self.storage = storage
        self.playlist = playlist; self.time = time; self.session = session; self.uptimeS = uptimeS
        self.queue = queue; self.clockOk = clockOk; self.orientation = orientation
        self.oracle = oracle
    }

    /// §5f.6: `"oracle":{"cards":22,"state":"waits|shuffle|three|short|thread|reading|reading-out|hold",
    /// "cards_drawn":[a,b,c],"card":-1,"page":-1,"reading":""}` (older firmware's `mode`, `question`, `daily_card`
    /// are read and ignored).
    public struct OracleStatus: Codable, Sendable, Equatable {
        public var cards: Int
        public var state: OracleState
        /// The three cards A, B, C, −1 each when not drawn.
        public var cardsDrawn: [Int]
        /// The detail card (§5f.7), −1 otherwise.
        public var card: Int
        /// The lean screen (0–4) or the detail (0–2) on screen, −1 otherwise.
        public var page: Int
        /// That screen's text on a lean or detail screen, the whole paragraph otherwise (§5f.7); nil when empty (the
        /// clip sends `""` then).
        public var reading: String?
        public init(cards: Int, state: OracleState, cardsDrawn: [Int] = [-1, -1, -1], card: Int = -1, page: Int = -1, reading: String? = nil) {
            self.cards = cards; self.state = state; self.cardsDrawn = cardsDrawn; self.card = card; self.page = page; self.reading = reading
        }
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            cards = try c.decodeIfPresent(Int.self, forKey: .cards) ?? 0
            state = try c.decodeIfPresent(OracleState.self, forKey: .state) ?? .waits
            cardsDrawn = try c.decodeIfPresent([Int].self, forKey: .cardsDrawn) ?? [-1, -1, -1]
            card = try c.decodeIfPresent(Int.self, forKey: .card) ?? -1
            page = try c.decodeIfPresent(Int.self, forKey: .page) ?? -1
            let r = try? c.decodeIfPresent(String.self, forKey: .reading)
            reading = (r ?? nil).flatMap { $0.isEmpty ? nil : $0 }
        }
        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(cards, forKey: .cards); try c.encode(state, forKey: .state); try c.encode(cardsDrawn, forKey: .cardsDrawn)
            try c.encode(card, forKey: .card); try c.encode(page, forKey: .page); try c.encode(reading ?? "", forKey: .reading)
        }
        enum CodingKeys: String, CodingKey {
            case cards, state, card, page, reading
            case cardsDrawn = "cards_drawn"
        }
        /// The three cards, when drawn.
        public var three: [Int]? { cardsDrawn.count == 3 && cardsDrawn.allSatisfy { $0 >= 0 } ? cardsDrawn : nil }
        /// Something has been drawn and is on screen (a press turns it on): anything but waits, armed and the shuffle.
        public var cardShowing: Bool { ![.waits, .armed, .shuffle].contains(state) }
        /// §5f.8: a draw is in progress (any screen but waits): the clip defers rotation, queue and sprinkles.
        public var drawInProgress: Bool { state != .waits }
    }

    /// `"orientation":{"mode":"auto","flipped":false}`: the configured mode and whether the screen is
    /// turned 180° right now (in `auto`, decided by gravity).
    public struct Orientation: Codable, Sendable, Equatable {
        public var mode: ClipOrientationMode
        public var flipped: Bool
        public init(mode: ClipOrientationMode, flipped: Bool) { self.mode = mode; self.flipped = flipped }
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            mode = try c.decodeIfPresent(ClipOrientationMode.self, forKey: .mode) ?? .auto
            flipped = try c.decodeIfPresent(Bool.self, forKey: .flipped) ?? false
        }
        enum CodingKeys: String, CodingKey { case mode, flipped }
    }

    /// The clip's screen is turned 180° right now (false when the firmware doesn't say).
    public var isFlipped: Bool { orientation?.flipped == true }

    public struct QueueState: Codable, Sendable, Equatable {
        public var pending: Int
        public var nextAt: Int?
        public var done: Int
        enum CodingKeys: String, CodingKey {
            case pending, done
            case nextAt = "next_at"
        }
        public init(pending: Int, nextAt: Int?, done: Int) { self.pending = pending; self.nextAt = nextAt; self.done = done }
    }

    public struct Device: Codable, Sendable, Equatable {
        public var name: String
        public var id: String
        public var fw: String
        public var hw: String
        public var protocolVersion: Int
        enum CodingKeys: String, CodingKey {
            case name, id, fw, hw
            case protocolVersion = "protocol"
        }
        public init(name: String, id: String, fw: String, hw: String, protocolVersion: Int) {
            self.name = name; self.id = id; self.fw = fw; self.hw = hw; self.protocolVersion = protocolVersion
        }
    }

    /// Fields are optional because the board may not expose a battery ADC (see PLAN §2).
    public struct Battery: Codable, Sendable, Equatable {
        public var mv: Int?
        public var pct: Int?
        public var charging: Bool?
        /// Firmware extension: USB power is connected.
        public var usbPresent: Bool?
        enum CodingKeys: String, CodingKey {
            case mv, pct, charging
            case usbPresent = "usb_present"
        }
        public init(mv: Int?, pct: Int?, charging: Bool?, usbPresent: Bool? = nil) {
            self.mv = mv; self.pct = pct; self.charging = charging; self.usbPresent = usbPresent
        }
        /// The firmware refuses/ends upload mode below 3.5 V.
        public static let uploadCutoffMv = 3500
        /// Close enough to the cutoff to warn.
        public var isNearUploadCutoff: Bool { (mv ?? 4000) < Battery.uploadCutoffMv + 80 && usbPresent != true }
    }

    public struct Storage: Codable, Sendable, Equatable {
        public var total: Int
        public var used: Int
        public var free: Int
        public init(total: Int, used: Int, free: Int) { self.total = total; self.used = used; self.free = free }
        public var fractionUsed: Double { total > 0 ? Double(used) / Double(total) : 0 }
    }

    /// `index` is -1 for an empty playlist; `current` is an asset id, `"scene:<name>"`,
    /// `"reader:<text id>"`, `"oracle:<asset id>"`, or nil (idle screen).
    public struct PlaylistState: Codable, Sendable, Equatable {
        public var count: Int
        public var index: Int
        public var current: String?
        public init(count: Int, index: Int, current: String?) { self.count = count; self.index = index; self.current = current }
    }

    public struct TimeState: Codable, Sendable, Equatable {
        public var epoch: Int
        public var tzOffsetS: Int
        public var synced: Bool
        enum CodingKeys: String, CodingKey {
            case epoch, synced
            case tzOffsetS = "tz_offset_s"
        }
        public init(epoch: Int, tzOffsetS: Int, synced: Bool) { self.epoch = epoch; self.tzOffsetS = tzOffsetS; self.synced = synced }
    }

    public struct Session: Codable, Sendable, Equatable {
        public var idleS: Int
        public var timeoutS: Int
        /// `wifi_always_on`: the access point stays up with no idle timeout (PROTOCOL §3).
        public var alwaysOn: Bool?
        enum CodingKeys: String, CodingKey {
            case idleS = "idle_s"
            case timeoutS = "timeout_s"
            case alwaysOn = "always_on"
        }
        public init(idleS: Int, timeoutS: Int, alwaysOn: Bool? = nil) { self.idleS = idleS; self.timeoutS = timeoutS; self.alwaysOn = alwaysOn }
    }

    /// The hotspot SSID derived from the device id (`PixelClip-` + id upper-cased).
    public var ssid: String { HotspotDefaults.ssidPrefix + device.id.uppercased() }
}

// MARK: - Assets

public struct ClipAsset: Codable, Sendable, Equatable, Hashable {
    public var id: String
    public var size: Int
    public var sha256: String
    public var width: Int
    public var height: Int
    public var frames: Int
    public var atlas: Bool
    /// A scrolling strip (one frame wider than the screen, PROTOCOL §2 `is_strip`). Omitted by
    /// firmware that predates strips, so nil means "not a strip".
    public var strip: Bool?

    public init(id: String, size: Int, sha256: String, width: Int, height: Int, frames: Int, atlas: Bool, strip: Bool? = nil) {
        self.id = id; self.size = size; self.sha256 = sha256
        self.width = width; self.height = height; self.frames = frames; self.atlas = atlas; self.strip = strip
    }

    public var isStrip: Bool { strip == true }
}

public struct AssetList: Codable, Sendable, Equatable {
    public var ok: Bool
    public var assets: [ClipAsset]
    public init(ok: Bool = true, assets: [ClipAsset]) { self.ok = ok; self.assets = assets }
}

/// `201 {"ok":true,"id","size","sha256"}` from `PUT /assets/{id}`.
public struct AssetPutResponse: Codable, Sendable, Equatable {
    public var ok: Bool
    public var id: String
    public var size: Int
    public var sha256: String
    public init(ok: Bool = true, id: String, size: Int, sha256: String) {
        self.ok = ok; self.id = id; self.size = size; self.sha256 = sha256
    }
}

public enum AssetPutResult: Sendable, Equatable {
    case created(AssetPutResponse)
    /// `409`: the clip already has this exact content under this id.
    case alreadyPresent
}

// MARK: - Playlist

/// String-backed so unknown future values survive a round-trip.
public struct PlaylistItemType: RawRepresentable, Codable, Sendable, Hashable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(from decoder: any Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: any Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }

    public static let asset = PlaylistItemType(rawValue: "asset")
    public static let clock = PlaylistItemType(rawValue: "clock")
    public static let text = PlaylistItemType(rawValue: "text")
    public static let scene = PlaylistItemType(rawValue: "scene")
    /// Reader mode (PROTOCOL §5c): one word at a time from an uploaded text.
    public static let reader = PlaylistItemType(rawValue: "reader")
    /// Oracle (PROTOCOL §5f): an asset of a face-down frame and, per card, a face and reading pages.
    public static let oracle = PlaylistItemType(rawValue: "oracle")
    /// Board (PROTOCOL §5g): a sheet of row pictures the clip stacks, drops by their `until` and scrolls.
    public static let board = PlaylistItemType(rawValue: "board")

    /// Types whose item names an uploaded asset (`id` on playlist items, `asset` in the queue). An oracle's
    /// `id` is its phrase bundle's `/texts` id since §5f.2 (its assets are the deck, keys and notes).
    public var usesAsset: Bool { self == .asset }
}

public enum Transition: String, Codable, Sendable, Hashable, CaseIterable {
    case cut, fade
    /// Fade = 250 ms ramp down, swap, ramp up.
    public static let fadeHalfMs = 250
}

/// A scene parameter: the protocol allows flat strings or numbers.
public enum SceneParam: Codable, Sendable, Hashable {
    case string(String)
    case number(Double)

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let d = try? c.decode(Double.self) { self = .number(d) } else { self = .string(try c.decode(String.self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let d):
            if d == d.rounded(), abs(d) < 1e15 { try c.encode(Int(d)) } else { try c.encode(d) }
        }
    }
}

/// A local time of day, `"HH:MM"` (PROTOCOL §4 scheduling). `"24:00"` (minutes 1440) is the end of
/// the day and is only valid as a window's `until` (the playlist decoder enforces that).
public struct TimeOfDay: Codable, Sendable, Hashable, Comparable {
    public var minutes: Int   // 0…1439, or 1440 for "24:00"

    public init(hour: Int, minute: Int) { minutes = (hour * 60 + minute) % 1440 }

    /// `"24:00"`: the end of the day (an `until` bound only).
    public static let endOfDay = TimeOfDay(minutesUnchecked: 1440)
    private init(minutesUnchecked m: Int) { minutes = m }

    public var isEndOfDay: Bool { minutes == 1440 }

    public init?(_ string: String) {
        let parts = string.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 2, parts[1].count == 2,
              parts[0].allSatisfy(\.isASCIIDigit), parts[1].allSatisfy(\.isASCIIDigit),
              let h = Int(parts[0]), let m = Int(parts[1]), (0..<60).contains(m) else { return nil }
        if h == 24 && m == 0 { minutes = 1440; return }
        guard (0..<24).contains(h) else { return nil }
        minutes = h * 60 + m
    }

    public init(from decoder: any Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let t = TimeOfDay(s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Expected HH:MM, got \(s)"))
        }
        self = t
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(string)
    }

    public var string: String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }
    public static func < (a: TimeOfDay, b: TimeOfDay) -> Bool { a.minutes < b.minutes }

    /// Whether `minuteOfDay` falls in `[from, until)`; windows may cross midnight; a missing bound
    /// means 00:00 / 24:00 (firmware `sched_window_contains`).
    public static func window(from: TimeOfDay?, until: TimeOfDay?, contains minuteOfDay: Int) -> Bool {
        if from == nil && until == nil { return true }
        let f = from?.minutes ?? 0
        let u = until?.minutes ?? 1440
        if f == u { return true }   // rejected when sent; defensive, like the firmware
        return f < u ? (minuteOfDay >= f && minuteOfDay < u) : (minuteOfDay >= f || minuteOfDay < u)
    }
}

extension Character {
    fileprivate var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}

public struct PlaylistItem: Codable, Sendable, Equatable, Hashable {
    public var type: PlaylistItemType
    /// Asset id (`type == asset`).
    public var id: String?
    public var durationMs: Int
    public var loops: Int?
    public var transition: Transition?
    /// `type == scene`: which live scene, and its parameters.
    public var scene: String?
    public var params: [String: SceneParam]?
    /// Optional local time-of-day window; outside it the item is skipped.
    public var from: TimeOfDay?
    public var until: TimeOfDay?
    /// Strip assets only: how the device scrolls the strip (PROTOCOL §4 "Scrolling strips").
    public var scroll: Scroll?
    /// `type == reader` (PROTOCOL §5c): text id, reader font id, words per minute, an optional start
    /// word (overrides the clip's saved progress) and whether to start over at the end.
    public var text: String?
    public var font: String?
    public var wpm: Int?
    public var fromWord: Int?
    public var loop: Bool?
    /// `type == oracle` (§5f): how long the final frame holds (0 = forever), the shake threshold in g.
    public var holdMs: Int?
    public var shakeG: Double?
    /// `type == oracle` (PROTOCOL §5f): cards and reading pages in the asset, card of the day, how long
    /// the face and each page show before turning by themselves (0 = only on a press).
    public var cards: Int?
    public var pages: Int?
    public var faceMs: Int?
    public var pageMs: Int?
    /// `type == oracle`: the deck, keys and notes assets (`id` / `asset` is the phrase bundle).
    public var deck: String?
    public var keys: String?
    public var notes: String?
    /// `type == oracle` (§5f.1/§5f.2): the phrase bundle (a `/texts` id; since §5f.2 the same as `id`, kept one
    /// release as an alias) and the numeral's big font (`/fonts` id, optional; `font` is the body font).
    public var reader: String?
    public var fontBig: String?
    /// `type == board` (§5g): the header and empty frames, the rows (frame + until), the scroll speed.
    public var header: Int? = nil
    public var empty: Int? = nil
    public var rows: [BoardRow]? = nil
    public var scrollPxS: Int? = nil

    /// `{"x":40,"y":21,"w":104,"h":198}`: a rectangle in frame pixels (the oracle's card slot).
    public struct Window: Codable, Sendable, Hashable {
        public var x: Int, y: Int, w: Int, h: Int
        public init(x: Int, y: Int, w: Int, h: Int) { self.x = x; self.y = y; self.w = w; self.h = h }
        public func contains(x px: Int, y py: Int) -> Bool { px >= x && px < x + w && py >= y && py < y + h }
        /// Inside the 536×240 frame, non-empty, even `x` and `w` (the firmware blends pixel pairs).
        public var isValid: Bool {
            w > 0 && h > 0 && x >= 0 && y >= 0 && x + w <= ClipCanvas.width && y + h <= ClipCanvas.height && x % 2 == 0 && w % 2 == 0
        }
    }

    /// `{"px_per_s":80,"direction":"left","gap_px":120,"loops":3}`.
    public struct Scroll: Codable, Sendable, Hashable {
        public enum Direction: String, Codable, Sendable, Hashable, CaseIterable { case left, right }
        public var pxPerS: Int
        public var direction: Direction
        public var gapPx: Int
        public var loops: Int?

        enum CodingKeys: String, CodingKey {
            case direction, loops
            case pxPerS = "px_per_s"
            case gapPx = "gap_px"
        }

        public init(pxPerS: Int, direction: Direction = .left, gapPx: Int = 0, loops: Int? = nil) {
            self.pxPerS = pxPerS; self.direction = direction; self.gapPx = gapPx; self.loops = loops
        }

        /// Every key is optional on the wire; missing ones take the firmware's defaults
        /// (80 px/s, left, 0 px gap, 1 pass).
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let d = try? c.decode(Double.self, forKey: .pxPerS) { pxPerS = Int(d.rounded()) } else { pxPerS = Self.defaultSpeed }
            direction = try c.decodeIfPresent(Direction.self, forKey: .direction) ?? .left
            gapPx = try c.decodeIfPresent(Int.self, forKey: .gapPx) ?? 0
            loops = try c.decodeIfPresent(Int.self, forKey: .loops)
        }

        /// Protocol range for `px_per_s`.
        public static let speedRange = 10...400
        public static let defaultSpeed = 80
        /// Firmware limit for `gap_px` (`PL_SCROLL_MAX_GAP`).
        public static let maxGap = 2000
        /// Strip widths the device accepts (`STORAGE_STRIP_MIN_W`…`MAX_W`): a strip is wider than the screen.
        public static let minStripWidth = 537
        public static let maxStripWidth = 8192
        public static var stripWidths: ClosedRange<Int> { minStripWidth...maxStripWidth }
    }

    enum CodingKeys: String, CodingKey {
        case type, id, loops, transition, scene, params, from, until, scroll, text, font, wpm, loop
        case cards, pages, deck, keys, notes, reader, header, empty, rows
        case scrollPxS = "scroll_px_s"
        case durationMs = "duration_ms"
        case fromWord = "from_word"
        case holdMs = "hold_ms"
        case shakeG = "shake_g"
        case faceMs = "face_ms"
        case pageMs = "page_ms"
        case fontBig = "font_big"
    }

    public init(type: PlaylistItemType, id: String? = nil, durationMs: Int, loops: Int? = nil, transition: Transition? = nil,
                scene: String? = nil, params: [String: SceneParam]? = nil, from: TimeOfDay? = nil, until: TimeOfDay? = nil,
                scroll: Scroll? = nil, text: String? = nil, font: String? = nil, wpm: Int? = nil, fromWord: Int? = nil,
                loop: Bool? = nil, holdMs: Int? = nil, shakeG: Double? = nil,
                cards: Int? = nil, pages: Int? = nil, faceMs: Int? = nil, pageMs: Int? = nil,
                deck: String? = nil, keys: String? = nil, notes: String? = nil, reader: String? = nil,
                fontBig: String? = nil, header: Int? = nil, empty: Int? = nil, rows: [BoardRow]? = nil, scrollPxS: Int? = nil) {
        self.header = header; self.empty = empty; self.rows = rows; self.scrollPxS = scrollPxS
        self.type = type; self.id = id; self.durationMs = durationMs; self.loops = loops; self.transition = transition
        self.scene = scene; self.params = params; self.from = from; self.until = until; self.scroll = scroll
        self.text = text; self.font = font; self.wpm = wpm; self.fromWord = fromWord; self.loop = loop
        self.holdMs = holdMs; self.shakeG = shakeG
        self.cards = cards; self.pages = pages; self.faceMs = faceMs; self.pageMs = pageMs
        self.deck = deck; self.keys = keys; self.notes = notes; self.reader = reader; self.fontBig = fontBig
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(PlaylistItemType.self, forKey: .type)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        durationMs = try c.decodeIfPresent(Int.self, forKey: .durationMs) ?? 0
        loops = try c.decodeIfPresent(Int.self, forKey: .loops)
        transition = try c.decodeIfPresent(Transition.self, forKey: .transition)
        scene = try c.decodeIfPresent(String.self, forKey: .scene)
        params = try c.decodeIfPresent([String: SceneParam].self, forKey: .params)
        from = try c.decodeIfPresent(TimeOfDay.self, forKey: .from)
        until = try c.decodeIfPresent(TimeOfDay.self, forKey: .until)
        scroll = try c.decodeIfPresent(Scroll.self, forKey: .scroll)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        font = try c.decodeIfPresent(String.self, forKey: .font)
        wpm = try c.decodeIfPresent(Int.self, forKey: .wpm)
        fromWord = try c.decodeIfPresent(Int.self, forKey: .fromWord)
        loop = try c.decodeIfPresent(Bool.self, forKey: .loop)
        holdMs = try c.decodeIfPresent(Int.self, forKey: .holdMs)
        shakeG = try c.decodeIfPresent(Double.self, forKey: .shakeG)
        cards = try c.decodeIfPresent(Int.self, forKey: .cards)
        pages = try c.decodeIfPresent(Int.self, forKey: .pages)
        faceMs = try c.decodeIfPresent(Int.self, forKey: .faceMs)
        pageMs = try c.decodeIfPresent(Int.self, forKey: .pageMs)
        deck = try c.decodeIfPresent(String.self, forKey: .deck)
        keys = try c.decodeIfPresent(String.self, forKey: .keys)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        reader = try c.decodeIfPresent(String.self, forKey: .reader)
        fontBig = try c.decodeIfPresent(String.self, forKey: .fontBig)
        header = try c.decodeIfPresent(Int.self, forKey: .header)
        empty = try c.decodeIfPresent(Int.self, forKey: .empty)
        rows = try c.decodeIfPresent([BoardRow].self, forKey: .rows)
        scrollPxS = try c.decodeIfPresent(Int.self, forKey: .scrollPxS)
        if from?.isEndOfDay == true {
            throw DecodingError.dataCorruptedError(forKey: .from, in: c, debugDescription: "\"24:00\" is only valid as until")
        }
    }

    public static func asset(_ id: String, durationMs: Int, loops: Int? = nil, transition: Transition? = .fade) -> PlaylistItem {
        PlaylistItem(type: .asset, id: id, durationMs: durationMs, loops: loops, transition: transition)
    }

    public static func scene(_ name: String, params: [String: SceneParam]? = nil, durationMs: Int, transition: Transition? = .fade) -> PlaylistItem {
        PlaylistItem(type: .scene, durationMs: durationMs, transition: transition, scene: name, params: params)
    }

    /// §5b.1: `{"type":"scene","scene":"words","id":"<sheet>","params":{"bounce":60}}`.
    public static func words(sheet: String, bounce: Int = WordsScene.defaultBounce, durationMs: Int, transition: Transition? = .fade) -> PlaylistItem {
        PlaylistItem(type: .scene, id: sheet, durationMs: durationMs, transition: transition, scene: WordsScene.name,
                     params: ["bounce": .number(Double(bounce))])
    }

    /// A `words` scene (its `id` is the sheet).
    public var isWords: Bool { type == .scene && scene == WordsScene.name }

    /// `{"type":"reader","text":"id","font":"id","wpm":300,"from_word":0,"loop":false,"duration_ms":0}`;
    /// `duration_ms` 0 = until the text is finished. `fromWord` nil = resume where the clip stopped.
    public static func reader(text: String, font: String, wpm: Int, fromWord: Int? = nil, loop: Bool = false,
                              durationMs: Int = 0, transition: Transition? = .fade) -> PlaylistItem {
        PlaylistItem(type: .reader, durationMs: durationMs, transition: transition, text: text, font: font, wpm: wpm,
                     fromWord: fromWord, loop: loop)
    }

    /// §5f.2/§5f.6/§5f.7: `{"type":"oracle","id":B,"reader":B,"deck":D,"keys":K,"font":F,"font_big":G,"cards":22,
    ///   "shake_g":0.9,"face_ms":0,"page_ms":0,"hold_ms":300000,"transition":"fade"}` (no `mode`, `daily`, `notes`).
    /// (`id` = the phrase bundle's `/texts` id, `reader` its alias; no `pages`, no text asset).
    public static func oracle(_ o: OracleItem, durationMs: Int = 0, transition: Transition? = .fade) -> PlaylistItem {
        PlaylistItem(type: .oracle, id: o.id, durationMs: durationMs, transition: transition, font: o.font,
                     holdMs: o.holdMs, shakeG: o.shakeG, cards: o.cards, faceMs: o.faceMs,
                     pageMs: o.pageMs, deck: o.deck, keys: o.keys, reader: o.id,
                     fontBig: o.font == nil ? nil : o.fontBig)
    }

    /// The asset this item shows (pictures), nil otherwise.
    public var assetRef: String? { type.usesAsset || isWords || type == .board ? id : nil }

    /// Every asset this item needs: a picture's own, a `words` scene's sheet; an oracle's deck and keys (and an older item's notes; its bundle and fonts
    /// are `/texts` and `/fonts`, see `oracleTextID` / `oracleFontIDs`).
    public var assetRefs: [String] {
        if type == .oracle { return id == nil ? [] : [deck, keys, notes].compactMap { $0 } }
        return assetRef.map { [$0] } ?? []
    }

    public func isActive(atMinuteOfDay m: Int) -> Bool { TimeOfDay.window(from: from, until: until, contains: m) }
}

/// A one-shot timed interrupt from the playlist's `queue[]`.
/// Note the asset key is `asset` here (`id` is the entry's own id).
public struct QueueEntry: Codable, Sendable, Equatable, Hashable {
    public var id: String
    /// Unix seconds.
    public var at: Int
    public var type: PlaylistItemType
    public var asset: String?
    public var scene: String?
    public var params: [String: SceneParam]?
    /// Default 60 s when omitted or 0.
    public var durationMs: Int?
    public var transition: Transition?
    /// Strip assets: same block as on playlist items.
    public var scroll: PlaylistItem.Scroll?
    /// Reader entries (PROTOCOL §5c): same keys as the playlist item.
    public var text: String?
    public var font: String?
    public var wpm: Int?
    public var fromWord: Int?
    public var loop: Bool?
    public var holdMs: Int?
    public var shakeG: Double?
    /// Oracle entries (PROTOCOL §5f): same keys as the playlist item (the text asset id is `asset`).
    public var cards: Int?
    public var pages: Int?
    public var faceMs: Int?
    public var pageMs: Int?
    /// `type == oracle`: the deck, keys and notes assets (`id` / `asset` is the phrase bundle).
    public var deck: String?
    public var keys: String?
    public var notes: String?
    /// `type == oracle` (§5f.2): the phrase bundle's `/texts` id (= `asset`, kept as an alias) and the big font.
    public var reader: String?
    public var fontBig: String?
    /// `type == board` (§5g): as on playlist items (the sheet is `asset`).
    public var header: Int? = nil
    public var empty: Int? = nil
    public var rows: [BoardRow]? = nil
    public var scrollPxS: Int? = nil

    enum CodingKeys: String, CodingKey {
        case id, at, type, asset, scene, params, transition, scroll, text, font, wpm, loop
        case cards, pages, deck, keys, notes, reader, header, empty, rows
        case scrollPxS = "scroll_px_s"
        case durationMs = "duration_ms"
        case fromWord = "from_word"
        case holdMs = "hold_ms"
        case shakeG = "shake_g"
        case faceMs = "face_ms"
        case pageMs = "page_ms"
        case fontBig = "font_big"
    }

    public init(id: String, at: Int, type: PlaylistItemType, asset: String? = nil, scene: String? = nil,
                params: [String: SceneParam]? = nil, durationMs: Int? = nil, transition: Transition? = nil,
                scroll: PlaylistItem.Scroll? = nil, text: String? = nil, font: String? = nil, wpm: Int? = nil,
                fromWord: Int? = nil, loop: Bool? = nil, holdMs: Int? = nil,
                shakeG: Double? = nil, cards: Int? = nil, pages: Int? = nil, faceMs: Int? = nil,
                pageMs: Int? = nil, deck: String? = nil, keys: String? = nil, notes: String? = nil,
                reader: String? = nil, fontBig: String? = nil) {
        self.id = id; self.at = at; self.type = type; self.asset = asset; self.scene = scene
        self.params = params; self.durationMs = durationMs; self.transition = transition; self.scroll = scroll
        self.text = text; self.font = font; self.wpm = wpm; self.fromWord = fromWord; self.loop = loop
        self.holdMs = holdMs; self.shakeG = shakeG
        self.cards = cards; self.pages = pages; self.faceMs = faceMs; self.pageMs = pageMs
        self.deck = deck; self.keys = keys; self.notes = notes; self.reader = reader; self.fontBig = fontBig
    }

    /// The asset this entry shows (pictures), nil otherwise.
    public var assetRef: String? { type.usesAsset || (type == .scene && scene == WordsScene.name) || type == .board ? asset : nil }

    /// Every asset this entry needs: a picture's own; an oracle's deck, keys and notes.
    public var assetRefs: [String] {
        if type == .oracle { return asset == nil ? [] : [deck, keys, notes].compactMap { $0 } }
        return assetRef.map { [$0] } ?? []
    }

    public static let defaultDurationMs = 60_000
    /// Entries discovered later than this are skipped.
    public static let lateLimitS = 600
    public var effectiveDurationMs: Int { (durationMs ?? 0) > 0 ? durationMs! : Self.defaultDurationMs }

    /// The same content as a playlist item (for playback).
    public var asPlaylistItem: PlaylistItem {
        PlaylistItem(type: type, id: asset, durationMs: effectiveDurationMs, transition: transition ?? .fade, scene: scene, params: params,
                     scroll: scroll, text: text, font: font, wpm: wpm, fromWord: fromWord, loop: loop,
                     holdMs: holdMs, shakeG: shakeG, cards: cards, pages: pages,
                     faceMs: faceMs, pageMs: pageMs, deck: deck, keys: keys, notes: notes, reader: reader, fontBig: fontBig,
                     header: header, empty: empty, rows: rows, scrollPxS: scrollPxS)
    }
}

public struct Playlist: Codable, Sendable, Equatable, Hashable {
    public var version: Int
    public var items: [PlaylistItem]
    /// One-shot timed interrupts ("tonight" queue). Omitted when nil.
    public var queue: [QueueEntry]?

    public init(version: Int = 1, items: [PlaylistItem], queue: [QueueEntry]? = nil) {
        self.version = version; self.items = items; self.queue = queue
    }
    public static let empty = Playlist(items: [])

    /// The scroll block a "Show now" of `assetID` should carry: the rotation item's for that asset,
    /// else a moment's, else `fallback` (the library item's), without `loops` (a show lasts its duration).
    public func showScroll(for assetID: String, fallback: PlaylistItem.Scroll? = nil) -> PlaylistItem.Scroll? {
        var s = items.first { $0.type == .asset && $0.id == assetID && $0.scroll != nil }?.scroll
            ?? queue?.first { $0.type == .asset && $0.asset == assetID && $0.scroll != nil }?.scroll
            ?? fallback
        s?.loops = nil
        return s
    }

    /// Asset ids referenced by items and queue entries (pictures, an oracle's four assets), in
    /// order, without duplicates.
    public var assetIDs: [String] {
        var seen = Set<String>()
        let fromItems = items.flatMap(\.assetRefs)
        let fromQueue = (queue ?? []).flatMap(\.assetRefs)
        return (fromItems + fromQueue).filter { seen.insert($0).inserted }
    }

    /// The oracle item (rotation first, then the queue) that shows `assetID`, for a "Show now" of it.
    public func oracleItem(for assetID: String) -> PlaylistItem? {
        items.first { $0.type == .oracle && $0.id == assetID }
            ?? queue?.first { $0.type == .oracle && $0.asset == assetID }?.asPlaylistItem
    }

    /// Text ids referenced by reader items and queue entries, in order, without duplicates.
    public var textIDs: [String] {
        var seen = Set<String>()
        return (items.compactMap { $0.type == .reader ? $0.text : nil } + (queue ?? []).compactMap { $0.type == .reader ? $0.text : nil })
            .filter { seen.insert($0).inserted }
    }

    /// The oracles' phrase bundles (`/texts` ids: an oracle item's `id`, a queue entry's `asset`, §5f.2), in
    /// order, without duplicates.
    public var oracleReaderIDs: [String] {
        var seen = Set<String>()
        return (items.compactMap { $0.type == .oracle ? $0.id : nil } + (queue ?? []).compactMap { $0.type == .oracle ? $0.asset : nil })
            .filter { seen.insert($0).inserted }
    }

    /// The fonts (`/fonts` ids) oracle items and entries write with: the body font and the big one (§5f.2).
    public var oracleFontIDs: [String] {
        var seen = Set<String>()
        return (items.flatMap { $0.type == .oracle ? [$0.font, $0.fontBig].compactMap { $0 } : [] }
            + (queue ?? []).flatMap { $0.type == .oracle ? [$0.font, $0.fontBig].compactMap { $0 } : [] })
            .filter { seen.insert($0).inserted }
    }

    /// Oracles whose bundle or body font isn't available are left out (the clip writes every screen with them
    /// and would refuse the item with 422 `unknown_text` / `unknown_font`); one whose big font is missing loses
    /// `font_big` (the clip falls back to the body font for the numeral).
    public func withoutUnavailableOracles(missingTexts: Set<String>, missingFonts: Set<String>) -> Playlist {
        func keep(_ id: String?, _ font: String?) -> Bool {
            guard let id, let font else { return false }
            return !missingTexts.contains(id) && !missingFonts.contains(font)
        }
        var p = self
        p.items = p.items.filter { $0.type != .oracle || keep($0.id, $0.font) }
        for i in p.items.indices where p.items[i].type == .oracle && p.items[i].fontBig.map(missingFonts.contains) == true {
            p.items[i].fontBig = nil
        }
        if var q = p.queue {
            q = q.filter { $0.type != .oracle || keep($0.asset, $0.font) }
            for i in q.indices where q[i].type == .oracle && q[i].fontBig.map(missingFonts.contains) == true { q[i].fontBig = nil }
            p.queue = q
        }
        return p
    }

    /// Reader font ids referenced by reader items and queue entries, in order, without duplicates.
    public var fontIDs: [String] {
        var seen = Set<String>()
        return (items.compactMap { $0.type == .reader ? $0.font : nil } + (queue ?? []).compactMap { $0.type == .reader ? $0.font : nil })
            .filter { seen.insert($0).inserted }
    }
}

/// `GET /scenes`.
public struct SceneCatalog: Codable, Sendable, Equatable {
    public struct Scene: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        /// Either a list of allowed strings or a `[min, max]` numeric range, per parameter.
        public var params: [String: SceneParamSpec]
        public init(id: String, params: [String: SceneParamSpec]) { self.id = id; self.params = params }
    }
    public var ok: Bool
    public var scenes: [Scene]
    public init(ok: Bool = true, scenes: [Scene]) { self.ok = ok; self.scenes = scenes }

    /// Every scene the firmware's `/scenes` can return (the firmware list itself stays as it is).
    public static let knownScenes = ["sand", "water", "fire", "balls", "snow", "lava", WordsScene.name]

    /// The scenes the app offers, in picker order. The single app-side allow-list read by every scene
    /// picker (Tonight's moment sheet, the "Live Scene" add menu, the virtual clip's catalogue).
    /// ("lava" is left out.)
    public static let enabledIDs = ["sand", "water", "snow", "fire", "balls"]

    public static func isEnabled(_ id: String) -> Bool { enabledIDs.contains(id) }

    /// This catalogue minus scenes the app doesn't offer, in `enabledIDs` order.
    public var enabled: SceneCatalog {
        var copy = self
        copy.scenes = Self.enabledIDs.compactMap { id in scenes.first { $0.id == id } }
        return copy
    }
}

public enum SceneParamSpec: Codable, Sendable, Equatable {
    case choices([String])
    case range(Double, Double)

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let strings = try? c.decode([String].self) { self = .choices(strings); return }
        let nums = try c.decode([Double].self)
        guard nums.count == 2 else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "range needs 2 numbers")) }
        self = .range(nums[0], nums[1])
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .choices(let s): try c.encode(s)
        case .range(let a, let b):
            if a == a.rounded() && b == b.rounded() { try c.encode([Int(a), Int(b)]) } else { try c.encode([a, b]) }
        }
    }
}

// MARK: - Config

/// PROTOCOL §4 Orientation: config `orientation`. `auto` flips the screen 180° from gravity (the clip
/// worn the other way up); `normal` / `flipped` force one. An unknown value decodes as `auto` (the
/// firmware default), so a newer firmware's mode never breaks reading the config.
public enum ClipOrientationMode: String, Codable, Sendable, Hashable, CaseIterable {
    case auto, normal, flipped

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ClipOrientationMode(rawValue: raw) ?? .auto
    }
}

/// Full config on GET; a partial merge document on PUT (nil keys are omitted).
public struct ClipConfig: Codable, Sendable, Equatable {
    public var name: String?
    public var brightness: Int?
    public var uploadTimeoutS: Int?
    public var apPassword: String?
    public var lowBatteryPct: Int?
    public var defaultTransition: Transition?
    public var tzOffsetS: Int?
    /// PROTOCOL §3: the clip advertises the Bluetooth doorbell (default true).
    public var bleWake: Bool?
    /// PROTOCOL §3: the screen stays on (and `/show`, `/next`, `/brightness` are live) during an
    /// upload session (default true); false = the panel-off behaviour.
    public var displayDuringUpload: Bool?
    /// PROTOCOL §3: the access point stays up with no idle timeout (default false; ≈ halves wear time).
    public var wifiAlwaysOn: Bool?
    /// PROTOCOL §4 Orientation (default `auto`); nil on firmware that predates it.
    public var orientation: ClipOrientationMode?
    /// Read-only (`ap_password_set`): false while the clip still has the factory passphrase, true once
    /// another was set. Nil on firmware that predates it. Decoded from answers, never sent in a patch.
    public var apPasswordSet: Bool?

    enum CodingKeys: String, CodingKey {
        case name, brightness
        case uploadTimeoutS = "upload_timeout_s"
        case apPassword = "ap_password"
        case lowBatteryPct = "low_battery_pct"
        case defaultTransition = "default_transition"
        case tzOffsetS = "tz_offset_s"
        case bleWake = "ble_wake"
        case displayDuringUpload = "display_during_upload"
        case wifiAlwaysOn = "wifi_always_on"
        case orientation
        case apPasswordSet = "ap_password_set"
    }

    public init(name: String? = nil, brightness: Int? = nil, uploadTimeoutS: Int? = nil, apPassword: String? = nil,
                lowBatteryPct: Int? = nil, defaultTransition: Transition? = nil, tzOffsetS: Int? = nil,
                bleWake: Bool? = nil, displayDuringUpload: Bool? = nil, wifiAlwaysOn: Bool? = nil,
                orientation: ClipOrientationMode? = nil, apPasswordSet: Bool? = nil) {
        self.name = name; self.brightness = brightness; self.uploadTimeoutS = uploadTimeoutS
        self.apPassword = apPassword; self.lowBatteryPct = lowBatteryPct
        self.defaultTransition = defaultTransition; self.tzOffsetS = tzOffsetS
        self.bleWake = bleWake; self.displayDuringUpload = displayDuringUpload; self.wifiAlwaysOn = wifiAlwaysOn
        self.orientation = orientation; self.apPasswordSet = apPasswordSet
    }

    /// Encodes as a patch: every key but the read-only `ap_password_set`, which only an answer carries
    /// (an encoder whose `userInfo` has `ClipConfig.encodesAnswer` set to true, as the virtual clip's fast lane).
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(brightness, forKey: .brightness)
        try c.encodeIfPresent(uploadTimeoutS, forKey: .uploadTimeoutS)
        try c.encodeIfPresent(apPassword, forKey: .apPassword)
        try c.encodeIfPresent(lowBatteryPct, forKey: .lowBatteryPct)
        try c.encodeIfPresent(defaultTransition, forKey: .defaultTransition)
        try c.encodeIfPresent(tzOffsetS, forKey: .tzOffsetS)
        try c.encodeIfPresent(bleWake, forKey: .bleWake)
        try c.encodeIfPresent(displayDuringUpload, forKey: .displayDuringUpload)
        try c.encodeIfPresent(wifiAlwaysOn, forKey: .wifiAlwaysOn)
        try c.encodeIfPresent(orientation, forKey: .orientation)
        if encoder.userInfo[Self.encodesAnswer] as? Bool == true {
            try c.encodeIfPresent(apPasswordSet, forKey: .apPasswordSet)
        }
    }

    /// `userInfo` key: encode the config as the clip's answer (with its read-only fields).
    public static let encodesAnswer = CodingUserInfoKey(rawValue: "pixelclip.config.answer")!

    /// Device defaults from PROTOCOL §3–§4.
    public static let deviceDefaults = ClipConfig(name: "PixelClip", brightness: 160, uploadTimeoutS: 120,
                                                  apPassword: HotspotDefaults.password, lowBatteryPct: 8,
                                                  defaultTransition: .fade, tzOffsetS: 0,
                                                  bleWake: true, displayDuringUpload: true, wifiAlwaysOn: false,
                                                  orientation: .auto)

    /// The screen keeps playing during a session (true unless the clip reports the panel-off mode).
    public var screenStaysOn: Bool { displayDuringUpload != false }

    /// Firmware limits (422 `invalid_config` otherwise).
    public enum Limits {
        public static let nameBytes = 1...64
        public static let brightness = 0...255
        public static let uploadTimeoutS = 30...1800
        public static let apPasswordLength = 8...63
        public static let lowBatteryPct = 0...20   // the firmware's range (appcfg.c)
        public static let tzOffsetS = -50_400...50_400
    }

    /// Why this (partial) config would be rejected, or nil when valid.
    public var validationProblem: String? {
        if let name, !Limits.nameBytes.contains(name.utf8.count) { return "Name must be 1–64 bytes." }
        if let brightness, !Limits.brightness.contains(brightness) { return "Brightness is 0–255." }
        if let uploadTimeoutS, !Limits.uploadTimeoutS.contains(uploadTimeoutS) { return "Upload timeout is 30–1800 s." }
        if let apPassword {
            let printable = apPassword.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value <= 0x7E }
            if !Limits.apPasswordLength.contains(apPassword.utf8.count) || !printable {
                return "The hotspot password must be 8–63 printable ASCII characters."
            }
        }
        if let lowBatteryPct, !Limits.lowBatteryPct.contains(lowBatteryPct) { return "Low-battery level is 0–20 %." }
        if let tzOffsetS, !Limits.tzOffsetS.contains(tzOffsetS) { return "Time zone offset out of range." }
        return nil
    }

    /// Non-nil fields of `patch` override `self` (the PUT merge rule). `apPasswordSet` is the clip's
    /// own (read-only): a patch never changes it.
    public func merging(_ patch: ClipConfig) -> ClipConfig {
        ClipConfig(name: patch.name ?? name, brightness: patch.brightness ?? brightness,
                   uploadTimeoutS: patch.uploadTimeoutS ?? uploadTimeoutS, apPassword: patch.apPassword ?? apPassword,
                   lowBatteryPct: patch.lowBatteryPct ?? lowBatteryPct,
                   defaultTransition: patch.defaultTransition ?? defaultTransition, tzOffsetS: patch.tzOffsetS ?? tzOffsetS,
                   bleWake: patch.bleWake ?? bleWake, displayDuringUpload: patch.displayDuringUpload ?? displayDuringUpload,
                   wifiAlwaysOn: patch.wifiAlwaysOn ?? wifiAlwaysOn, orientation: patch.orientation ?? orientation,
                   apPasswordSet: apPasswordSet)
    }
}

// MARK: - Firmware update gate

/// `GET /ota`, `POST /ota/ask`: whether a firmware upload is allowed now (the clip's button was pressed
/// while it asked), whether the clip is asking ("Update? press the button"), and the seconds left in
/// the current window (asking or allowed). Firmware that predates the gate answers 404.
public struct OTAState: Codable, Sendable, Equatable {
    public var ok: Bool
    public var allowed: Bool
    public var asking: Bool
    public var secondsLeft: Int

    enum CodingKeys: String, CodingKey {
        case ok, allowed, asking
        case secondsLeft = "seconds_left"
    }

    public init(allowed: Bool, asking: Bool, secondsLeft: Int) {
        ok = true; self.allowed = allowed; self.asking = asking; self.secondsLeft = secondsLeft
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = try c.decodeIfPresent(Bool.self, forKey: .ok) ?? true
        allowed = try c.decodeIfPresent(Bool.self, forKey: .allowed) ?? false
        asking = try c.decodeIfPresent(Bool.self, forKey: .asking) ?? false
        secondsLeft = try c.decodeIfPresent(Int.self, forKey: .secondsLeft) ?? 0
    }
}

/// `GET /config` returns the config object; firmware may or may not add `"ok":true`, which we ignore.
public typealias ConfigResponse = ClipConfig

// MARK: - Small bodies

public struct TimeSync: Codable, Sendable, Equatable {
    public var epoch: Int
    public var tzOffsetS: Int
    enum CodingKeys: String, CodingKey {
        case epoch
        case tzOffsetS = "tz_offset_s"
    }
    public init(epoch: Int, tzOffsetS: Int) { self.epoch = epoch; self.tzOffsetS = tzOffsetS }

    public static func now(_ date: Date = Date(), timeZone: TimeZone = .current) -> TimeSync {
        TimeSync(epoch: Int(date.timeIntervalSince1970), tzOffsetS: timeZone.secondsFromGMT(for: date))
    }
}

public struct BrightnessRequest: Codable, Sendable, Equatable {
    public var value: Int
    public init(value: Int) { self.value = value }
}

/// `POST /show/{id}`: `{"duration_ms":<optional>,"scroll":<optional, as on playlist items>}`. Without
/// `scroll` the firmware uses the playlist item's scroll for that asset if it has one, else defaults.
public struct ShowRequest: Codable, Sendable, Equatable {
    public var durationMs: Int?
    public var scroll: PlaylistItem.Scroll?
    enum CodingKeys: String, CodingKey { case durationMs = "duration_ms", scroll }
    public init(durationMs: Int? = nil, scroll: PlaylistItem.Scroll? = nil) { self.durationMs = durationMs; self.scroll = scroll }
}

public struct OKResponse: Codable, Sendable, Equatable {
    public var ok: Bool
    public init(ok: Bool = true) { self.ok = ok }
}

/// `{"ok":false,"error":"<code>","message":"<human>"}`.
public struct ErrorEnvelope: Codable, Sendable, Equatable, Error {
    public var ok: Bool
    public var error: String
    public var message: String
    public init(error: String, message: String) { ok = false; self.error = error; self.message = message }
}

// MARK: - JSON helpers

public enum ClipJSON {
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }
    /// For the clip's own answers (the virtual clip): read-only fields such as `ap_password_set` included.
    public static func answerEncoder() -> JSONEncoder {
        let e = encoder()
        e.userInfo[ClipConfig.encodesAnswer] = true
        return e
    }
    public static func decoder() -> JSONDecoder { JSONDecoder() }
}

/// PROTOCOL §5b.1: the `words` live scene.
public enum WordsScene {
    public static let name = "words"
    public static let defaultBounce = 60
    public static var params: [String: SceneParam] { ["bounce": .number(Double(defaultBounce))] }
    /// A sheet: 1…12 frames, all `w × h` (w ≤ 536, h ≤ 240, N·w·h ≤ 514 560).
    public static let maxFrames = 12
    public static let maxPixels = 514_560

    /// Whether a stored asset can be a sheet.
    public static func isValidSheet(width: Int, height: Int, frames: Int) -> Bool {
        (1...maxFrames).contains(frames) && (1...ClipCanvas.width).contains(width) && (1...ClipCanvas.height).contains(height)
            && frames * width * height <= maxPixels
    }
}
