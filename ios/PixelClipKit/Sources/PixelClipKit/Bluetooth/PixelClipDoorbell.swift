import Foundation
import Observation

// MARK: - Public vocabulary

/// Why a doorbell ring didn't wake the clip.
public enum DoorbellFailure: Equatable, Sendable {
    /// Bluetooth is off (or this device has none, e.g. the simulator).
    case bluetoothOff
    /// The person hasn't allowed Bluetooth for PixelClip.
    case unauthorized
    /// No `PixelClip-…` peripheral answered within the scan window (8 s), or it vanished mid-way.
    case notFound
    /// The clip's battery is too low to start Wi‑Fi (it would refuse the wake).
    case lowBattery
    /// The `wake` write was refused, or the peripheral isn't a doorbell-capable PixelClip.
    case writeFailed
}

/// `idle → scanning → found(name, rssi) → waking → accepted → hotspotUp`, or `→ failed(reason)`.
public enum DoorbellState: Equatable, Sendable {
    case idle
    case scanning
    case found(name: String, rssi: Int)
    case waking
    /// The clip acknowledged the wake write: its access point is starting (joining can begin).
    case accepted
    case hotspotUp
    case failed(DoorbellFailure)

    public var isFinal: Bool {
        switch self {
        case .hotspotUp, .failed: true
        default: false
        }
    }
}

/// The clip as last heard over Bluetooth (the Clip tab's "Nearby · 64 %").
public struct DoorbellNearby: Equatable, Sendable {
    public var name: String
    public var rssi: Int
    public var status: PixelClipBLEStatus?
    public var info: PixelClipBLEInfo?
    /// The BLE link is up (status notifications arrive; `0x02` can end a session).
    public var linked: Bool
    public var seenAt: Date

    public init(name: String, rssi: Int, status: PixelClipBLEStatus? = nil, info: PixelClipBLEInfo? = nil, linked: Bool = false, seenAt: Date = Date()) {
        self.name = name; self.rssi = rssi; self.status = status; self.info = info; self.linked = linked; self.seenAt = seenAt
    }
}

/// What the app needs from a doorbell: the real one (`PixelClipDoorbell`, CoreBluetooth) or the
/// simulator's (`VirtualDoorbell`).
@MainActor
public protocol DoorbellRinging: AnyObject {
    var state: DoorbellState { get }
    var nearby: DoorbellNearby? { get }
    /// True when a scan won't trigger the system permission prompt (already allowed). Background
    /// peeks only run then; the first Connect asks.
    var canScanSilently: Bool { get }
    /// Scan, connect, write `0x01`, wait for the session flag, disconnect. The stream ends after
    /// `hotspotUp` or `failed`.
    func wake() -> AsyncStream<DoorbellState>
    /// A short look (scan ≤ 4 s, connect, read status and info). The link stays up for
    /// notifications until `release()`.
    func peek() async
    /// Writes `0x02` over a live link. False when there's no link (use HTTP `/session/end`).
    func endSession() async -> Bool
    /// Stop scanning and drop the link (Clip tab hidden, app in the background, Wi‑Fi joined).
    func release()
    /// The BLE fast lane (PROTOCOL §3b) over the doorbell's link: links to the nearby clip first if
    /// needed (scan, connect, discover). Nil when it can't be reached, or its firmware has no fast lane.
    func fastLaneLink() async -> (any FastLaneLink)?
    /// The link is up and carries the fast lane (quick actions can go over Bluetooth).
    var fastLaneLinked: Bool { get }
    /// One plain line per step (scan, heard, linked, wake, not heard…), for the app's send log.
    var onLog: (@MainActor (String) -> Void)? { get set }
}

public extension DoorbellRinging {
    func fastLaneLink() async -> (any FastLaneLink)? { nil }
    var fastLaneLinked: Bool { false }
}

// MARK: - Radio (CoreBluetooth, or a fake in tests)

public enum DoorbellRadioState: Equatable, Sendable {
    case unknown, resetting, unsupported, unauthorized, poweredOff, poweredOn
}

public enum DoorbellAuthorization: Equatable, Sendable {
    case notDetermined, denied, allowed
}

