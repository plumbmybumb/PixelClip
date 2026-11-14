import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Share Extension entry point. A photo, GIF or video goes into `MediaInbox` and opens in Send's crop
/// screen when PixelClip becomes active; a text or link (and, from Safari, the page itself via
/// `PixelClipSharePreprocessor.js`) goes into `ReaderInbox` and opens in the Reader extra.
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        let sheet = ShareSheetView(model: model, onSave: { [weak self] in self?.save() }, onCancel: { [weak self] in self?.cancel() })
        let host = UIHostingController(rootView: sheet)
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        let titleHint = ((extensionContext?.inputItems.first as? NSExtensionItem)?.attributedContentText?.string).map(Self.clipped(title:))
        Self.sweepTemporaryCopies()   // what an earlier, interrupted share left behind
        Task { await load(providers, titleHint: titleHint) }
    }

    /// The temporary copy of a shared picture or video lives in this extension's `tmp` as `share-…`.
    nonisolated private static let temporaryPrefix = "share-"

    nonisolated private static func sweepTemporaryCopies() {
        let tmp = FileManager.default.temporaryDirectory
        for file in (try? FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)) ?? []
        where file.lastPathComponent.hasPrefix(temporaryPrefix) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// A link the Reader will fetch: `http` or `https` with a host, nothing else.
    nonisolated private static func isWebLink(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", let host = url.host() else { return false }
        return !host.isEmpty
    }

    /// At most `ReaderInbox.maxTextBytes` of a text (the clip keeps 1 MB of it), cut between characters.
    nonisolated private static func clipped(text: String) -> String {
        guard text.utf8.count > ReaderInbox.maxTextBytes else { return text }
        return String(decoding: Data(text.utf8.prefix(ReaderInbox.maxTextBytes)), as: UTF8.self)
    }

    nonisolated private static func clipped(title: String) -> String { String(title.prefix(ReaderInbox.maxTitleCharacters)) }

    /// The start of a text file (at most `ReaderInbox.maxTextBytes`), or nil when `url` isn't a readable file.
    nonisolated private static func text(ofFile url: URL) -> String? {
        guard url.isFileURL, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: ReaderInbox.maxTextBytes), !data.isEmpty else { return nil }
        if let s = String(data: data, encoding: .utf8) { return s }
        // Cut in the middle of a character: drop the broken tail.
        let s = String(decoding: data, as: UTF8.self)
        return data.count == ReaderInbox.maxTextBytes ? String(s.dropLast()) : nil
    }

    private func load(_ providers: [NSItemProvider], titleHint: String?) async {
        // A picture or a video first: it goes to Send.
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                switch await Self.takeFile(p, type: .movie, fallbackExt: "mov", limit: MediaInbox.maxVideoBytes) {
                case .file(let file):
                    model.media = ShareModel.Media(url: file, isVideo: true)
                    model.title = titleHint ?? "Video"
                    model.phase = .ready
                    return
                case .tooBig:
                    model.phase = .failed("That video is too long to send from here. Trim it in Photos, then share it again.")
                    return
                case .none: break
                }
            }
            for (type, ext) in [(UTType.gif, "gif"), (.heic, "heic"), (.png, "png"), (.jpeg, "jpg"), (.image, "jpg")]
            where p.hasItemConformingToTypeIdentifier(type.identifier) {
                switch await Self.takeFile(p, type: type, fallbackExt: ext, limit: MediaInbox.maxImageBytes) {
                case .file(let file):
                    model.media = ShareModel.Media(url: file, isVideo: false)
                    model.title = titleHint ?? "Photo"
                    model.phase = .ready
                    model.thumbnail = await Self.thumbnail(of: file)   // after "ready": the button never waits for it
                    return
                case .tooBig:
                    model.phase = .failed("That picture is too big to send from here.")
                    return
                case .none: break
                }
            }
        }
        var title = titleHint ?? ""
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.propertyList.identifier),
               let page = await Self.loadPage(p) {
                // Safari's preprocessing results.
                if let u = page["url"].flatMap(URL.init(string:)), Self.isWebLink(u) { model.url = u }
                if let t = page["title"], !t.isEmpty { title = Self.clipped(title: t) }
                if let h = page["html"], !h.isEmpty { model.html = h }
                if let text = page["text"], !text.isEmpty { model.text = Self.clipped(text: text) }
            } else if p.hasItemConformingToTypeIdentifier(UTType.url.identifier), model.url == nil,
                      let u = await Self.loadURL(p) {
                // A file is read here (the app couldn't reach it); a web link is fetched by the app; nothing else is kept.
                if u.isFileURL { if let text = Self.text(ofFile: u) { model.text = text } } else if Self.isWebLink(u) { model.url = u }
            } else if p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier), model.text == nil,
                      let text = await Self.loadText(p) {
                // A bare link shared as text is a link.
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.utf8.count <= 2_048, !trimmed.contains(" "), let u = URL(string: trimmed), Self.isWebLink(u) { model.url = u } else { model.text = text }
            }
        }
        if title.isEmpty, let text = model.text {
            let first = text.prefix(400).split(separator: "\n").first.map(String.init) ?? ""
            title = first.count <= 100 ? first : String(first.prefix(60)) + "…"
        }
        if title.isEmpty, let u = model.url { title = Self.clipped(title: u.host() ?? u.absoluteString) }
        model.title = title
        model.phase = (model.text == nil && model.url == nil) ? .failed("There’s nothing to read in what was shared.") : .ready
    }

    private enum Taken: Sendable { case file(URL), tooBig, none }

    /// The provider's file, moved somewhere this extension owns (the system's copy only lives inside
    /// the callback, and moving it costs no second copy), unless it is over `limit` bytes.
    private static func takeFile(_ p: NSItemProvider, type: UTType, fallbackExt: String, limit: Int) async -> Taken {
        await withCheckedContinuation { (cont: CheckedContinuation<Taken, Never>) in
            _ = p.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                guard let url else { cont.resume(returning: .none); return }
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
                guard size <= limit else { cont.resume(returning: .tooBig); return }
                let ext = url.pathExtension.isEmpty ? fallbackExt : url.pathExtension.lowercased()
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent("\(temporaryPrefix)\(UUID().uuidString).\(ext)")
                do {
                    do { try FileManager.default.moveItem(at: url, to: dest) } catch { try FileManager.default.copyItem(at: url, to: dest) }
                    cont.resume(returning: .file(dest))
                } catch {
                    cont.resume(returning: .none)
                }
            }
        }
    }

    /// A small preview of the shared picture, decoded at thumbnail size (never the whole image: the
    /// extension has little memory).
    nonisolated private static func thumbnail(of file: URL) async -> UIImage? {
        await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                            kCGImageSourceThumbnailMaxPixelSize: 600, kCGImageSourceShouldCacheImmediately: true]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map { UIImage(cgImage: $0) }
        }.value
    }

    private static func loadPage(_ p: NSItemProvider) async -> [String: String]? {
        await withCheckedContinuation { (cont: CheckedContinuation<[String: String]?, Never>) in
            p.loadItem(forTypeIdentifier: UTType.propertyList.identifier, options: nil) { item, _ in
                let dict = item as? NSDictionary
                let results = dict?[NSExtensionJavaScriptPreprocessingResultsKey] as? [String: Any]
                cont.resume(returning: results?.compactMapValues { $0 as? String })
            }
        }
    }

    private static func loadURL(_ p: NSItemProvider) async -> URL? {
        await withCheckedContinuation { (cont: CheckedContinuation<URL?, Never>) in
            p.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                cont.resume(returning: (item as? URL) ?? (item as? NSURL).map { $0 as URL })
            }
        }
    }

    private static func loadText(_ p: NSItemProvider) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            p.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                if let s = item as? String { cont.resume(returning: clipped(text: s)); return }
                if let d = item as? Data { cont.resume(returning: String(data: d.prefix(ReaderInbox.maxTextBytes), encoding: .utf8)); return }
                cont.resume(returning: (item as? URL).flatMap(text(ofFile:)))
            }
        }
    }

    private func save() {
        model.phase = .saving
        do {
            if let media = model.media {
                try MediaInbox.add(fileAt: media.url, ext: media.url.pathExtension, moving: true)
            } else {
                try ReaderInbox.write(model.item)
            }
            model.phase = .saved
            Task {
                try? await Task.sleep(for: .milliseconds(450))
                extensionContext?.completeRequest(returningItems: nil)
            }
        } catch {
            model.phase = .failed("Couldn’t save it for PixelClip. Is the app installed?")
        }
    }

    private func cancel() {
        if let media = model.media { try? FileManager.default.removeItem(at: media.url) }   // the temporary copy
        extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
    }
}
