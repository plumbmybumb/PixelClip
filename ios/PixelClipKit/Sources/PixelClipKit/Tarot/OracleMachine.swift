import Foundation

/// What the screen shows at one moment, as a composition of the item's assets (PROTOCOL §5f
/// "Composed frames"); `OracleCompositor` turns it into pixels.
public enum OracleView: Sendable, Equatable, CustomStringConvertible {
    /// `T[0]` with the back in the slot.
    case waits
    /// §5f.8: the back in the slot with `[prompt.armed]` (else the prompt).
    case armed
    /// The single shuffle: `T[0]` with card `i` in the slot.
    case shuffleOne(Int)
    /// `T[Q(i)]` with card i in the slot.
    case question(Int)
    /// The three-card shuffle: cards in the three slots, no keys yet.
    case shuffleThree([Int])
    /// Cards A, B, C side by side with their keywords.
    case three([Int])
    /// §5f.9: the three again at the end (hold): drawn as `three`, with the "end" hint.
    case hold([Int])
    /// `T[R(i, p)]` with card i in the slot.
    case reading(card: Int, page: Int)
    /// The three number notes, stacked.
    case thread([Int])
    /// `T[F(i)]` with card i in the slot (day mode).
    case face(Int)
    /// §5f.7: a lean screen's text (by card, by position, by the numbers, together, and), one page, full width.
    case lean(String)
    /// §5f.7: card `card`'s one-page detail (`card.<i>.brief`), the card in the slot.
    case detail(card: Int, text: String)

    public var description: String {
        switch self {
        case .waits: "waits"
        case .armed: "armed"
        case .shuffleOne(let i): "shuffle\(i)"
        case .question(let i): "question\(i)"
        case .shuffleThree(let c): "shuffle\(c.map(String.init).joined(separator: ","))"
        case .three(let c): "three\(c.map(String.init).joined(separator: ","))"
        case .hold(let c): "hold\(c.map(String.init).joined(separator: ","))"
        case .reading(let i, let p): "reading\(i).\(p)"
        case .thread(let c): "thread\(c.map(String.init).joined(separator: ","))"
        case .face(let i): "face\(i)"
        case .lean(let text): "lean\(Oracle.fnv1a(text.utf8))"
        case .detail(let i, let text): "detail\(i).\(Oracle.fnv1a(text.utf8))"
        }
    }
}

/// The clip's oracle state machine (PROTOCOL §5f, paged by hand §5f.3, one reading only §5f.6, the lean draw
/// §5f.7), as a value type driven by time: the virtual clip and the app's preview run it as the firmware does.
///
/// **Screens, in order** (at most 11, every one a page): waits → **armed** → (shuffle) → **three** → **lean**
/// 0 · 1 · 2 · 3 · 4 (by card, by position, by the numbers, together, and) → **detail** A · B · C (`card.<i>.brief`) →
/// the three again (**hold**). A lean screen with no text and a card without a brief are skipped. A tap (`turn`,
/// `POST /oracle/turn`) is the next screen (on waits: arm; on armed: deal; on hold: waits); a double-tap (`back`,
/// `POST /oracle/back`) the previous one (nothing on waits; armed → waits). §5f.8: a shake deals **only on armed**
/// (ignored on waits and from the shuffle through the hold); `POST /oracle/draw` deals from anywhere (the person
/// at the phone chose it). Taps during the shuffle do nothing.
///
/// **No timers** by default: `faceMs` (three) and `pageMs` (lean, detail) at 0 never advance by themselves. `holdMs`
/// is the **idle timeout**: no tap, back or shake for `holdMs` (default 5 min; 0 = never) and the clip returns to
/// waits from any screen. The shuffle lasts 1.2 s.
///
/// **Which cards**: random, A, B, C all different, and never the previous draw's three as a set; a forced row
/// (`POST /oracle/draw {"cards":[a,b,c]}`) wins. A shake counts when the metric reaches `shakeG`; it must fall below
/// `shakeG`/2 before another one does. The full paragraph (§5f.1) is still composed: `/status.oracle.reading` carries
/// it on the three and the hold.
public struct OracleMachine: Sendable {
    public let cards: Int
    public let faceMs: Int
    public let pageMs: Int
    public let holdMs: Int
    public let shakeG: Double
    /// The item's phrase bundle (nil: no lean screens, no details, no paragraph).
    public let reader: SentenceReader?
    /// "Fits one page" for the "and" screen (the virtual clip asks the body font; nil: ≤ 150 code points).
    public let fits: (@Sendable (String) -> Bool)?