/// What the radio reports. Identifiers are the peripheral's `identifier`.
public enum DoorbellEvent: Equatable, Sendable {
    case radio(DoorbellRadioState)
    case discovered(id: UUID, name: String?, rssi: Int, serviceUUIDs: [String])
    case connected(UUID)
    case connectFailed(UUID)
    /// Service and `wake`/`status` (and `info`, if present) characteristics found.
    case ready(UUID)
    /// Connected, but it isn't a doorbell-capable PixelClip.
    case missingCharacteristics(UUID)
    /// A `wake` write's response: `attError` nil = accepted, else the ATT error code
    /// (`PixelClipBLE.attErrorLowBattery` for a low-battery refusal).
    case wrote(UUID, command: UInt8, attError: Int?)
    case status(UUID, Data)
    case info(UUID, Data)
    case disconnected(UUID)
}

/// The radio primitives `PixelClipDoorbell` drives. Calls are fire-and-forget; results arrive as events
/// on `onEvent` (always on the main actor, never re-entrantly from inside a call).
@MainActor
public protocol DoorbellRadio: AnyObject {
    var onEvent: ((DoorbellEvent) -> Void)? { get set }
    /// Current permission, read without prompting.
    var authorization: DoorbellAuthorization { get }
    /// Bring the radio up (may show the permission prompt); reports `.radio(_)`.
    func activate()
    func scan()
    func stopScan()
    func connect(_ id: UUID)
    /// Cancel a connection or pending connect.
    func disconnect(_ id: UUID)
    func write(_ command: UInt8, to id: UUID)
    func subscribeStatus(_ id: UUID)
    func readStatus(_ id: UUID)
    func readInfo(_ id: UUID)
    /// The fast-lane link of a connected peripheral whose `req`/`rsp` characteristics were found.
    func fastLaneLink(for id: UUID) -> (any FastLaneLink)?
}

public extension DoorbellRadio {
    func fastLaneLink(for id: UUID) -> (any FastLaneLink)? { nil }
}

/// Every wait in the flow. `standard` matches the brief: 8 s to find the clip.
public struct DoorbellTimings: Sendable {
    public var scan: Duration
    public var peekScan: Duration
    public var connect: Duration
    public var firstStatus: Duration
    public var confirm: Duration
    public var radio: Duration
    public var endWrite: Duration

    public init(scan: Duration = .seconds(8), peekScan: Duration = .seconds(4), connect: Duration = .seconds(6),
                firstStatus: Duration = .seconds(2), confirm: Duration = .seconds(10), radio: Duration = .seconds(30),
                endWrite: Duration = .seconds(3)) {
        self.scan = scan; self.peekScan = peekScan; self.connect = connect; self.firstStatus = firstStatus
        self.confirm = confirm; self.radio = radio; self.endWrite = endWrite
    }

    public static let standard = DoorbellTimings()
}

// MARK: - The doorbell

/// Rings the clip over Bluetooth LE. One flow at a time; a wake takes over a running peek (and
/// reuses its link). Scanning only happens while the app asks (foreground), never in the background.
@MainActor @Observable
public final class PixelClipDoorbell: DoorbellRinging {
    public private(set) var state: DoorbellState = .idle
    public private(set) var nearby: DoorbellNearby?

    private enum Goal { case wake, peek }
    private enum Phase: Equatable {
        case none
        case waitingRadio
        case scanning
        case connecting(UUID)
        case discovering(UUID)
        case reading(UUID)
        case writing(UUID)
        case confirming(UUID)
        case linked(UUID)

        var label: String {
            switch self {
            case .none: "idle"
            case .waitingRadio: "radio starting"
            case .scanning: "scanning"
            case .connecting: "connecting"
            case .discovering: "discovering"
            case .reading: "reading status"
            case .writing: "writing"
            case .confirming: "confirming"
            case .linked: "linked"
            }
        }
    }

