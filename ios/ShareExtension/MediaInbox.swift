import Foundation

/// Photos, GIFs and videos handed over by the Share Extension: files in the App Group container (folder
/// `MediaInbox/`). The extension only writes; when the app becomes active it claims the newest one,
/// opens it in Send's crop screen and deletes them all (`ShareInbox`). (Texts and links go through
/// `ReaderInbox` and land in the Reader extra.) Dependency-free: compiled into both targets.
enum MediaInbox {
    static let folder = "MediaInbox"
    /// The biggest picture and video the share sheet takes. A photo is a few MB (a 48 MP ProRAW about
    /// 75 MB), a minute of 4K video about 400 MB; the clip shows a few seconds at 536×240.
    static let maxImageBytes = 200 << 20
    static let maxVideoBytes = 2 << 30

    /// The inbox folder (created on demand), or nil when the App Group isn't available.
    static func directory(fileManager: FileManager = .default) -> URL? { AppGroup.folder(folder, fileManager: fileManager) }

    private static func destination(in dir: URL, ext: String) -> URL {
        dir.appendingPathComponent("\(AppGroup.stamp())-\(UUID().uuidString.prefix(8)).\(ext.isEmpty ? "dat" : ext)")
    }

    /// Takes a shared file in (`ext` without the dot: "jpg", "gif", "mov"…): moved when `moving` (the
    /// extension's own temporary copy: nothing is left behind), else copied. Returns its inbox URL.
    @discardableResult
    static func add(fileAt source: URL, ext: String, moving: Bool = false, to dir: URL? = directory()) throws -> URL {
        guard let dir else { throw CocoaError(.fileNoSuchFile) }
        let dest = destination(in: dir, ext: ext)
        if moving {
            do { try FileManager.default.moveItem(at: source, to: dest) } catch {
                // Another volume: copy, then drop the original.
                try FileManager.default.copyItem(at: source, to: dest)
                try? FileManager.default.removeItem(at: source)
            }
        } else {
            try FileManager.default.copyItem(at: source, to: dest)
        }
        DataProtection.protect(dest, .whileUnlocked)
        return dest
    }

    /// Writes shared bytes in (an image handed over as data).
    @discardableResult
    static func add(data: Data, ext: String, to dir: URL? = directory()) throws -> URL {
        guard let dir else { throw CocoaError(.fileNoSuchFile) }
        let dest = destination(in: dir, ext: ext)
        try data.write(to: dest, options: [.atomic, .completeFileProtection])
        return dest
    }

    static func remove(_ url: URL) { try? FileManager.default.removeItem(at: url) }
}
