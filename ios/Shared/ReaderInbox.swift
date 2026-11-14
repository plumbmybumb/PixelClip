import Foundation

/// The hand-off between the Share Extension and the app: one JSON file per shared item in the App
/// Group container (folder `ReaderInbox/`). The extension only writes; the app claims, imports and
/// deletes them when it becomes active (`ReaderStore.importInbox`). Dependency-free (compiled into both
/// targets).
struct ReaderInboxItem: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var createdAt: Date
    /// The page or note title, when the host app gave one.
    var title: String?
    /// Plain text (Notes, a text selection, or the page's visible text from Safari).
    var text: String?
    /// The shared link (Safari, any app sharing a URL).
    var url: URL?
    /// The page's HTML from Safari's preprocessing script (without its scripts and styles), so the app
    /// can extract the article offline.
    var html: String?
    /// Times the app has asked the site for `url` and failed (see `LinkRetry`).
    var attempts: Int?

    init(id: String = UUID().uuidString, createdAt: Date = Date(), title: String? = nil, text: String? = nil, url: URL? = nil,
         html: String? = nil, attempts: Int? = nil) {
        self.id = id; self.createdAt = createdAt; self.title = title; self.text = text; self.url = url; self.html = html
        self.attempts = attempts
    }
}

/// The App Group the app and its Share Extension share. One build setting names it (`APP_GROUP_ID`, see
/// `Config.xcconfig`): it reaches both targets' entitlements and, through the `PixelClipAppGroup`
/// Info.plist key, this code.
enum AppGroup {
    static let identifier = Bundle.main.object(forInfoDictionaryKey: "PixelClipAppGroup") as? String ?? ""

    /// A folder in the shared container (created on demand, readable only while the iPhone is unlocked),
    /// or nil when the App Group isn't available.
    static func folder(_ name: String, fileManager: FileManager = .default) -> URL? {
        guard !identifier.isEmpty, let base = fileManager.containerURL(forSecurityApplicationGroupIdentifier: identifier) else { return nil }
        let dir = base.appendingPathComponent(name, isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        DataProtection.protect(dir, .whileUnlocked)
        return dir
    }

    /// Sortable by name, oldest first: milliseconds since 1970, zero-padded.
    static func stamp(_ date: Date = Date()) -> String {
        let s = String(Int(date.timeIntervalSince1970 * 1000))
        return String(repeating: "0", count: max(0, 15 - s.count)) + s
    }
}

enum ReaderInbox {
    static let folder = "ReaderInbox"
    /// A shared item's file is never bigger than this (Safari's page is at most 4,000,000 characters);
    /// anything bigger isn't read.
    static let maxFileBytes = 32 << 20
    /// What the share sheet keeps of a shared text and its title.
    static let maxTextBytes = 4 << 20
    static let maxTitleCharacters = 300

    /// The inbox folder (created on demand), or nil when the App Group isn't available.
    static func directory(fileManager: FileManager = .default) -> URL? { AppGroup.folder(folder, fileManager: fileManager) }

    static func encoded(_ item: ReaderInboxItem) throws -> Data {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(item)
    }

    static func decoded(_ data: Data) -> ReaderInboxItem? {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(ReaderInboxItem.self, from: data)
    }

    /// Saves a shared item; the file name sorts by time, so the app takes them oldest first.
    static func write(_ item: ReaderInboxItem, to dir: URL? = directory()) throws {
        guard let dir else { throw CocoaError(.fileNoSuchFile) }
        let file = dir.appendingPathComponent("\(AppGroup.stamp(item.createdAt))-\(item.id).json")
        try encoded(item).write(to: file, options: [.atomic, .completeFileProtection])
    }

    /// A rough word count for the share sheet (the app counts exactly once it imports).
    static func roughWordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }
}
