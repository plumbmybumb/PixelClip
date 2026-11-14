import Foundation

/// The hand-off between the Share Extension and the app: one JSON file per shared item in the App
/// Group container (`group.com.example.pixelclip`, folder `ReaderInbox/`). The extension only writes; the app
/// imports and deletes them when it becomes active. Dependency-free (compiled into both targets).
struct ReaderInboxItem: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var createdAt: Date
    /// The page or note title, when the host app gave one.
    var title: String?
    /// Plain text (Notes, a text selection, or the page's visible text from Safari).
    var text: String?
    /// The shared link (Safari, any app sharing a URL).
    var url: URL?
    /// The page's HTML from Safari's preprocessing script, so the app can extract the article offline.
    var html: String?

    init(id: String = UUID().uuidString, createdAt: Date = Date(), title: String? = nil, text: String? = nil, url: URL? = nil,
         html: String? = nil) {
        self.id = id; self.createdAt = createdAt; self.title = title; self.text = text; self.url = url; self.html = html
    }
}

enum ReaderInbox {
    static let appGroup = "group.com.example.pixelclip"
    static let folder = "ReaderInbox"

    /// The inbox folder (created on demand), or nil when the App Group isn't available.
    static func directory(fileManager: FileManager = .default) -> URL? {
        guard let base = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else { return nil }
        let dir = base.appendingPathComponent(folder, isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func write(_ item: ReaderInboxItem, to dir: URL? = directory()) throws {
        guard let dir else { throw CocoaError(.fileNoSuchFile) }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(item).write(to: dir.appendingPathComponent("\(item.id).json"), options: .atomic)
    }

    /// Items waiting to be imported, oldest first.
    static func pending(in dir: URL? = directory()) -> [(url: URL, item: ReaderInboxItem)] {
        guard let dir, let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return files.filter { $0.pathExtension == "json" }
            .compactMap { url in (try? Data(contentsOf: url)).flatMap { try? dec.decode(ReaderInboxItem.self, from: $0) }.map { (url, $0) } }
            .sorted { $0.item.createdAt < $1.item.createdAt }
    }

    static func remove(_ url: URL) { try? FileManager.default.removeItem(at: url) }

    /// A rough word count for the share sheet (the app counts exactly once it imports).
    static func roughWordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }
}
