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
        let titleHint = (extensionContext?.inputItems.first as? NSExtensionItem)?.attributedContentText?.string
        Task { await load(providers, titleHint: titleHint) }
    }

    private func load(_ providers: [NSItemProvider], titleHint: String?) async {
        // A picture or a video first: it goes to Send.
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.movie.identifier),
               let file = await Self.copyFile(p, type: .movie, fallbackExt: "mov") {
                model.media = ShareModel.Media(url: file, isVideo: true)
                model.title = titleHint ?? "Video"
                model.phase = .ready
                return
            }
            for (type, ext) in [(UTType.gif, "gif"), (.heic, "heic"), (.png, "png"), (.jpeg, "jpg"), (.image, "jpg")]
            where p.hasItemConformingToTypeIdentifier(type.identifier) {
                if let file = await Self.copyFile(p, type: type, fallbackExt: ext) {
                    model.media = ShareModel.Media(url: file, isVideo: false)
                    model.title = titleHint ?? "Photo"
                    model.phase = .ready
                    return
                }
            }
        }
        var title = titleHint ?? ""
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.propertyList.identifier),
               let page = await Self.loadPage(p) {
                // Safari's preprocessing results.
                if let u = page["url"].flatMap(URL.init(string:)) { model.url = u }
                if let t = page["title"], !t.isEmpty { title = t }
                if let h = page["html"], !h.isEmpty { model.html = h }
                if let text = page["text"], !text.isEmpty { model.text = text }
            } else if p.hasItemConformingToTypeIdentifier(UTType.url.identifier), model.url == nil,
                      let u = await Self.loadURL(p) {
                if u.isFileURL, let text = try? String(contentsOf: u, encoding: .utf8) { model.text = text } else { model.url = u }
            } else if p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier), model.text == nil,
                      let text = await Self.loadText(p) {
                // A bare link shared as text is a link.
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if let u = URL(string: trimmed), u.scheme?.hasPrefix("http") == true, !trimmed.contains(" ") { model.url = u } else { model.text = text }
            }
        }
        if title.isEmpty, let text = model.text {
            let first = text.split(separator: "\n").first.map(String.init) ?? ""
            title = first.count <= 100 ? first : String(first.prefix(60)) + "…"
        }
        if title.isEmpty, let u = model.url { title = u.host() ?? u.absoluteString }
        model.title = title
        model.phase = (model.text == nil && model.url == nil) ? .failed("There’s nothing to read in what was shared.") : .ready
    }

    /// The provider's file, copied somewhere this extension owns (the system's copy only lives inside
    /// the callback).
    private static func copyFile(_ p: NSItemProvider, type: UTType, fallbackExt: String) async -> URL? {
        await withCheckedContinuation { (cont: CheckedContinuation<URL?, Never>) in
            _ = p.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                guard let url else { cont.resume(returning: nil); return }
                let ext = url.pathExtension.isEmpty ? fallbackExt : url.pathExtension.lowercased()
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent("share-\(UUID().uuidString).\(ext)")
                do {
                    try FileManager.default.copyItem(at: url, to: dest)
                    cont.resume(returning: dest)
                } catch {
                    cont.resume(returning: nil)
                }
            }
        }
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
                if let s = item as? String { cont.resume(returning: s); return }
                if let d = item as? Data { cont.resume(returning: String(data: d, encoding: .utf8)); return }
                cont.resume(returning: (item as? URL).flatMap { try? String(contentsOf: $0, encoding: .utf8) })
            }
        }
    }

    private func save() {
        model.phase = .saving
        do {
            if let media = model.media {
                try MediaInbox.add(fileAt: media.url, ext: media.url.pathExtension)
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
        extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
    }
}
