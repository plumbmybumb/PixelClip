import Foundation

/// Local time as the clip sees it: a fixed UTC offset (`tz_offset_s`), no DST rules. Windows
/// (`from`/`until`) are evaluated against this, exactly like `sched_window_contains` in the firmware:
/// `minute = ((now + tz) mod 86400) / 60`.
public struct ClipLocalTime: Sendable, Equatable, Hashable {
    public var tzOffsetS: Int

    public init(tzOffsetS: Int) { self.tzOffsetS = tzOffsetS }

    /// The phone's zone frozen at `date` (what `POST /time` would send).
    public init(timeZone: TimeZone, at date: Date = Date()) { tzOffsetS = timeZone.secondsFromGMT(for: date) }

    public var timeZone: TimeZone { TimeZone(secondsFromGMT: tzOffsetS) ?? .gmt }

    private func localSeconds(_ date: Date) -> Int {
        Int(date.timeIntervalSince1970.rounded(.down)) + tzOffsetS
    }

    /// 0…1439, firmware rule.
    public func minuteOfDay(_ date: Date) -> Int {
        let s = localSeconds(date)
        return ((s % 86_400) + 86_400) % 86_400 / 60
    }

    public func hour(_ date: Date) -> Int { minuteOfDay(date) / 60 }

    /// Floor to the start of the local hour.
    public func startOfHour(_ date: Date) -> Date {
        let s = localSeconds(date)
        let floored = s - (((s % 3600) + 3600) % 3600)
        return Date(timeIntervalSince1970: TimeInterval(floored - tzOffsetS))
    }

    /// Local midnight that starts the day containing `date`.
    public func startOfDay(_ date: Date) -> Date {
        let s = localSeconds(date)
        let floored = s - (((s % 86_400) + 86_400) % 86_400)
        return Date(timeIntervalSince1970: TimeInterval(floored - tzOffsetS))
    }

    /// The occurrence of `time` nearest after `reference − lookBackS`: today's if it isn't more than
    /// `lookBackS` in the past, else tomorrow's. (A time picked a few minutes ago resolves to the past,
    /// so the planner can say "that time has passed" instead of silently meaning tomorrow.)
    public func date(for time: TimeOfDay, near reference: Date, lookBackS: Int = 3600) -> Date {
        var d = startOfDay(reference).addingTimeInterval(TimeInterval(time.minutes * 60))
        if d.timeIntervalSince(reference) < -Double(lookBackS) { d.addTimeInterval(86_400) }
        return d
    }

    public func timeOfDay(_ date: Date) -> TimeOfDay {
        let m = minuteOfDay(date)
        return TimeOfDay(hour: m / 60, minute: m % 60)
    }

    /// "21:30", or "21:30:45" when `seconds` and not on a whole minute.
    public func string(_ date: Date, seconds: Bool = false) -> String {
        let s = ((localSeconds(date) % 86_400) + 86_400) % 86_400
        let base = String(format: "%02d:%02d", s / 3600, s % 3600 / 60)
        return seconds && s % 60 != 0 ? base + String(format: ":%02d", s % 60) : base
    }

    /// "UTC+2", "UTC−3:30", "UTC".
    public var offsetLabel: String { Self.offsetLabel(tzOffsetS) }

    public static func offsetLabel(_ s: Int) -> String {
        if s == 0 { return "UTC" }
        let sign = s > 0 ? "+" : "−"
        let a = abs(s)
        let h = a / 3600, m = a % 3600 / 60
        return m == 0 ? "UTC\(sign)\(h)" : String(format: "UTC%@%d:%02d", sign, h, m)
    }
}