    enum Step: Sendable, Equatable {
        case waits, armed, shuffle, three, lean(Int), detail(Int), hold
    }

    private(set) var step: Step = .waits
    private var stepStart = Date.distantPast
    /// The last tap, back or draw (the idle timeout counts from it).
    private var lastInput = Date.distantPast
    /// When the machine last came back to waits (the end of a draw: the clip's deferred rotation, queue and
    /// sprinkles fire from then, §5f.8).
    public private(set) var waitsSince = Date.distantPast
    private var seed: UInt32 = 1
    /// The three cards of the current draw.
    public private(set) var three: [Int] = []
    /// The previous draw's three (the next one is never the same set).
    public private(set) var lastThree: [Int] = []
    /// Every row drawn, in order (tests, debug).
    public private(set) var drawn: [[Int]] = []
    /// The full paragraph of the current draw (§5f.1; the phone shows it).
    public private(set) var paragraph: String?
    /// The five lean screens of this draw (§5f.7).
    public private(set) var leanTexts: [String] = []
    /// The three cards' details (`card.<i>.brief`, nil when absent).
    public private(set) var briefs: [String?] = []
    /// The screens after the three, in order, ending with the hold (built when the three show).
    private var sequence: [Step] = []
    private var armed = true
    private var rng: Xorshift32

    public init(cards: Int, faceMs: Int = Oracle.defaultFaceMs, pageMs: Int = Oracle.defaultPageMs,
                holdMs: Int = Oracle.defaultHoldMs, shakeG: Double = Oracle.defaultShakeG, seed: UInt32? = nil,
                reader: SentenceReader? = nil, fits: (@Sendable (String) -> Bool)? = nil) {
        self.cards = max(1, cards)
        self.faceMs = max(0, faceMs)
        self.pageMs = max(0, pageMs)
        self.holdMs = max(0, holdMs)
        self.shakeG = shakeG
        self.reader = reader
        self.fits = fits
        rng = Xorshift32(seed: seed ?? UInt32.random(in: 1...UInt32.max))
    }

    public init(item: OracleItem, seed: UInt32? = nil, reader: SentenceReader? = nil, fits: (@Sendable (String) -> Bool)? = nil) {
        self.init(cards: item.cards, faceMs: item.faceMs, pageMs: item.pageMs, holdMs: item.holdMs, shakeG: item.shakeG,
                  seed: seed, reader: item.hasReader ? reader : nil, fits: fits)
    }

    // MARK: Input

    /// One reading of the shake metric (g, decaying peak) at `t`.
    public mutating func sample(_ metric: Double, at t: Date) {
        advance(to: t)
        if metric >= shakeG {
            // §5f.8: a shake deals only on armed; elsewhere it is ignored (and still spent).
            if armed { armed = false; if step == .armed { draw(at: t) } }
        } else if metric < shakeG / 2 {
            armed = true
        }
    }

    /// Is `cards` a row the clip takes (three distinct cards in the deck)?
    public func isRow(_ row: [Int]) -> Bool { row.count == 3 && Set(row).count == 3 && row.allSatisfy { (0..<cards).contains($0) } }

    /// A draw now (a shake or a tap on armed, or `POST /oracle/draw`); `forced` (three distinct cards) forces the row.
    public mutating func draw(at t: Date, cards forced: [Int]? = nil) {
        advance(to: t)
        three = forced.flatMap { isRow($0) ? $0 : nil } ?? pickThree()
        lastThree = three
        drawn.append(three)
        paragraph = nil
        leanTexts = []
        briefs = []
        sequence = []
        lastInput = t
        go(.shuffle, at: t)
        seed = rng.next()
    }

