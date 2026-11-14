import Foundation

/// The one-line summary at the top of Tonight: "3 moments tonight · Sunset after 21:30 · clock synced 2 min ago".
public enum TonightSummary {

    public static func parts(plan: TonightPlan, projection: TimelineProjection, now: Date) -> [String] {
        var out: [String] = []
        let n = projection.upcoming.count
        out.append(n == 0 ? "No moments yet" : "\(n) moment\(n == 1 ? "" : "s") tonight")
        let windowed = plan.slots.filter(\.hasWindow)
        if let first = windowed.first, let w = first.windowText {
            let name = first.title
            out.append(windowed.count > 1 ? "\(name) \(w) (+\(windowed.count - 1) more)" : "\(name) \(w)")
        }
        out.append(clockText(projection.clock, now: now))
        return out
    }

    public static func line(plan: TonightPlan, projection: TimelineProjection, now: Date) -> String {
        parts(plan: plan, projection: projection, now: now).joined(separator: " · ")
    }

    public static func clockText(_ clock: ClipClock, now: Date) -> String {
        switch clock {
        case .synced(let at?): "clock synced \(relative(at, now: now))"
        case .synced(nil): "clock synced"
        case .unsynced: "clock not set"
        case .unknown: "clock not checked"
        }
    }

    /// "just now", "2 min ago", "3 h ago", "2 days ago" (deterministic, for tests and VoiceOver).
    public static func relative(_ date: Date, now: Date) -> String {
        let s = Int(now.timeIntervalSince(date))
        switch s {
        case ..<60: return "just now"
        case ..<3600: return "\(s / 60) min ago"
        case ..<86_400: return "\(s / 3600) h ago"
        default:
            let d = s / 86_400
            return d == 1 ? "1 day ago" : "\(d) days ago"
        }
    }

    /// "45 s", "1 min", "1 min 30 s", "30 min".
    public static func duration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) s" }
        return seconds % 60 == 0 ? "\(seconds / 60) min" : "\(seconds / 60) min \(seconds % 60) s"
    }
}