    @ObservationIgnored private let radio: any DoorbellRadio
    @ObservationIgnored private let timings: DoorbellTimings
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var radioState: DoorbellRadioState = .unknown
    @ObservationIgnored private var activated = false
    @ObservationIgnored private var goal: Goal?
    @ObservationIgnored private var phase: Phase = .none
    @ObservationIgnored private var wakeContinuation: AsyncStream<DoorbellState>.Continuation?
    @ObservationIgnored private var peekWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var endWaiter: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var timerGeneration = 0
    @ObservationIgnored private var endTimer: Task<Void, Never>?
    /// A peek is checking that a link it found up still answers (else it drops it and scans).
    @ObservationIgnored private var verifying = false
    @ObservationIgnored public var onLog: (@MainActor (String) -> Void)?

    private func log(_ s: String) { onLog?("bluetooth: " + s) }

    public init(radio: any DoorbellRadio, timings: DoorbellTimings = .standard, now: @escaping @Sendable () -> Date = { Date() }) {
        self.radio = radio
        self.timings = timings
        self.now = now
        radio.onEvent = { [weak self] e in self?.handle(e) }
    }

    public var canScanSilently: Bool { radio.authorization == .allowed }

    private var linkedID: UUID? { if case .linked(let id) = phase { id } else { nil } }

    // MARK: Flows

    public func wake() -> AsyncStream<DoorbellState> {
        let (stream, continuation) = AsyncStream.makeStream(of: DoorbellState.self)
        if goal == .wake {
            // Already ringing: this caller just gets the end of it.
            continuation.yield(state)
            continuation.finish()
            return stream
        }
        if goal == .peek { resumePeekWaiters() }
        verifying = false
        wakeContinuation = continuation
        goal = .wake
        log("wake requested (\(phase.label))")
        switch phase {
        case .linked(let id):
            // A peek left the link up (the Clip tab's Nearby poll): no scan, no connect, and no status
            // read either — its status notifications keep `nearby.status` current, so write at once.
            // (A stale "asleep" costs nothing: the clip answers an already-active wake as accepted and
            // refuses a low-battery one with ATT 0x80. A cached "awake" is re-read: skipping the write
            // on a stale one would leave the Wi‑Fi off.)
            if let n = nearby { emit(.found(name: n.name, rssi: n.rssi)) }
            if let cached = nearby?.status, !cached.sessionActive { decide(id, status: cached) } else { readFirstStatus(id) }
        case .scanning:
            emit(.scanning)
            arm(timings.scan)
        case .connecting, .discovering, .reading:
            if let n = nearby { emit(.found(name: n.name, rssi: n.rssi)) }
            if case .reading(let id) = phase { readFirstStatus(id) }
        default:
            begin()
        }
        return stream
    }

    public func peek() async {
        guard goal == nil else {
            log("look skipped: busy (\(goal == .wake ? "waking" : "looking"))")
            return
        }
        if let id = linkedID {
            // Already linked: check the link still answers. A dead one (the clip restarted, iOS kept a
            // stale connection) would otherwise stop every later look from scanning: drop it and scan.
            goal = .peek
            verifying = true
            await withCheckedContinuation { c in
                peekWaiters.append(c)
                readFirstStatus(id)
            }
            return
        }
        guard canScanSilently else {
            log("look skipped: Bluetooth isn’t allowed yet")
            return
        }
        goal = .peek
        await withCheckedContinuation { c in
            peekWaiters.append(c)
            begin()
        }
    }

    public func endSession() async -> Bool {
        guard goal == nil, let id = linkedID, endWaiter == nil else { return false }
        return await withCheckedContinuation { c in
            endWaiter = c
            radio.write(PixelClipBLE.endCommand, to: id)
            endTimer = Task { [weak self, endWrite = timings.endWrite] in
                try? await Task.sleep(for: endWrite)
                guard !Task.isCancelled else { return }
                self?.resolveEnd(false)
            }
        }
    }

    public var fastLaneLinked: Bool { linkedID.flatMap { radio.fastLaneLink(for: $0) } != nil }

    /// Reuses the link a peek left up; otherwise runs the peek's scan + connect (this is a person's
    /// action, so the Bluetooth permission prompt may show), waiting for a peek already running. A
    /// wake in progress means Wi‑Fi is coming: no fast lane.
    public func fastLaneLink() async -> (any FastLaneLink)? {
        if let id = linkedID { return radio.fastLaneLink(for: id) }
        switch goal {
        case .wake?: return nil
        case .peek?: await withCheckedContinuation { peekWaiters.append($0) }
        case nil:
            guard radio.authorization != .denied else { return nil }
            goal = .peek
            await withCheckedContinuation { c in
                peekWaiters.append(c)
                begin()
            }
        }
        return linkedID.flatMap { radio.fastLaneLink(for: $0) }
    }

