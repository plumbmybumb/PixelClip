import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif

/// A phone-side reminder shortly before a moment ("PixelClip will show “Happy birthday” at 00:00").
public struct MomentReminder: Sendable, Equatable {
    public var id: String
    public var fireAt: Date
    public var title: String
    public var body: String
}

public enum MomentReminders {
    public static let leadS = 300
    public static let idPrefix = "pixelclip.tonight."

    /// Reminders for moments whose reminder time is still ahead. Times are formatted in `timeZone`
    /// (the phone's: the notification is read on the phone).
    public static func plan(_ moments: [Moment], deviceName: String, timeZone: TimeZone = .current,
                            now: Date, leadS: Int = leadS) -> [MomentReminder] {
        moments.compactMap { m in
            let fire = m.start.addingTimeInterval(-TimeInterval(leadS))
            guard fire > now else { return nil }
            let clock = ClipLocalTime(tzOffsetS: timeZone.secondsFromGMT(for: m.start))
            return MomentReminder(id: idPrefix + m.id, fireAt: fire, title: deviceName,
                                  body: "\(deviceName) will show “\(m.title)” at \(clock.string(m.start)).")
        }
    }
}

#if canImport(UserNotifications)
/// Schedules `MomentReminder`s with UNUserNotificationCenter. Only ever touches requests whose id
/// starts with `MomentReminders.idPrefix`. Not used by tests (the center needs an app bundle).
@MainActor
public enum MomentNotifier {
    /// Asks once; later calls return the stored answer.
    public static func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        case .denied: return false
        default:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        }
    }

    /// Replace all Tonight reminders with `reminders`.
    public static func replace(with reminders: [MomentReminder]) async {
        let center = UNUserNotificationCenter.current()
        await removeAll()
        for r in reminders {
            let content = UNMutableNotificationContent()
            content.title = r.title
            content.body = r.body
            content.sound = .default
            let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: r.fireAt)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: r.id, content: content, trigger: trigger))
        }
    }

    public static func removeAll() async {
        let center = UNUserNotificationCenter.current()
        let ids = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(MomentReminders.idPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }
}
#endif
