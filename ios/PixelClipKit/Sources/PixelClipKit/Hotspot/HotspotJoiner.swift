import Foundation
import Observation
#if os(iOS)
import NetworkExtension
#endif

public enum HotspotDefaults {
    /// PROTOCOL §3: `PixelClip-XXXX` (ASCII), WPA2, default passphrase `pixelclip-2026`.
    public static let ssidPrefix = "PixelClip-"
    public static let password = "pixelclip-2026"
    public static let host = "192.168.4.1"
    public static let mdnsName = "pixelclip.local"
}

/// Joins a WiFi network by SSID prefix. Abstracted so the state machine can be tested and the
/// simulator (which has no NEHotspotConfigurationManager) can use a stand-in.
public protocol HotspotConfiguring: Sendable {
    /// - Parameter remember: install a remembered network (`joinOnce = false`): iOS asks to join only
    ///   the first time. False = join-once (iOS forgets it when the app stops using it).
    func join(ssidPrefix: String, passphrase: String, remember: Bool) async throws
    /// Remove a remembered network (Settings ▸ Forget Clip).
    func forget(ssidPrefix: String) async
}

public extension HotspotConfiguring {
    func forget(ssidPrefix: String) async {}
}

public enum HotspotJoinError: Error, Equatable, Sendable {
    case userDenied
    case invalidPassphrase
    case unavailable(String)
    /// The system refused to install a remembered configuration (the join-once fallback may work).
    case refused(String)
}

#if os(iOS)
/// The real thing: `NEHotspotConfiguration(ssidPrefix:passphrase:isWEP:)`, remembered (falls back
/// to join-once in `HotspotJoiner` when refused). Requires the
/// `com.apple.developer.networking.HotspotConfiguration` entitlement.
public struct SystemHotspotConfigurator: HotspotConfiguring {
    public init() {}

    public func join(ssidPrefix: String, passphrase: String, remember: Bool) async throws {
        let cfg = NEHotspotConfiguration(ssidPrefix: ssidPrefix, passphrase: passphrase, isWEP: false)
        cfg.joinOnce = !remember
        do {
            try await NEHotspotConfigurationManager.shared.apply(cfg)
        } catch let e as NSError where e.domain == NEHotspotConfigurationErrorDomain {
            switch NEHotspotConfigurationError(rawValue: e.code) {
            case .alreadyAssociated: return
            case .userDenied: throw HotspotJoinError.userDenied
            case .invalidWPAPassphrase: throw HotspotJoinError.invalidPassphrase
            case let code? where remember && Self.refusals.contains(code):
                throw HotspotJoinError.refused(e.localizedDescription)
            default: throw HotspotJoinError.unavailable(e.localizedDescription)
            }
        }
    }

    /// Errors that mean "not as a remembered network" rather than "no such network".
    static let refusals: Set<NEHotspotConfigurationError> = [.systemConfiguration, .invalid, .unknown, .joinOnceNotSupported]

    public func forget(ssidPrefix: String) async {
        let manager = NEHotspotConfigurationManager.shared
        // A prefix configuration is listed (and removed) under its prefix; full SSIDs too, to be sure.
        let ssids = await manager.configuredSSIDs()
        for ssid in Set(ssids.filter { $0.hasPrefix(ssidPrefix) } + [ssidPrefix]) {
            manager.removeConfiguration(forSSID: ssid)
        }
    }
}
#endif

/// Pretends to join instantly (simulator / virtual clip / tests).
public struct ImmediateHotspotConfigurator: HotspotConfiguring {
    public let error: HotspotJoinError?
    public init(error: HotspotJoinError? = nil) { self.error = error }
    public func join(ssidPrefix: String, passphrase: String, remember: Bool) async throws {
        if let error { throw error }
    }
}

/// `notJoined → (waking →) joining → joined`, or `→ unreachable` when the network can't be joined or
/// the clip doesn't answer `GET /status` after joining. `waking` is the Bluetooth doorbell.
public enum HotspotState: Equatable, Sendable {
    case notJoined
    /// Ringing the clip over Bluetooth so it turns its Wi‑Fi on.
    case waking
    case joining
    case joined
    case unreachable(String)