    public func release() {
        cancelTimer()
        radio.stopScan()
        if let id = currentPeripheral { radio.disconnect(id) }
        if goal == .wake { finishWake(.failed(.notFound)) }
        resumePeekWaiters()
        resolveEnd(false)
        goal = nil
        phase = .none
        nearby?.linked = false
        if !state.isFinal { state = .idle }
    }

    // MARK: Steps

    private func begin() {
        if goal == .wake {
            switch radio.authorization {
            case .denied: finishWake(.failed(.unauthorized)); return
            case .notDetermined, .allowed: break
            }
        }
        if !activated {
            activated = true
            log("turning the radio on")
            phase = .waitingRadio
            radio.activate()
            arm(timings.radio)
            return
        }
        switch radioState {
        case .poweredOn: startScan()
        case .poweredOff, .unsupported: stop(.bluetoothOff)
        case .unauthorized: stop(.unauthorized)
        case .unknown, .resetting:
            phase = .waitingRadio
            arm(timings.radio)
        }
    }

    private func startScan() {
        phase = .scanning
        log("scanning (\(goal == .wake ? "to wake" : "a look"), up to \(Int((goal == .wake ? timings.scan : timings.peekScan).components.seconds)) s)")
        if goal == .wake { emit(.scanning) }
        radio.scan()
        arm(goal == .wake ? timings.scan : timings.peekScan)
    }

    private func readFirstStatus(_ id: UUID) {
        phase = .reading(id)
        radio.readStatus(id)
        arm(timings.firstStatus)
    }

    /// The wake decision once the clip's status is known (or didn't come).
    private func decide(_ id: UUID, status: PixelClipBLEStatus?) {
        if let status, status.sessionActive { finishWake(.hotspotUp); return }
        if let status, status.tooLowToWake { finishWake(.failed(.lowBattery)); return }
        phase = .writing(id)
        emit(.waking)
        log("writing the wake (0x01)")
        radio.write(PixelClipBLE.wakeCommand, to: id)
        arm(timings.confirm)
    }

    private var currentPeripheral: UUID? {
        switch phase {
        case .connecting(let id), .discovering(let id), .reading(let id), .writing(let id), .confirming(let id), .linked(let id): id
        default: nil
        }
    }

    // MARK: Events