    /// A tap of BOOT, or `POST /oracle/turn`: the next screen (waits → armed; armed → a draw; hold → waits; ignored
    /// during the shuffle).
    public mutating func turn(at t: Date) {
        advance(to: t)
        switch step {
        case .waits: lastInput = t; go(.armed, at: t)
        case .armed: draw(at: t)
        case .shuffle: break
        default: lastInput = t; next(at: t)
        }
    }

    /// A double-tap of BOOT (`POST /oracle/back`): the previous screen (nothing on waits or during the shuffle;
    /// armed and the three go back to waits).
    public mutating func back(at t: Date) {
        advance(to: t)
        switch step {
        case .waits, .shuffle: return
        case .armed, .three: lastInput = t; go(.waits, at: t)
        default:
            lastInput = t
            guard let i = sequence.firstIndex(of: step) else { return }
            go(i > 0 ? sequence[i - 1] : .three, at: t)
        }
    }

    private mutating func go(_ s: Step, at t: Date) {
        if s == .three { buildSequence() }
        if s == .waits && step != .waits { waitsSince = t }
        step = s
        stepStart = t
    }

    /// The step after the current one (what its timer or a tap leads to).
    private mutating func next(at t: Date) {
        switch step {
        case .waits: go(.armed, at: t)
        case .armed: draw(at: t)
        case .shuffle: go(.three, at: t)
        case .three: go(sequence.first ?? .hold, at: t)
        case .hold: go(.waits, at: t)
        default:
            guard let i = sequence.firstIndex(of: step), i + 1 < sequence.count else { go(.hold, at: t); return }
            go(sequence[i + 1], at: t)
        }
    }

    /// The screens after the three: the lean screens with text, the cards with a brief, the hold.
    private mutating func buildSequence() {
        guard three.count == 3 else { sequence = [.hold]; return }
        if leanTexts.isEmpty, let r = reader {
            let fits = self.fits
            leanTexts = r.composeLean(a: three[0], b: three[1], c: three[2], fits: fits.map { f in { f($0) } }) ?? []
            briefs = three.map { r.field($0, .brief) }
            paragraph = r.compose(a: three[0], b: three[1], c: three[2])?.text
        }
        var seq: [Step] = leanTexts.indices.filter { !leanTexts[$0].isEmpty }.map { .lean($0) }
        seq += briefs.indices.filter { briefs[$0].map { !$0.isEmpty } ?? false }.map { .detail($0) }
        seq.append(.hold)
        sequence = seq
    }

    // MARK: Time

    /// How long the current step lasts by itself (nil: until a tap).
    private var dwellMs: Int? {
        switch step {
        case .waits, .armed, .hold: nil
        case .shuffle: Oracle.shuffleMs
        case .three: faceMs > 0 ? faceMs : nil
        case .lean, .detail: pageMs > 0 ? pageMs : nil
        }
    }

    /// Runs every transition due by `t`: the timed steps, and the idle timeout back to waits.
    public mutating func advance(to t: Date) {
        while step != .waits {
            let timed = dwellMs.map { stepStart.addingTimeInterval(Double($0) / 1000) }
            let idle = holdMs > 0 ? lastInput.addingTimeInterval(Double(holdMs) / 1000) : nil
            if let idle, t >= idle, timed.map({ idle <= $0 }) ?? true {
                go(.waits, at: idle)
                return
            }
            guard let timed, t >= timed else { return }
            next(at: timed)
        }
    }

    /// Three distinct random cards, never the previous draw's three as a set (a deck too small repeats what it must).
    private mutating func pickThree() -> [Int] {
        guard cards >= 3 else { return Array(0..<cards) + Array(repeating: 0, count: 3 - cards) }
        for _ in 0..<64 {
            var pool = Array(0..<cards)
            var out: [Int] = []
            for _ in 0..<3 { out.append(pool.remove(at: Int(rng.next() % UInt32(pool.count)))) }
            if Set(out) != Set(lastThree) || cards == 3 { return out }
        }
        return Array(0..<3)
    }