    public var isJoined: Bool { self == .joined }
}

/// Why the last `connect()` didn't end up talking to the clip (for the app's copy, never shown raw).
public enum JoinFailure: Equatable, Sendable {
    /// The person tapped Cancel on iOS's "join PixelClip-…" prompt.
    case declined
    /// iOS joined nothing because the stored hotspot password doesn't match the clip's.
    case wrongPassword
    /// No `PixelClip-…` network in range (the clip's Wi‑Fi isn't on).
    case notFound
    /// Joined, but the clip never answered `GET /status`.
    case noAnswer
    /// The doorbell said the battery is too low for Wi‑Fi (nothing was joined).
    case lowBattery
}

@MainActor @Observable
public final class HotspotJoiner {
    public private(set) var state: HotspotState = .notJoined
    /// Last error worth showing (permission denied, wrong password…).
    public private(set) var message: String?
    /// Why the last connect failed (nil after a success or before any attempt).
    public private(set) var failure: JoinFailure?

    public var ssidPrefix: String
    public var passphrase: String

    /// Ring the clip over Bluetooth before joining (Settings ▸ Bluetooth Wake). Needs `doorbell`.
    public var bluetoothWake = true
    /// Join as a remembered network (`joinOnce = false`) so iOS asks only the first time; join-once
    /// when the system refuses (then for the rest of the app's life).
    public var rememberNetwork = true
    /// The doorbell's latest state while waking (for progress copy).
    public private(set) var doorbellState: DoorbellState = .idle
    /// How the last wake went (nil before any, or when the last connect didn't ring).
    public private(set) var lastWake: DoorbellOutcome?
    /// Whether the last successful join used a remembered configuration (nil: none yet).
    public private(set) var lastJoinRemembered: Bool?
    /// The system refused the remembered configuration once: joins are join-once from now on.
    public private(set) var rememberRefused = false
    /// Configurator calls in the last join (retries while the access point starts count too).
    public private(set) var joinAttempts = 0

    @ObservationIgnored public var doorbell: (any DoorbellRinging)?
    @ObservationIgnored private let configurator: any HotspotConfiguring
    @ObservationIgnored private let probe: @Sendable () async -> Bool
    @ObservationIgnored private let probeAttempts: Int
    @ObservationIgnored private let probeInterval: Duration
    @ObservationIgnored private let joinRetryInterval: Duration
    @ObservationIgnored private let wakeJoinWindow: Duration

    /// - Parameters:
    ///   - probe: returns true when `GET /status` succeeds.
    ///   - probeAttempts/probeInterval: DHCP on the clip's SoftAP takes a moment after joining,
    ///     so the first probes are expected to fail.
    ///   - joinRetryInterval/wakeJoinWindow: after a Bluetooth wake the access point takes a moment to
    ///     start, so joins are retried every `joinRetryInterval` for up to `wakeJoinWindow`.
    public init(configurator: any HotspotConfiguring, ssidPrefix: String = HotspotDefaults.ssidPrefix,
                passphrase: String = HotspotDefaults.password, probeAttempts: Int = 10,
                probeInterval: Duration = .milliseconds(800), doorbell: (any DoorbellRinging)? = nil,
                joinRetryInterval: Duration = .milliseconds(500), wakeJoinWindow: Duration = .seconds(12),
                probe: @escaping @Sendable () async -> Bool) {
        self.configurator = configurator
        self.doorbell = doorbell
        self.joinRetryInterval = joinRetryInterval
        self.wakeJoinWindow = wakeJoinWindow
        self.ssidPrefix = ssidPrefix
        self.passphrase = passphrase
        self.probe = probe
        self.probeAttempts = max(1, probeAttempts)
        self.probeInterval = probeInterval
    }

