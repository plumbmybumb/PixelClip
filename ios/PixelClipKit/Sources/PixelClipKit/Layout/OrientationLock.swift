import Foundation
import Observation

/// Interface orientations, without UIKit (the app maps them to `UIInterfaceOrientationMask`).
public struct InterfaceOrientations: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let portrait = InterfaceOrientations(rawValue: 1 << 0)
    public static let landscapeLeft = InterfaceOrientations(rawValue: 1 << 1)
    public static let landscapeRight = InterfaceOrientations(rawValue: 1 << 2)
    public static let portraitUpsideDown = InterfaceOrientations(rawValue: 1 << 3)

    public static let landscape: InterfaceOrientations = [.landscapeLeft, .landscapeRight]
    /// Portrait plus both landscapes (never upside down on iPhone).
    public static let portraitAndLandscape: InterfaceOrientations = [.portrait, .landscapeLeft, .landscapeRight]
}

/// The screens that may turn sideways. Everything else is portrait.
public enum OrientationScreen: String, Sendable, CaseIterable {
    /// Draw & Animate: landscape gives the canvas a bigger integer zoom.
    case draw
    /// Text & Marquee and Quick Cards: preview left, controls right.
    case text, cards

    public var orientations: InterfaceOrientations { .portraitAndLandscape }
}

/// Which orientations the app allows right now. Screens claim orientations while they're on screen
/// (`claim` on appear, `release` on disappear); the most recent claim wins, and with no claims the
/// app is portrait. The app delegate's `supportedInterfaceOrientationsFor:` returns `mask`, and
/// `onChange` asks UIKit to re-read it (`setNeedsUpdateOfSupportedInterfaceOrientations`). Releasing
/// the last claim while the phone is held sideways lets iOS rotate back to portrait itself.
@MainActor @Observable
public final class OrientationLock {
    public static let shared = OrientationLock()

    public struct Token: Hashable, Sendable {
        fileprivate let id = UUID()
    }

    /// What the app supports with nothing claimed.
    public let base: InterfaceOrientations
    public private(set) var mask: InterfaceOrientations
    /// Called after `mask` changes (never for a claim or release that leaves it the same).
    @ObservationIgnored public var onChange: (@MainActor (InterfaceOrientations) -> Void)?
    @ObservationIgnored private var claims: [(token: Token, orientations: InterfaceOrientations)] = []

    public init(base: InterfaceOrientations = .portrait) {
        self.base = base
        mask = base
    }

    /// Claim orientations for a screen; keep the token and release it when the screen goes away.
    @discardableResult
    public func claim(_ orientations: InterfaceOrientations) -> Token {
        let token = Token()
        claims.append((token, orientations))
        update()
        return token
    }

    @discardableResult
    public func claim(_ screen: OrientationScreen) -> Token { claim(screen.orientations) }

    /// Releasing is order-independent: SwiftUI may deliver the old screen's `onDisappear` after the
    /// new one's `onAppear`. Unknown or already-released tokens are ignored.
    public func release(_ token: Token) {
        claims.removeAll { $0.token == token }
        update()
    }

    /// Whether the current mask allows landscape (the "Rotate" affordances only show when it does).
    public var allowsLandscape: Bool { !mask.isDisjoint(with: .landscape) }

    private func update() {
        let next = claims.last.map { $0.orientations.isEmpty ? base : $0.orientations } ?? base
        guard next != mask else { return }
        mask = next
        onChange?(next)
    }
}