    func handle(_ e: DoorbellEvent) {
        switch e {
        case .radio(let s):
            radioState = s
            if s != .poweredOn {
                nearby?.linked = false
                if case .linked = phase { phase = .none }
            }
            guard goal != nil else { return }
            switch (phase, s) {
            case (.waitingRadio, .poweredOn): startScan()
            case (.waitingRadio, .unknown), (.waitingRadio, .resetting): break
            case (_, .poweredOn): break
            case (_, .unauthorized): stop(.unauthorized)
            case (_, .unknown), (_, .resetting):
                if phase != .waitingRadio { stop(.bluetoothOff) }
            default: stop(.bluetoothOff)
            }

        case .discovered(let id, let name, let rssi, let services):
            guard phase == .scanning, PixelClipBLE.matches(name: name, serviceUUIDs: services) else { return }
            let label = name ?? "PixelClip"
            // rssi 0: the radio found it among the peripherals already connected to this iPhone (it
            // doesn't advertise while a central holds it).
            log(rssi == 0 ? "found \(label) already connected to this iPhone (not advertising): using that link"
                          : "heard \(label) (\(rssi) dBm)")
            let previous = nearby
            nearby = DoorbellNearby(name: label, rssi: rssi, status: previous?.name == label ? previous?.status : nil,
                                    info: previous?.name == label ? previous?.info : nil, linked: false, seenAt: now())
            if goal == .wake { emit(.found(name: label, rssi: rssi)) }
            radio.stopScan()
            phase = .connecting(id)
            radio.connect(id)
            arm(timings.connect)

        case .connected(let id):
            guard phase == .connecting(id) else { return }
            phase = .discovering(id)   // the radio discovers the service and characteristics

        case .ready(let id):
            guard phase == .discovering(id) else { return }
            log("linked\(radio.fastLaneLink(for: id) == nil ? " (no fast lane on this firmware)" : " · fast lane ready")")
            nearby?.linked = true
            radio.subscribeStatus(id)
            radio.readInfo(id)
            readFirstStatus(id)

        case .missingCharacteristics(let id):
            guard currentPeripheral == id else { return }
            radio.disconnect(id)
            phase = .none
            nearby?.linked = false
            if goal == .wake { finishWake(.failed(.writeFailed)) } else { finishPeek() }

        case .connectFailed(let id):
            guard currentPeripheral == id else { return }
            log("couldn’t connect")
            phase = .none
            nearby?.linked = false
            if goal == .wake { finishWake(.failed(.notFound)) } else { finishPeek() }

        case .disconnected(let id):
            guard currentPeripheral == id else { return }
            log("link dropped")
            let was = phase
            phase = .none
            nearby?.linked = false
            resolveEnd(false)
            guard goal == .wake else { finishPeek(); return }
            // The clip may drop Bluetooth as its Wi‑Fi comes up: after an accepted wake that's success.
            if case .confirming = was { finishWake(.hotspotUp) } else { finishWake(.failed(.notFound)) }

        case .status(let id, let data):
            guard let s = PixelClipBLEStatus(data: data) else { return }
            if nearby != nil {
                nearby?.status = s
                nearby?.seenAt = now()
            }
            switch phase {
            case .reading(id):
                if goal == .wake { decide(id, status: s) } else {
                    if verifying { log("the link answers (\(s.sessionActive ? "Wi‑Fi on" : "Wi‑Fi off"))") }
                    settleLinked(id)
                }
            case .writing(id), .confirming(id):
                if s.sessionActive { finishWake(.hotspotUp) }
                else if case .confirming = phase, s.lastWake == .lowBattery { finishWake(.failed(.lowBattery)) }
            default: break
            }

        case .info(_, let data):
            if let info = PixelClipBLEInfo(data: data) { nearby?.info = info }

        case .wrote(let id, let command, let attError):
            if command == PixelClipBLE.endCommand { resolveEnd(attError == nil); return }
            guard command == PixelClipBLE.wakeCommand, phase == .writing(id) else { return }
            log(attError == nil ? "wake accepted" : "wake refused (ATT \(attError!))")
            switch attError {
            case nil:
                phase = .confirming(id)
                emit(.accepted)
                arm(timings.confirm)
            case PixelClipBLE.attErrorLowBattery?:
                finishWake(.failed(.lowBattery))
            default:
                finishWake(.failed(.writeFailed))
            }
        }
    }

    private func timedOut(_ generation: Int) {
        guard generation == timerGeneration else { return }
        switch phase {
        case .waitingRadio:
            stop(.bluetoothOff)
        case .scanning:
            phase = .none
            log("not heard (\(goal == .wake ? "wake" : "look") scan timed out)")
            if goal == .wake {
                finishWake(.failed(.notFound))
            } else {
                // Not heard this time: no longer nearby.
                radio.stopScan()
                nearby = nil
                finishPeek()
            }
        case .connecting(let id), .discovering(let id):
            radio.disconnect(id)
            phase = .none
            nearby?.linked = false
            if goal == .wake { finishWake(.failed(.notFound)) } else { finishPeek() }
        case .reading(let id):
            // No status came: wake anyway (the join step verifies), or keep the link for a peek — unless
            // the peek was checking an old link: then it's dead, drop it and scan.
            if goal == .wake { decide(id, status: nil) } else if verifying {
                log("the link doesn’t answer: dropping it and scanning")
                verifying = false
                radio.disconnect(id)
                nearby?.linked = false
                startScan()
            } else { settleLinked(id) }
        case .writing:
            finishWake(.failed(.writeFailed))
        case .confirming:
            // Accepted but no session flag yet: trust the write; joining the hotspot verifies.
            if nearby?.status?.tooLowToWake == true { finishWake(.failed(.lowBattery)) } else { finishWake(.hotspotUp) }
        case .linked, .none:
            break
        }
    }