    /// Wake the clip over Bluetooth (when enabled) and join; see `wakeAndJoin`.
    @discardableResult
    public func connect() async -> HotspotState {
        await wakeAndJoin()
    }

    /// Wake over Bluetooth and join its Wi‑Fi, overlapped: the `GET /status` probe runs alongside the
    /// ring (already on the clip's Wi‑Fi → done), and join attempts start as soon as the clip
    /// acknowledges the wake write (every `joinRetryInterval`, up to `wakeJoinWindow`) instead of
    /// after its `session_active` flag. Without an answer over Bluetooth the join is still tried (the
    /// button may have been pressed); a failure then carries the usual button instructions. Low
    /// battery stops before joining.
    /// - Parameters:
    ///   - onState: every doorbell state.
    ///   - onWake: the doorbell's outcome, as soon as it's known.
    ///   - onJoinStart: the first join attempt is about to start.
    @discardableResult
    public func wakeAndJoin(onState: ((DoorbellState) -> Void)? = nil, onWake: ((DoorbellOutcome) -> Void)? = nil,
                            onJoinStart: (() -> Void)? = nil) async -> HotspotState {
        if state == .joining || state == .waking { return state }
        message = nil
        failure = nil
        lastWake = nil
        guard bluetoothWake, let doorbell else {
            onWake?(.disabled)
            onJoinStart?()
            return await join()
        }
        state = .waking
        doorbellState = .idle
        // The probe answers at once when the phone is already on the clip's Wi‑Fi, but costs its whole
        // timeout otherwise: run it alongside the ring rather than before it. A hit ends the ring.
        let hit = ProbeHit()
        let probeTask = Task { @MainActor [probe] () -> Bool in
            guard !Task.isCancelled, await probe(), !Task.isCancelled else { return false }
            hit.value = true
            doorbell.release()
            return true
        }
        var joinTask: Task<HotspotState, Never>?
        var final: DoorbellState = .failed(.notFound)
        for await s in doorbell.wake() {
            doorbellState = s
            onState?(s)
            final = s
            if s == .accepted || s == .hotspotUp, joinTask == nil, !hit.value {
                // The wake was acknowledged: join now, while the access point starts.
                probeTask.cancel()
                onJoinStart?()
                joinTask = Task { @MainActor in await self.joinLoop(window: self.wakeJoinWindow) }
            }
        }
        // Without an acknowledged wake the probe decides whether the clip was already reachable.
        let reachable = joinTask == nil ? await probeTask.value : hit.value
        if reachable {
            joinTask?.cancel()
            lastWake = .alreadyAwake
            onWake?(.alreadyAwake)
            state = .joined
            return state
        }
        let outcome = DoorbellOutcome.from(final)
        lastWake = outcome
        onWake?(outcome)
        if case .blocked = outcome {
            joinTask?.cancel()
            failure = .lowBattery
            message = "The battery is too low to turn on Wi‑Fi."
            state = .unreachable(message!)
            return state
        }
        if let joinTask { return await joinTask.value }
        onJoinStart?()
        return await joinLoop(window: outcome == .woke ? wakeJoinWindow : .zero)
    }

    /// The doorbell step alone: probe first (already on the clip's Wi‑Fi → `alreadyAwake`), then
    /// ring. `onState` sees every doorbell state.
    @discardableResult
    public func wake(onState: ((DoorbellState) -> Void)? = nil) async -> DoorbellOutcome {
        message = nil
        failure = nil
        lastWake = nil
        guard bluetoothWake, let doorbell else { return .disabled }
        if await probe() {
            state = .joined
            lastWake = .alreadyAwake
            return .alreadyAwake
        }
        state = .waking
        var final: DoorbellState = .failed(.notFound)
        doorbellState = .idle
        for await s in doorbell.wake() {
            doorbellState = s
            onState?(s)
            final = s
        }
        let outcome = DoorbellOutcome.from(final)
        lastWake = outcome
        if case .blocked = outcome {
            failure = .lowBattery
            message = "The battery is too low to turn on Wi‑Fi."
            state = .unreachable(message!)
        } else {
            state = .notJoined
        }
        return outcome
    }

