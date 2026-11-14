import Foundation

/// Per-word timing, exactly as PROTOCOL §5c and `core/src/rsvp_tok.c` define it:
/// `60000/wpm ms × factor`, factor (in tenths) = 10, 13 for ≥ 8 glyphs, 16 for ≥ 12, plus 10 at a
/// sentence end or else 5 after a comma/semicolon/dash (the bonuses add: ×1.6 + 100 % = ×2.6),
/// rounded to the nearest ms; a 300 ms blank after a word that ends a paragraph.
public enum RSVPTiming {
    public static let wpmRange = 50...1500
    public static let defaultWPM = 300
    /// The app's slider.
    public static let appWPMRange = 150...700
    public static let paragraphBlankMs = 300
    /// The "fin" card at the end of a text.
    public static let endCardMs = 3000

    public static func clampWPM(_ wpm: Int) -> Int { min(max(wpm, wpmRange.lowerBound), wpmRange.upperBound) }

    /// `rsvp_word_factor_x10`.
    public static func factorX10(_ w: RSVPWord) -> Int {
        let len = w.length
        var f = len >= 12 ? 16 : len >= 8 ? 13 : 10
        if w.flags.contains(.sentence) { f += 10 } else if w.flags.contains(.comma) { f += 5 }
        return f
    }

    /// On-screen time of the word (`rsvp_word_ms`).
    public static func wordMs(_ w: RSVPWord, wpm: Int) -> Int {
        let v = clampWPM(wpm)
        return (60_000 * factorX10(w) + v * 5) / (v * 10)
    }

    /// Blank after the word (`rsvp_blank_ms`).
    public static func blankMs(_ w: RSVPWord) -> Int { w.flags.contains(.paragraph) ? paragraphBlankMs : 0 }

    /// Word plus its blank.
    public static func slotMs(_ w: RSVPWord, wpm: Int) -> Int { wordMs(w, wpm: wpm) + blankMs(w) }

    /// Whole-text estimate (`rsvp_total_ms`): from the summed factors, as the clip computes it.
    public static func totalMs<S: Sequence>(_ words: S, wpm: Int) -> Int where S.Element == RSVPWord {
        var factor = 0, paragraphs = 0
        for w in words {
            factor += factorX10(w)
            if w.flags.contains(.paragraph) { paragraphs += 1 }
        }
        let v = clampWPM(wpm)
        return (factor * 6000 + v / 2) / v + paragraphs * paragraphBlankMs
    }

    /// Rounded minutes, at least 1 (`rsvp_minutes`).
    public static func minutes(totalMs: Int) -> Int { max(1, (totalMs + 30_000) / 60_000) }

    /// "1 234 words · 4 min" (`rsvp_end_card_text`).
    public static func endCardText(words: Int, minutes: Int) -> String {
        let digits = Array(String(words))
        var num = ""
        for (i, d) in digits.enumerated() {
            if i > 0 && (digits.count - i) % 3 == 0 { num.append(" ") }
            num.append(d)
        }
        return "\(num) word\(words == 1 ? "" : "s") \u{00B7} \(minutes) min"
    }
}

/// When each word of a text appears at a given speed: the clip's reading clock, used by the virtual
/// clip and the app's live preview.
public struct RSVPSchedule: Sendable {
    public let wpm: Int
    /// `starts[i]` = ms from word 0 to word i; `starts[count]` = the whole text.
    public let starts: [Int]
    /// How long word i is visible (its blank follows).
    public let visible: [Int]

    public init(words: [RSVPWord], wpm: Int) {
        self.wpm = RSVPTiming.clampWPM(wpm)
        var s = [Int](repeating: 0, count: words.count + 1)
        var v = [Int](repeating: 0, count: words.count)
        var t = 0
        for (i, w) in words.enumerated() {
            s[i] = t
            v[i] = RSVPTiming.wordMs(w, wpm: self.wpm)
            t += v[i] + RSVPTiming.blankMs(w)
        }
        s[words.count] = t
        starts = s
        visible = v
    }

    public var count: Int { visible.count }
    public var totalMs: Int { starts.last ?? 0 }

    /// Time from word `from` to the end of the text.
    public func remainingMs(from: Int) -> Int {
        let f = min(max(from, 0), count)
        return totalMs - starts[f]
    }

    public enum Position: Sendable, Equatable {
        /// Word `index` (with `blank` = in the paragraph pause after it).
        case word(Int, blank: Bool)
        /// Past the last word.
        case end
    }

    /// Where the reading is `elapsedMs` after starting at word `from`.
    public func position(from: Int, elapsedMs: Int) -> Position {
        let f = min(max(from, 0), count)
        guard f < count else { return .end }
        let target = starts[f] + max(0, elapsedMs)
        guard target < totalMs else { return .end }
        // Last start ≤ target.
        var lo = f, hi = count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= target { lo = mid } else { hi = mid - 1 }
        }
        return .word(lo, blank: target - starts[lo] >= visible[lo])
    }

    /// Elapsed ms at which word `index` appears when starting at `from`.
    public func elapsed(from: Int, to index: Int) -> Int {
        let f = min(max(from, 0), count), i = min(max(index, 0), count)
        return max(0, starts[i] - starts[f])
    }
}