    // MARK: Finishing

    private func stop(_ failure: DoorbellFailure) {
        log("stopped: \(failure)")
        cancelTimer()
        radio.stopScan()
        phase = .none
        if goal == .wake { finishWake(.failed(failure)) } else { finishPeek() }
    }

    private func settleLinked(_ id: UUID) {
        cancelTimer()
        phase = .linked(id)
        finishPeek()
    }

    private func finishPeek() {
        verifying = false
        if goal == .peek { goal = nil }
        resumePeekWaiters()
    }

    private func resumePeekWaiters() {
        let waiters = peekWaiters
        peekWaiters = []
        for w in waiters { w.resume() }
    }

    /// The wake is over: report, and drop the link either way (never hold Bluetooth during Wi‑Fi).
    private func finishWake(_ final: DoorbellState) {
        log("wake finished: \(final)")
        cancelTimer()
        radio.stopScan()
        if let id = currentPeripheral { radio.disconnect(id) }
        phase = .none
        nearby?.linked = false
        if final == .hotspotUp, var s = nearby?.status {
            s.flags.insert(.sessionActive)
            nearby?.status = s
        }
        goal = nil
        emit(final)
        wakeContinuation?.finish()
        wakeContinuation = nil
    }

    private func resolveEnd(_ ok: Bool) {
        endTimer?.cancel()
        endTimer = nil
        guard let w = endWaiter else { return }
        endWaiter = nil
        if ok, var s = nearby?.status {
            s.flags.remove(.sessionActive)
            nearby?.status = s
        }
        w.resume(returning: ok)
    }

    private func emit(_ s: DoorbellState) {
        state = s
        if goal == .wake || s.isFinal { wakeContinuation?.yield(s) }
    }

    private func arm(_ d: Duration) {
        timer?.cancel()
        timerGeneration += 1
        let g = timerGeneration
        timer = Task { [weak self] in
            try? await Task.sleep(for: d)
            guard !Task.isCancelled else { return }
            self?.timedOut(g)
        }
    }

    private func cancelTimer() {
        timer?.cancel()
        timer = nil
        timerGeneration += 1
    }
}

// MARK: - Fallback

/// How a connect continues after the doorbell.
public enum DoorbellOutcome: Equatable, Sendable {
    /// Bluetooth wake is off in Settings (or there's no doorbell): join as before.
    case disabled
    /// The clip's Wi‑Fi was already up (the phone reached it, or its status said so).
    case alreadyAwake
    /// The wake was accepted: join now (retrying while the access point starts).
    case woke
    /// Didn't work over Bluetooth: try to join anyway (the button may have been pressed), and on
    /// failure show the button instructions.
    case fallBack(DoorbellFailure)
    /// Don't try to join: the clip can't start Wi‑Fi (battery too low).
    case blocked(DoorbellFailure)

    /// The decision for a doorbell's final state.
    public static func from(_ final: DoorbellState) -> DoorbellOutcome {
        switch final {
        case .hotspotUp: .woke
        case .failed(.lowBattery): .blocked(.lowBattery)
        case .failed(let f): .fallBack(f)
        default: .fallBack(.notFound)
        }
    }

    /// Whether to join the hotspot next.
    public var shouldJoin: Bool { if case .blocked = self { false } else { true } }

    /// The button instructions are the way forward if the join then fails.
    public var usesButton: Bool { if case .fallBack = self { true } else { false } }

    /// The Bluetooth row's line in the send sheet.
    public var line: String {
        switch self {
        case .disabled: "Bluetooth wake is off in Settings"
        case .alreadyAwake: "Already awake"
        case .woke: "Awake · its Wi‑Fi is on"
        case .fallBack(.bluetoothOff): "Bluetooth is off · hold the clip’s button for two seconds instead"
        case .fallBack(.unauthorized): "Bluetooth isn’t allowed for PixelClip · hold the clip’s button for two seconds instead"
        case .fallBack(.writeFailed): "It didn’t take the wake-up · hold its button for two seconds"
        case .fallBack: "No answer over Bluetooth · hold its button for two seconds"
        case .blocked: "The battery is too low to turn on Wi‑Fi"
        }
    }
}