    /// Join (if needed) and confirm the clip answers.
    /// - Parameters:
    ///   - probeFirst: check whether the clip already answers before asking iOS to join.
    ///   - retryFor: keep retrying (every `joinRetryInterval`) while no `PixelClip-…` network is found yet,
    ///     for this long (right after a Bluetooth wake the access point takes a moment to start).
    @discardableResult
    public func join(probeFirst: Bool = true, retryFor window: Duration = .zero) async -> HotspotState {
        if state == .joining { return state }
        message = nil
        failure = nil
        // Already on the clip's network (e.g. joined from Settings)? Skip the join prompt.
        if probeFirst, await probe() { state = .joined; return state }
        return await joinLoop(window: window)
    }

    /// Join attempts (retrying "not found" until `window` has passed), then the probes. A cancelled
    /// loop (the wake turned out blocked, or the clip was already reachable) leaves `state` alone.
    private func joinLoop(window: Duration) async -> HotspotState {
        state = .joining
        joinAttempts = 0
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: window)
        while true {
            do {
                try await attemptJoin()
                break
            } catch HotspotJoinError.unavailable(_) where clock.now < deadline {
                if Task.isCancelled { return state }
                try? await Task.sleep(for: joinRetryInterval)
                if Task.isCancelled { return state }
            } catch {
                if Task.isCancelled { return state }
                return joinFailed(error)
            }
        }
        if Task.isCancelled { return state }
        for attempt in 0..<probeAttempts {
            if await probe() {
                if Task.isCancelled { return state }
                state = .joined
                return state
            }
            if Task.isCancelled { return state }
            if attempt < probeAttempts - 1 { try? await Task.sleep(for: probeInterval) }
        }
        failure = .noAnswer
        state = .unreachable("The clip isn’t answering.")
        return state
    }

    /// One configurator call: remembered first, join-once if the system refuses that.
    private func attemptJoin() async throws {
        joinAttempts += 1
        let remember = rememberNetwork && !rememberRefused
        do {
            try await configurator.join(ssidPrefix: ssidPrefix, passphrase: passphrase, remember: remember)
            lastJoinRemembered = remember
        } catch HotspotJoinError.refused(_) where remember {
            rememberRefused = true
            try await configurator.join(ssidPrefix: ssidPrefix, passphrase: passphrase, remember: false)
            lastJoinRemembered = false
        }
    }

    /// Settings ▸ Forget Clip: remove the remembered network (iOS asks to join again next time).
    public func forgetNetwork() async {
        await configurator.forget(ssidPrefix: ssidPrefix)
        lastJoinRemembered = nil
        rememberRefused = false
        markDisconnected()
    }

    private func joinFailed(_ error: any Error) -> HotspotState {
        if let e = error as? HotspotJoinError {
            switch e {
            case .userDenied:
                message = "Joining was cancelled."
                failure = .declined
                state = .notJoined
            case .invalidPassphrase:
                message = "The hotspot password was rejected."
                failure = .wrongPassword
                state = .unreachable(message!)
            case .unavailable(let s), .refused(let s):
                message = s
                failure = .notFound
                state = .unreachable("Couldn’t find a \(ssidPrefix)… network.")
            }
            return state
        }
        failure = .notFound
        state = .unreachable(error.localizedDescription)
        return state
    }

    /// Re-check reachability without joining.
    @discardableResult
    public func refresh() async -> HotspotState {
        guard state != .joining, state != .waking else { return state }
        state = await probe() ? .joined : (state == .joined ? .unreachable("The clip stopped answering.") : state)
        return state
    }

    /// Forget the connection (after `POST /session/end` the clip turns its WiFi off).
    public func markDisconnected() {
        state = .notJoined
        message = nil
        failure = nil
    }
}

/// The probe that runs alongside a ring found the clip already reachable.
@MainActor
private final class ProbeHit {
    var value = false
}
