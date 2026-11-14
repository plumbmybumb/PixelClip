import Foundation
import Observation
import PixelClipKit

/// Where a making screen ends: on the clip (the default, with "Add to the playlist instead"), or in the
/// playlist (reached from the playlist's "+ Add something").
enum ComposeMode: String, Hashable, Sendable {
    case send, playlist
}

/// The pushed screens. Home is the root; everything is one tap from it (docs/DESIGN.md).
enum Route: Hashable {
    /// Send ▸ the crop screen for picked (or shared) media, held in `Router.media`.
    case crop(UUID, ComposeMode)
    case draw(ComposeMode)
    case write(ComposeMode)
    case playlist
    case settings
    /// Settings ▸ If something's off ▸ Advanced: everything technical.
    case advanced
}

/// The Extras, each a sheet (preview, minimal choices, Send, playlist alternative).
enum Extra: String, CaseIterable, Identifiable, Hashable {
    case tarot, scenes, loops, reader

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tarot: "Tarot"
        case .scenes: "Scenes"
        case .loops: "Loops"
        case .reader: "Reader"
        }
    }
}

struct ExtraRequest: Identifiable, Hashable {
    let extra: Extra
    var mode: ComposeMode = .send
    /// Reader: open on this text (a text that just came in from the share sheet).
    var readerDocID: String?
    var id: String { "\(extra.rawValue)-\(mode.rawValue)-\(readerDocID ?? "")" }
}

/// A short line floating at the bottom ("Sent · Undo", "Removed · Undo"). Undo, when there is one,
/// stays for 5 seconds.
struct Toast: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var systemImage: String
    var seconds: Double = 5
    var undo: (@MainActor () -> Void)?

    static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
}

@MainActor @Observable
final class Router {
    var path: [Route] = [] { didSet { if oldValue != path { releaseClosedMediaSoon() } } }
    /// The Extras sheet on screen.
    var extra: ExtraRequest?
    /// Home ▸ Recent ▸ a thumbnail: the re-send sheet (a library item id).
    var resend: String?
    /// The photo picker is up for this mode.
    var picking: ComposeMode?
    /// Playlist ▸ + Add something.
    var addSomething = false
    /// Settings ▸ Can't find the clip?
    var cantFind = false
    /// Media waiting for (or shown in) the crop screen.
    var media: [UUID: ImportedMedia] = [:]
    /// Reading picked media before the crop screen opens.
    var importing = false
    var importError: String?
    var toast: Toast?
    /// Debug: the Share Extension's sheet inside the app (`-PixelClipScreen share`, screenshots).
    var shareSheetPreview = false

    func open(_ route: Route) { path.append(route) }

    /// Back to Home (after a send from a pushed screen).
    func home() { path.removeAll() }

    /// After a making screen's button: back to Home (a send), or back to the playlist (an add from
    /// "+ Add something").
    func finish(_ mode: ComposeMode) {
        switch mode {
        case .send: home()
        case .playlist:
            if let i = path.firstIndex(of: .playlist) { path = Array(path.prefix(i + 1)) } else { path = [.playlist] }
        }
    }

    /// Pops the top screen.
    func back() { if !path.isEmpty { path.removeLast() } }

    /// Shows picked or shared media in the crop screen.
    func openMedia(_ m: ImportedMedia, mode: ComposeMode) {
        let key = UUID()
        // A crop screen already up (another share arrived) is replaced.
        if case .crop? = path.last { path.removeLast() }
        media[key] = m
        path.append(.crop(key, mode))
    }

    /// Media whose crop screen has closed (sent, added or backed out of) is let go, and a movie's working
    /// copy in `tmp` is deleted (the library has kept its own copy of what was sent). A moment later, so
    /// the screen still has its picture while it slides away.
    private func releaseClosedMediaSoon() {
        guard !media.isEmpty else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            releaseClosedMedia()
        }
    }

    private func releaseClosedMedia() {
        let open = Set(path.compactMap { route -> UUID? in
            if case .crop(let key, _) = route { return key }
            return nil
        })
        for (key, m) in media where !open.contains(key) {
            if case .video(let url, _) = m.source { MediaImporter.discardTemporaryCopy(url) }
            media[key] = nil
        }
    }

    /// Reads picked media, then opens the crop screen.
    func importMedia(mode: ComposeMode, _ load: @escaping @Sendable () async throws -> ImportedMedia) {
        importing = true
        Task {
            do {
                let m = try await load()
                importing = false
                openMedia(m, mode: mode)
            } catch {
                importing = false
                importError = (error as? ImportError)?.errorDescription ?? "Couldn’t open that one. Try another photo, GIF or video."
            }
        }
    }

    /// Shows `text` for a few seconds (with Undo when `undo` is given).
    func show(_ text: String, systemImage: String = "checkmark.circle.fill", seconds: Double = 5,
              undo: (@MainActor () -> Void)? = nil) {
        let t = Toast(text: text, systemImage: systemImage, seconds: seconds, undo: undo)
        toast = t
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            if toast?.id == t.id { toast = nil }
        }
    }

    /// Kept for the reused screens (calibration, Advanced): a line without Undo.
    func flash(_ text: String, icon: String = "info.circle.fill") { show(text, systemImage: icon, seconds: 4) }
}