    // MARK: Output

    public var state: OracleState {
        switch step {
        case .waits: .waits
        case .armed: .armed
        case .shuffle: .shuffle
        case .three: .three
        case .lean: .lean
        case .detail: .detail
        case .hold: .hold
        }
    }

    /// `/status.oracle.cards_drawn`: A, B, C once they show, −1 each otherwise.
    public var cardsDrawn: [Int] {
        switch step {
        case .waits, .armed, .shuffle: return [-1, -1, -1]
        default: return three.count == 3 ? three : [-1, -1, -1]
        }
    }

    /// `/status.oracle.card`: the detail's card, −1 otherwise.
    public var card: Int {
        if case .detail(let k) = step, three.indices.contains(k) { return three[k] }
        return -1
    }

    /// `/status.oracle.reading`: the screen's text on a lean or detail screen, the whole paragraph on the three and
    /// the hold, nil otherwise.
    public var reading: String? {
        switch step {
        case .lean(let k): return leanTexts.indices.contains(k) ? leanTexts[k] : nil
        case .detail(let k): return briefs.indices.contains(k) ? briefs[k] : nil
        case .three, .hold: return paragraph
        default: return nil
        }
    }

    /// `/status.oracle.page`: the lean screen (0–4) or the detail (0–2), −1 otherwise.
    public var page: Int {
        switch step {
        case .lean(let k), .detail(let k): return k
        default: return -1
        }
    }

    public func status(at t: Date) -> ClipStatus.OracleStatus {
        .init(cards: cards, state: state, cardsDrawn: cardsDrawn, card: card, page: page, reading: reading)
    }

    /// The screen at `t` (call `advance(to:)` first). The shuffle is quantised to its 12 fps.
    public func view(at t: Date) -> OracleView {
        let tick = Int((max(0, t.timeIntervalSince(stepStart)) * Double(Oracle.shuffleFps)).rounded(.down))
        switch step {
        case .waits: return .waits
        case .armed: return .armed
        case .shuffle:
            return .shuffleThree(three.enumerated().map { k, c in
                Self.shuffleCard(tick: tick, chosen: c, cards: cards, seed: seed &+ UInt32(k + 1) &* 0x9E37_79B9)
            })
        case .three: return .three(three)
        case .hold: return .hold(three)
        case .lean(let k): return .lean(leanTexts.indices.contains(k) ? leanTexts[k] : "")
        case .detail(let k): return .detail(card: three[k], text: briefs[k] ?? "")
        }
    }

    /// Ticks of a shuffle (the last one, 1.08–1.2 s, shows the chosen card).
    static var shuffleTicks: Int { Oracle.shuffleMs * Oracle.shuffleFps / 1000 }

    /// The card shown at shuffle tick `tick`: pseudo-random, never the same twice running nor the chosen
    /// card before it lands; the chosen card from the last tick on.
    static func shuffleCard(tick: Int, chosen: Int, cards: Int, seed: UInt32) -> Int {
        guard cards > 1, tick < shuffleTicks - 1 else { return chosen }
        var rng = Xorshift32(seed: seed)
        var prev = -1
        var out = chosen
        for _ in 0...tick {
            var k = Int(rng.next() % UInt32(cards))
            if cards >= 3 {
                var guardN = 0
                while (k == prev || k == chosen) && guardN < 8 { k = (k + 1) % cards; guardN += 1 }
            } else if k == prev {
                k = (k + 1) % cards
            }
            prev = k
            out = k
        }
        return out
    }
}

