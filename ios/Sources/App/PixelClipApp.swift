import SwiftUI
import PixelClipKit

@main
struct PixelClipApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var library: LibraryStore
    @State private var session: ClipSession
    @State private var router: Router
    @State private var sender: Sender
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let library = LibraryStore(), session = ClipSession(), router = Router()
        _library = State(initialValue: library)
        _session = State(initialValue: session)
        _router = State(initialValue: router)
        let sender = Sender(session: session, library: library, router: router)
        _sender = State(initialValue: sender)
        // The model's quiet sends (Undo, playlist edits) go through the app's Sender: same toasts, same
        // "will send when the clip is near".
        ClipSender.shared.attach(session: session, library: library)
        NowOnClip.shared.send = { sender.send(.playlist, kind: .quiet) }
    }

    var body: some Scene {
        WindowGroup {
            AppRoot()
                .environment(library)
                .environment(session)
                .environment(router)
                .environment(sender)
                .task {
                    await DemoContent.applyLaunchArguments(library: library, session: session, router: router, sender: sender)
                    // Oracles made the older ways (a text asset, fonts without their size) are remade the §5f.3 way;
                    // after the launch arguments, so a first screen never waits on it.
                    await TarotMaker.upgrade(library: library)
                }
        }
        .onChange(of: scenePhase) { _, phase in
            sender.isActive = phase == .active
            if phase == .active {
                // What the Share Extension saved: a photo or video opens in Send, a text in the Reader.
                ShareInbox.collect(router: router)
                // A send that was waiting for the clip.
                Task { await sender.retryIfNear() }
            }
            // Never hold Bluetooth in the background (a send's fast-lane link included).
            if phase == .background {
                session.releaseBluetooth()
            }
        }
    }
}
