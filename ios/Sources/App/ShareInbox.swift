import Foundation

/// Picks up what the PixelClipShare extension left in the App Group when the app becomes active: the newest
/// photo, GIF or video opens in Send's crop screen; a text or link is imported into the Reader and
/// opens in the Reader extra.
@MainActor
enum ShareInbox {
    static func collect(router: Router) {
        let media = MediaInbox.pending()
        if let newest = media.last {
            let older = media.dropLast()
            router.importMedia(mode: .send) {
                defer { MediaInbox.remove(newest) }
                return try await MediaImporter.load(fileURL: newest)
            }
            older.forEach(MediaInbox.remove)
        }
        let textsWaiting = !ReaderInbox.pending().isEmpty
        Task {
            let store = ReaderStore.shared
            let before = Set(store.documents.map(\.id))
            await store.importInbox()
            guard textsWaiting, media.isEmpty, router.extra == nil,
                  let doc = store.documents.first(where: { !before.contains($0.id) }) else { return }
            router.extra = ExtraRequest(extra: .reader, readerDocID: doc.id)
        }
    }
}
