import Foundation

/// Photos, GIFs and videos handed over by the Share Extension: copied as files into the App Group
/// container (`group.com.example.pixelclip`, folder `MediaInbox/`). The extension only writes; when the app
/// becomes active it opens the newest one in Send's crop screen and deletes them all. (Texts and links
/// go through `ReaderInbox` and land in the Reader extra.) Dependency-free: compiled into both targets.
enum MediaInbox {
    static let folder = "MediaInbox"

    /// The inbox folder (created on demand), or nil when the App Group isn't available.
    static func directory(fileManager: FileManager = .default) -> URL? {
        guard let base = fileManager.containerURL(forSecurityApplicationGroupIdentifier: ReaderInbox.appGroup) else { return nil }
        let dir = base.appendingPathComponent(folder, isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Copies a shared file in (`ext` without the dot: "jpg", "gif", "mov"…). Returns its inbox URL.
    @discardableResult
    static func add(fileAt source: URL, ext: String, to dir: URL? = directory()) throws -> URL {
        guard let dir else { throw CocoaError(.fileNoSuchFile) }
        let dest = dir.appendingPathComponent("\(Self.stamp())-\(UUID().uuidString.prefix(8)).\(ext.isEmpty ? "dat" : ext)")
        try FileManager.default.copyItem(at: source, to: dest)
        return dest
    }

    /// Writes shared bytes in (an image handed over as data).
    @discardableResult
    static func add(data: Data, ext: String, to dir: URL? = directory()) throws -> URL {
        guard let dir else { throw CocoaError(.fileNoSuchFile) }
        let dest = dir.appendingPathComponent("\(Self.stamp())-\(UUID().uuidString.prefix(8)).\(ext.isEmpty ? "dat" : ext)")
        try data.write(to: dest, options: .atomic)
        return dest
    }

    /// Everything waiting, newest last.
    static func pending(in dir: URL? = directory()) -> [URL] {
        guard let dir, let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { !$0.lastPathComponent.hasPrefix(".") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func remove(_ url: URL) { try? FileManager.default.removeItem(at: url) }

    /// Sortable by name: milliseconds since 1970, zero-padded.
    private static func stamp() -> String {
        let ms = Int(Date().timeIntervalSince1970 * 1000)
        let s = String(ms)
        return String(repeating: "0", count: max(0, 15 - s.count)) + s
    }
}