/// Composes the panel frame from the item's decoded assets (PROTOCOL §5f "Composed frames").
public enum OracleCompositor {
    public struct Assets: Sendable {
        public var deck: [RGB565Frame]
        /// The app's own rendered text frames (`TarotRenderer`, its previews and the library poster); empty on
        /// the clip since §5f.2, which writes the text screens from `bundle` with `font` / `fontBig`.
        public var text: [RGB565Frame]
        public var keys: [RGB565Frame]
        public var notes: [RGB565Frame]
        /// Reading pages per card in `text`.
        public var pages: Int
        /// §5f.1/§5f.2: the body font (the text screens and the typed paragraph; nil: black where it would write).
        public var font: ReaderBoundFont?
        /// §5f.2: the phrase bundle the text screens come from, and the numeral's font.
        public var bundle: SentenceReader?
        public var fontBig: ReaderBoundFont?
        /// §5f.9: the panel is flipped (the button hints go to the left edge).
        public var flipped: Bool
        public init(deck: [RGB565Frame], text: [RGB565Frame] = [], keys: [RGB565Frame], notes: [RGB565Frame], pages: Int = 2,
                    font: ReaderBoundFont? = nil, bundle: SentenceReader? = nil, fontBig: ReaderBoundFont? = nil, flipped: Bool = false) {
            self.deck = deck; self.text = text; self.keys = keys; self.notes = notes; self.pages = pages; self.font = font
            self.bundle = bundle; self.fontBig = fontBig; self.flipped = flipped
        }

        /// The clip's way (§5f.2): text screens from the bundle.
        public var writesText: Bool { bundle != nil && font != nil }
    }

    /// The screen with its button hints (§5f.9) when the text is written from the bundle.
    public static func frame(_ view: OracleView, _ a: Assets) -> RGB565Frame {
        guard a.writesText, let b = a.bundle, let font = a.font, let f = written(view, a, bundle: b, font: font) else { return screen(view, a) }
        return f
    }

    /// §5f.11/§5f.12 as the clip draws it: the cards (108×206) — the three at y 0, x 52, 214, 376 with their keywords at
    /// y 206, the back or the detail's card at y 17, x 8 / 420 — the text in its box in the largest face that fits, and
    /// one ▶ in the BOOT corner (every screen but the shuffle). Nil for the views the clip no longer has.
    static func written(_ view: OracleView, _ a: Assets, bundle b: SentenceReader, font: ReaderBoundFont) -> RGB565Frame? {
        var out = RGB565Frame(width: ClipCanvas.width, height: ClipCanvas.height)
        let flip = a.flipped
        func card(_ i: Int) -> RGB565Frame? { a.deck.indices.contains(1 + i) ? a.deck[1 + i] : nil }
        func single(_ c: RGB565Frame?) { if let c { paste(c, into: &out, x: Oracle.singleCardX(flipped: flip), y: Oracle.singleCardY) } }
        func three(_ cs: [Int], keys: Bool) {
            for (k, c) in cs.prefix(3).enumerated() {
                if let f = card(c) { paste(f, into: &out, x: Oracle.threeCardX[k], y: Oracle.threeCardY) }
                // §5f.12: the keyword row under the three (when the item has its keys).
                if keys, a.keys.indices.contains(c) { paste(a.keys[c], into: &out, x: Oracle.threeKeyX[k], y: Oracle.threeKeyY) }
            }
        }
        func paint(_ l: OracleScreens.Laid) {
            out = OracleScreens.paint(l.screen, body: l.face, big: a.fontBig?.normal, onto: out)
        }
        switch view {
        case .waits:
            single(a.deck.first)
            paint(OracleScreens.waits(b, font: font, flipped: flip))
        case .armed:
            single(a.deck.first)
            paint(OracleScreens.armed(b, font: font, flipped: flip))
        case .shuffleThree(let cs): three(cs, keys: false)
        case .three(let cs), .hold(let cs): three(cs, keys: true)
        case .lean(let text): paint(OracleScreens.lean(text, font: font, flipped: flip))
        case .detail(let i, let text):
            let d = OracleScreens.detail(text, font: font, flipped: flip)
            if d.card { single(card(i)) }
            paint(d.laid)
        default:
            return nil
        }
        if OracleScreens.hasHint(view) { OracleScreens.paintHint(flipped: flip, into: &out.pixels) }
        return out
    }

