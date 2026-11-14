import SwiftUI
import PixelClipKit

/// Home ▸ Recent ▸ a thumbnail: send it again (or add it to the playlist).
struct ResendSheet: View {
    let itemID: String
    @Environment(LibraryStore.self) private var library
    @Environment(Sender.self) private var sender
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let item = library.item(itemID) {
                Text(item.name).font(.title3.bold()).foregroundStyle(Z2.text).lineLimit(2)
                Z2ClipFrame { LibraryItemPreview(id: item.id, glow: true, bezel: false, playing: true) }
                Spacer(minLength: 0)
                Z2SendButtons(mode: .send, send: {
                    sender.sendNow(library.content(for: item.id), title: item.name)
                    dismiss()
                }, addToPlaylist: {
                    sender.addToPlaylist(library.content(for: item.id), name: item.name)
                    dismiss()
                })
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 28)
        .padding(.bottom, 8)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .presentationBackground(Z2.sheet)
    }
}
