import PhotosUI
import SwiftUI
import PixelClipKit

/// PixelClip's one navigation stack: Home at the root, every other screen pushed from it, the Extras and
/// the re-send sheet over it. No tab bar (docs/DESIGN.md).
struct AppRoot: View {
    @Environment(Router.self) private var router
    @Environment(ClipSession.self) private var session
    @Environment(LibraryStore.self) private var library
    @State private var pickerItem: PhotosPickerItem?
    @Namespace private var zoom

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.path) {
            HomeView()
                .navigationDestination(for: Route.self) { route in destination(route) }
        }
        .environment(\.zoomNamespace, zoom)
        .tint(Color.accentColor)
        .photosPicker(isPresented: Binding(get: { router.picking != nil }, set: { if !$0 { router.picking = nil } }),
                      selection: $pickerItem, matching: .any(of: [.images, .videos, .livePhotos]),
                      preferredItemEncoding: .current)
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            let mode = router.picking ?? .send
            router.picking = nil
            pickerItem = nil
            router.importMedia(mode: mode) { try await MediaImporter.load(item) }
        }
        .sheet(item: $router.extra) { request in
            ExtraSheet(request: request)
                .navigationTransition(.zoom(sourceID: request.extra.rawValue, in: zoom))
        }
        .sheet(item: Binding(get: { router.resend.map(ResendID.init) }, set: { router.resend = $0?.id })) { r in
            ResendSheet(itemID: r.id)
                .navigationTransition(.zoom(sourceID: "recent-\(r.id)", in: zoom))
        }
        .sheet(isPresented: $router.addSomething) { AddSomethingSheet() }
        .sheet(isPresented: $router.cantFind) { CantFindClipSheet() }
        #if DEBUG
        .sheet(isPresented: $router.shareSheetPreview) {
            ShareSheetView(model: DemoContent.shareModel, onSave: {
                try? ReaderInbox.write(DemoContent.shareModel.item)
                router.shareSheetPreview = false
            }, onCancel: { router.shareSheetPreview = false })
            .presentationDetents([.medium])
        }
        #endif
        .overlay {
            if router.importing {
                WorkingLabel(text: "Opening…")
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .glassEffect(.regular, in: .capsule)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(Z2.spring, value: router.importing)
        // Home's send-status capsule, below its header (the playlist screen has its own).
        .overlay(alignment: .top) {
            if router.path.isEmpty { SendStatusCapsule().padding(.top, 54) }
        }
        .overlay(alignment: .bottom) {
            if let toast = router.toast {
                ToastView(toast: toast) { router.toast = nil }
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Z2.spring, value: router.toast)
        .task {
            // Once: the earlier design's old playlist model moves into Now + the playlist (nothing disappears).
            if let line = ClipDocument.migrateIfNeeded(library: library) { router.flash(line) }
            // PixelClip pack pieces that changed in this app version replace their library copies.
            StarterStore.shared.refreshStale(in: library)
        }
        .task(id: session.useVirtual) {
            // Drive the virtual clip's panel so previews show what it is displaying right now.
            while session.useVirtual && !Task.isCancelled {
                await session.updateVirtualScreen()
                try? await Task.sleep(for: .milliseconds(66))
            }
        }
        .alert("Can’t Open That", isPresented: Binding(get: { router.importError != nil }, set: { if !$0 { router.importError = nil } })) {
            Button("OK", role: .cancel) { router.importError = nil }
        } message: {
            Text(router.importError ?? "")
        }
    }

    @ViewBuilder private func destination(_ route: Route) -> some View {
        switch route {
        case .crop(let key, let mode):
            if let media = router.media[key] { SendCropView(media: media, mode: mode) } else { Color.clear }
        case .draw(let mode): DrawScreen(mode: mode)
        case .write(let mode): WriteView(mode: mode)
        case .playlist: PlaylistView()
        case .settings: SettingsView()
        case .advanced: AdvancedSettingsView()
        }
    }
}

private struct ResendID: Identifiable { let id: String }

extension EnvironmentValues {
    /// The zoom-transition namespace for sheets that open from the thing tapped.
    @Entry var zoomNamespace: Namespace.ID?
}

extension View {
    /// Marks a view as the source of a zoom transition (an Extra card → its sheet).
    @ViewBuilder func zoomSource(_ id: String, _ ns: Namespace.ID?) -> some View {
        if let ns { matchedTransitionSource(id: id, in: ns) } else { self }
    }
}

/// "Sent · Undo" and friends, floating at the bottom.
struct ToastView: View {
    let toast: Toast
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: toast.systemImage).foregroundStyle(Color.accentColor).accessibilityHidden(true)
            Text(toast.text).font(.subheadline.weight(.semibold)).foregroundStyle(Z2.text)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let undo = toast.undo {
                Button {
                    dismiss()
                    undo()
                } label: {
                    Text("Undo").font(.subheadline.weight(.bold)).frame(minWidth: 44, minHeight: 36)
                }
                .buttonStyle(Z2Press())
                .accessibilityIdentifier("toastUndo")
            }
        }
        .padding(.leading, 18).padding(.trailing, toast.undo == nil ? 18 : 10).padding(.vertical, 8)
        .frame(minHeight: 48)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 20)
        .onTapGesture { if toast.undo == nil { dismiss() } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("toast")
    }
}
