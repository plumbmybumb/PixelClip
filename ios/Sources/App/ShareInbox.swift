import Foundation
import PixelClipKit
import UIKit

/// Picks up what the PixelClipShare extension left in the App Group when the app becomes active: the newest
/// photo, GIF or video opens in Send's crop screen; a text or link is imported into the Reader and
/// opens in the Reader extra.
///
/// Shared files are other apps' content. Each is claimed (moved to `Processing/`, see `InboxClaims`)
/// before anything decodes it, so a picture or video that kills the app is gone at the next launch
/// instead of being opened again, and opening it has a deadline.
@MainActor
enum ShareInbox {
    /// Decoding a shared picture, GIF or video (a local file) may take this long.
    static let mediaDeadline = 30.0

    private static let mediaClaims: InboxClaims? = MediaInbox.directory().map { InboxClaims(inbox: $0) }

    static func collect(router: Router) {
        // The inboxes are sealed while the iPhone is locked: nothing to read yet, and nothing to give up on.
        guard UIApplication.shared.isProtectedDataAvailable else { return }
        var hadMedia = false
        if let claims = mediaClaims {
            if !claims.dropAbandoned().isEmpty { router.flash("A shared photo or video couldn’t be opened.", icon: "exclamationmark.triangle.fill") }
            let media = claims.pending()
            hadMedia = !media.isEmpty
            if let newest = media.last, let claimed = claims.claim(newest) {
                router.importMedia(mode: .send) {
                    defer { claims.finish(claimed) }
                    return try await withDeadline(seconds: mediaDeadline) { try await MediaImporter.load(fileURL: claimed, consuming: true) }
                }
            }
            media.dropLast().forEach(MediaInbox.remove)
        }
        Task {
            let store = ReaderStore.shared
            let before = Set(store.documents.map(\.id))
            await store.importInbox()
            if !hadMedia, router.extra == nil, let doc = store.documents.first(where: { !before.contains($0.id) }) {
                // The Reader opens on the new text; it shows the line about an item that didn't make it, if any.
                router.extra = ExtraRequest(extra: .reader, readerDocID: doc.id)
            } else if let problem = store.inboxProblem {
                router.flash(problem, icon: "exclamationmark.triangle.fill")
                store.dismissInboxProblem()
            }
        }
    }
}
