import SwiftUI
import UIKit
import PixelClipKit

/// The app delegate exists for one thing: per-screen orientation. Info.plist declares portrait and
/// both landscapes; this narrows them to what `OrientationLock` allows right now (portrait unless
/// Draw is on screen).
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        OrientationLock.shared.onChange = { _ in Orientation.refreshSupportedOrientations() }
        return true
    }

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationLock.shared.mask.uiMask
    }
}

extension InterfaceOrientations {
    var uiMask: UIInterfaceOrientationMask {
        var m: UIInterfaceOrientationMask = []
        if contains(.portrait) { m.insert(.portrait) }
        if contains(.landscapeLeft) { m.insert(.landscapeLeft) }
        if contains(.landscapeRight) { m.insert(.landscapeRight) }
        if contains(.portraitUpsideDown) { m.insert(.portraitUpsideDown) }
        return m.isEmpty ? .portrait : m
    }
}

@MainActor
enum Orientation {
    private static var scenes: [UIWindowScene] {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    }

    /// Tell UIKit the supported orientations changed. When landscape goes away while the phone is
    /// sideways, iOS rotates back to portrait with its own animation.
    ///
    /// Never in the middle of a navigation push or pop: re-reading orientations then leaves the tab
    /// bar hidden after an editor (which hides it) is popped. A running transition defers the
    /// update to its completion.
    static func refreshSupportedOrientations() {
        let controllers = allViewControllers()
        if let coordinator = controllers.lazy.compactMap(\.transitionCoordinator).first,
           coordinator.animate(alongsideTransition: nil, completion: { _ in
               Task { @MainActor in refreshSupportedOrientations() }
           }) {
            return
        }
        for vc in controllers { vc.setNeedsUpdateOfSupportedInterfaceOrientations() }
    }

    /// Every view controller in every window: roots, their children and anything presented.
    private static func allViewControllers() -> [UIViewController] {
        var out: [UIViewController] = []
        func visit(_ vc: UIViewController) {
            out.append(vc)
            vc.children.forEach(visit)
            if let presented = vc.presentedViewController, presented.presentingViewController === vc { visit(presented) }
        }
        for scene in scenes { for window in scene.windows { if let root = window.rootViewController { visit(root) } } }
        return out
    }

    /// Turn the interface sideways on request (the "Rotate for a bigger canvas" affordance). Never
    /// called automatically; does nothing unless the screen on top allows landscape.
    static func requestLandscape() {
        guard OrientationLock.shared.allowsLandscape else { return }
        request(.landscape)
    }

    /// Back to portrait (the rail's button in landscape).
    static func requestPortrait() { request(.portrait) }

    private static func request(_ mask: UIInterfaceOrientationMask) {
        refreshSupportedOrientations()
        for scene in scenes where scene.activationState == .foregroundActive || scene.activationState == .foregroundInactive {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
        }
    }
}

/// Lets a screen turn sideways while it's on screen (claims on appear, releases on disappear).
private struct OrientationClaim: ViewModifier {
    let screen: OrientationScreen
    @State private var token: OrientationLock.Token?

    func body(content: Content) -> some View {
        content
            .onAppear {
                if let token { OrientationLock.shared.release(token) }
                token = OrientationLock.shared.claim(screen)
            }
            .onDisappear {
                if let token { OrientationLock.shared.release(token) }
                token = nil
            }
            #if DEBUG
            .task {
                // Screenshots: turn sideways once the screen is up (as "Rotate for a bigger canvas" does).
                guard ProcessInfo.processInfo.arguments.contains("-PixelClipLandscape") else { return }
                try? await Task.sleep(for: .milliseconds(600))
                Orientation.requestLandscape()
            }
            #endif
    }
}

extension View {
    /// This screen may rotate to landscape; the rest of the app stays portrait.
    func allowsLandscape(_ screen: OrientationScreen) -> some View { modifier(OrientationClaim(screen: screen)) }
}
