import Foundation

/// Crash-safe hand-over of the files in a shared inbox folder (what the Share Extension leaves in the
/// App Group for the app).
///
/// Reading a shared item means parsing someone else's page, book, picture or video. If that ever kills
/// the app, the item must not be waiting at the next launch to kill it again. So an item is **claimed**
/// before anything reads it: moved into `Processing/` inside the inbox (a rename, atomic on the same
/// volume). When it has been dealt with it is deleted (`finish`), or handed back for a later try
/// (`release`). Whatever is still in `Processing/` when a new run starts was being read when the last
/// run died: `dropAbandoned()` deletes it, unread.
public final class InboxClaims: @unchecked Sendable {
    public let inbox: URL
    public let processing: URL
    private let lock = NSLock()
    /// File names this run has claimed and not finished: never "abandoned", however often the app comes forward.
    private var live: Set<String> = []

    public init(inbox: URL, processingFolder: String = "Processing") {
        self.inbox = inbox
        processing = inbox.appendingPathComponent(processingFolder, isDirectory: true)
    }

    /// The files waiting in the inbox, by name (the extension names them so that is oldest first).
    public func pending() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: [.isRegularFileKey])) ?? []
        return files
            .filter { !$0.lastPathComponent.hasPrefix(".") && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Takes `file` out of the inbox before it is read. Returns where it now is, or nil when it is gone
    /// (claimed already) or can't be moved; then it must not be read.
    public func claim(_ file: URL) -> URL? {
        let name = file.lastPathComponent
        let dest = processing.appendingPathComponent(name)
        let fm = FileManager.default
        return lock.withLock {
            guard !live.contains(name) else { return nil }
            do {
                try fm.createDirectory(at: processing, withIntermediateDirectories: true)
                try fm.moveItem(at: file, to: dest)
            } catch {
                return nil
            }
            live.insert(name)
            return dest
        }
    }

    /// A claimed file has been dealt with (imported, or given up on): delete it.
    public func finish(_ claimed: URL) {
        try? FileManager.default.removeItem(at: claimed)
        _ = lock.withLock { live.remove(claimed.lastPathComponent) }
    }

    /// Hands a claimed file back to the inbox, unread or to be tried again later (a link while offline).
    public func release(_ claimed: URL) {
        let name = claimed.lastPathComponent
        do {
            try FileManager.default.moveItem(at: claimed, to: inbox.appendingPathComponent(name))
        } catch {
            try? FileManager.default.removeItem(at: claimed)   // never leave it where the next run would call it abandoned
        }
        _ = lock.withLock { live.remove(name) }
    }

    /// Deletes what an earlier run claimed and never finished (it crashed, hung or was killed while
    /// reading them) and returns their names. Safe to call every time the app comes forward: this run's
    /// own claims are left alone.
    @discardableResult
    public func dropAbandoned() -> [String] {
        let fm = FileManager.default
        return lock.withLock {
            let left = (try? fm.contentsOfDirectory(at: processing, includingPropertiesForKeys: nil)) ?? []
            var dropped: [String] = []
            for file in left where !live.contains(file.lastPathComponent) {
                try? fm.removeItem(at: file)
                dropped.append(file.lastPathComponent)
            }
            return dropped.sorted()
        }
    }

    /// A file's size in bytes (nil when it can't be read).
    public static func size(of file: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue
    }
}
