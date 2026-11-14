import Foundation

/// The no-op checks that keep a Send short: each request skipped is one round trip on the clip's
/// Wi‑Fi.
public enum SendSkipRules {
    /// `POST /time` again when the last sync from this iPhone is older than this.
    public static let clockMaxAge: TimeInterval = 10 * 60
    /// …or the clip's clock is this far from the iPhone's.
    public static let clockMaxDrift: TimeInterval = 2

    /// Whether to `POST /time`: the clip says it isn't synced (`time.synced` false: never, or over
    /// 24 h ago, or rebuilt from its anchor), its time zone or clock differs from the iPhone's, or this
    /// iPhone hasn't synced it in the last 10 minutes (the clip doesn't report when it was synced).
    /// - Parameters:
    ///   - status: the session's first `/status` (nil: unknown → sync).
    ///   - readAt: when that status was read (its `epoch` is compared with the iPhone's clock then).
    ///   - lastSyncedAt: this iPhone's last successful `POST /time` to this clip.
    public static func needsTimeSync(status: ClipStatus?, readAt: Date, lastSyncedAt: Date?, now: Date = Date(),
                                     tzOffsetS: Int = TimeZone.current.secondsFromGMT()) -> Bool {
        guard let status, status.time.synced else { return true }
        if status.time.tzOffsetS != tzOffsetS { return true }
        if abs(Double(status.time.epoch) - readAt.timeIntervalSince1970) > clockMaxDrift { return true }
        guard let lastSyncedAt else { return true }
        let age = now.timeIntervalSince(lastSyncedAt)
        return age < 0 || age > clockMaxAge
    }

    /// The composed playlist is already the clip's (compared parsed, not as text). A send that starts a
    /// reading at a given word (`from_word`) always PUTs: the clip restarts the reading on a PUT.
    public static func playlistUnchanged(_ composed: Playlist, onClip: Playlist?) -> Bool {
        guard let onClip else { return false }
        if composed.items.contains(where: { $0.fromWord != nil }) || (composed.queue ?? []).contains(where: { $0.fromWord != nil }) {
            return false
        }
        return normalized(composed) == normalized(onClip)
    }

    private static func normalized(_ p: Playlist) -> Playlist {
        var p = p
        if p.queue?.isEmpty == true { p.queue = nil }
        return p
    }
}
