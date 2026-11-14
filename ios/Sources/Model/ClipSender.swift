import Foundation
import Observation
import PixelClipKit

/// Sends the composed document without a caller holding the session and the library: Undo uses it, and
/// the UI can too (e.g. after toggling the playlist). The same path as the Send flow: a
/// `SyncController(.playlist)` run against the app's `ClipSession` and `LibraryStore`.
///
/// Attach once at launch: `ClipSender.shared.attach(session:library:)` (it also hands the library to
/// `PlaylistStore`). If the UI wants its own send sheet instead of a
/// quiet send, it sets `present` and runs the request itself.
@MainActor @Observable
final class ClipSender {
    static let shared = ClipSender()

    /// The quiet send in progress (or the last one), for progress and its outcome.
    private(set) var current: SyncController?
    var isSending: Bool { current?.isRunning == true }

    /// When set, `send` hands the request to the UI (which presents its send sheet) instead of running it here.
    @ObservationIgnored var present: (@MainActor (SyncRequest) -> Void)?
    @ObservationIgnored private(set) weak var session: ClipSession?
    @ObservationIgnored private(set) weak var library: LibraryStore?

    func attach(session: ClipSession, library: LibraryStore) {
        self.session = session
        self.library = library
        PlaylistStore.shared.library = library
    }

    /// Sends `request` (default: the composed document). Returns when the send has finished (or was
    /// handed to the UI). Without an attached session nothing happens: the change stays unsent and goes
    /// with the next send.
    func send(_ request: SyncRequest = .playlist) async {
        if let present {
            present(request)
            return
        }
        guard let session, let library else { return }
        let controller = SyncController(request: request)
        current = controller
        await controller.run(session: session, library: library)
    }
}
