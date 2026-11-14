import Foundation

/// How the app talks about the clip's battery, in one place: the glyph's level and tint, when to
/// suggest charging, and a rough wear-time estimate. Percentages are the firmware's, already
/// rescaled so 0 % is the 3.40 V deep-sleep cutoff (HARDWARE.md §8), so "low" here is a real
/// margin above the clip putting itself to sleep.
public struct BatteryReading: Sendable, Equatable {
    public enum Level: Sendable, Equatable {
        /// 20 % and up (or on USB).
        case normal
        /// Under 20 %: orange, "charge soon".
        case low
        /// Under 10 %, or close to the 3.5 V Wi‑Fi cutoff: red.
        case critical
    }

    public var pct: Int?
    public var mv: Int?
    /// USB power present (charging or full).
    public var onUSB: Bool

    /// Below this the glyph turns orange and the Clip tab suggests charging.
    public static let lowPct = 20
    /// Below this the glyph turns red.
    public static let criticalPct = 10
    /// Wear time from full, always on (measured: ≈ 5–5.5 h on the 500 mAh cell).
    public static let fullWearHours = 5.0

    public init(pct: Int?, mv: Int? = nil, onUSB: Bool = false) {
        self.pct = pct.map { min(max($0, 0), 100) }
        self.mv = mv
        self.onUSB = onUSB
    }

    public init(_ battery: ClipStatus.Battery?) {
        self.init(pct: battery?.pct, mv: battery?.mv, onUSB: battery?.usbPresent == true || battery?.charging == true)
    }

    public var level: Level {
        if onUSB { return .normal }
        if let mv, mv < ClipStatus.Battery.uploadCutoffMv + 80 { return .critical }
        guard let pct else { return .normal }
        if pct < Self.criticalPct { return .critical }
        if pct < Self.lowPct { return .low }
        return .normal
    }

    /// SF Symbol for the glyph: the level in quarters, a bolt on USB.
    public var symbolName: String {
        if onUSB { return "battery.100percent.bolt" }
        guard let pct else { return "battery.0percent" }
        switch pct {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    /// Show the gentle "charge soon" banner.
    public var suggestsCharging: Bool { level != .normal }

    /// Rough minutes of wear left (nil on USB or without a percentage), rounded to 10 min.
    public var wearMinutesLeft: Int? {
        guard !onUSB, let pct else { return nil }
        let m = Double(pct) / 100 * Self.fullWearHours * 60
        return max(0, Int((m / 10).rounded()) * 10)
    }

    /// "about 40 min", "about 1 h 30 min".
    public var wearLeftText: String? {
        guard let m = wearMinutesLeft else { return nil }
        if m < 10 { return "only a few minutes" }
        if m < 60 { return "about \(m) min" }
        let h = m / 60, r = m % 60
        return r == 0 ? "about \(h) h" : "about \(h) h \(r) min"
    }

    /// VoiceOver: "Battery 18 percent, low", "Battery 64 percent, charging".
    public var accessibilityText: String {
        guard let pct else { return onUSB ? "Battery charging" : "Battery unknown" }
        var s = "Battery \(pct) percent"
        if onUSB { s += ", charging" } else if level == .critical { s += ", very low" } else if level == .low { s += ", low" }
        return s
    }
}

/// Size rules for what the app sends.
public enum ClipBudget {
    /// The largest frame-based animation the app makes or imports until the firmware pans stills
    /// on-device: every frame is stored whole, so a long, smooth pan of a detailed picture runs to
    /// tens of megabytes. Strips (one wide frame the clip scrolls itself) aren't limited by this.
    public static let maxAnimationBytes = 4_000_000

    /// True when a frame-based asset of `bytes` is over the limit (stills and strips never are).
    public static func isOverLimit(bytes: Int, frames: Int, isStrip: Bool = false) -> Bool {
        frames > 1 && !isStrip && bytes > maxAnimationBytes
    }
}