    static func screen(_ view: OracleView, _ a: Assets) -> RGB565Frame {
        let black = RGB565Frame(width: ClipCanvas.width, height: ClipCanvas.height)
        func text(_ i: Int) -> RGB565Frame { a.text.indices.contains(i) ? a.text[i] : black }
        func card(_ i: Int) -> RGB565Frame? { a.deck.indices.contains(1 + i) ? a.deck[1 + i] : nil }
        func slotted(_ base: RGB565Frame, _ c: RGB565Frame?) -> RGB565Frame {
            var out = base
            if let c { paste(c, into: &out, x: Oracle.slot.x, y: Oracle.slot.y) }
            return out
        }
        func threeUp(_ cs: [Int], keys: Bool) -> RGB565Frame {
            var out = black
            for (k, c) in cs.prefix(3).enumerated() {
                if let f = card(c) { paste(f, into: &out, x: Oracle.threeCardX[k], y: Oracle.threeCardY) }
                if keys, a.keys.indices.contains(c) { paste(a.keys[c], into: &out, x: Oracle.threeKeyX[k], y: Oracle.threeKeyY) }
            }
            return out
        }
        // §5f.2: the text screens written from the bundle with the glyph atlases.
        func written(_ s: (SentenceReader, ReaderBoundFont.Face) -> OracleScreens.Screen) -> RGB565Frame {
            guard let b = a.bundle, let f = a.font else { return black }
            return OracleScreens.paint(s(b, f.normal), body: f.normal, big: a.fontBig?.normal, onto: black)
        }
        if a.writesText {
            switch view {
            case .reading(let i, let p): return slotted(written { OracleScreens.reading(i, page: p, $0, body: $1) }, card(i))
            default: break
            }
        }
        switch view {
        case .waits, .armed: return slotted(text(Oracle.waitsFrame), a.deck.first)
        case .shuffleOne(let i): return slotted(text(Oracle.waitsFrame), card(i))
        case .question(let i): return slotted(text(Oracle.question(i, pages: a.pages)), card(i))
        case .shuffleThree(let cs): return threeUp(cs, keys: false)
        case .three(let cs), .hold(let cs): return threeUp(cs, keys: true)
        case .reading(let i, let p): return slotted(text(Oracle.reading(i, p, pages: a.pages)), card(i))
        case .face(let i): return slotted(text(Oracle.face(i, pages: a.pages)), card(i))
        case .thread(let cs):
            var out = black
            for (k, c) in cs.prefix(3).enumerated() where a.notes.indices.contains(c) {
                paste(a.notes[c], into: &out, x: 0, y: Oracle.threadY[k])
            }
            return out
        case .lean(let text), .detail(_, let text):
            // Without a bundle (the app's old previews): full width in the body font.
            guard let font = a.font else { return black }
            let l = OracleScreens.lean(text, font: font)
            return OracleScreens.paint(l.screen, body: l.face, big: nil, onto: black)
        }
    }

    /// Copies `src` into `dst` at (x, y), clipped.
    public static func paste(_ src: RGB565Frame, into dst: inout RGB565Frame, x: Int, y: Int) {
        let x0 = max(0, x), x1 = min(dst.width, x + src.width)
        guard x0 < x1 else { return }
        for row in 0..<src.height {
            let dy = y + row
            guard dy >= 0, dy < dst.height else { continue }
            let s = row * src.width + (x0 - x)
            let d = dy * dst.width + x0
            dst.pixels.replaceSubrange(d..<(d + x1 - x0), with: src.pixels[s..<(s + x1 - x0)])
        }
    }
}

/// xorshift32, the oracle's card picker (the firmware seeds its own from boot entropy).
struct Xorshift32: Sendable {
    private var state: UInt32
    init(seed: UInt32) { state = seed == 0 ? 0x9E37_79B9 : seed }
    mutating func next() -> UInt32 {
        state ^= state << 13
        state ^= state >> 17
        state ^= state << 5
        return state
    }
}

