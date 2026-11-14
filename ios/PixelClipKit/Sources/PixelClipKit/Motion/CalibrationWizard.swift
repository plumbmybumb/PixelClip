import Foundation

/// Why a calibration step didn't go through, in words (from the clip's 422/409 codes).
public enum CalibrationProblem: Equatable, Sendable {
    /// 422 `not_still`: it moved during the half-second reading.
    case notStill
    /// 422 `ambiguous_pose`: not ~1 g along one axis (tilted).
    case ambiguousPose
    /// 422 `calibration_failed`: both readings on the same chip axis; both captures are discarded.
    case calibrationFailed
    /// 409 `no_imu` (or `GET /imu` says `present:false`).
    case noIMU
    /// 404: firmware without the calibration endpoint (or without the scene engine).
    case unsupported
    /// The clip stopped answering.
    case lostConnection
    case other

    public init(_ error: any Error) {
        if let e = error as? ClipError {
            switch e {
            case .http(let status, let env):
                switch (status, env?.error) {
                case (_, "not_still"?): self = .notStill
                case (_, "ambiguous_pose"?): self = .ambiguousPose
                case (_, "calibration_failed"?): self = .calibrationFailed
                case (_, "no_imu"?), (409, _): self = .noIMU
                case (404, _): self = .unsupported
                default: self = .other
                }
            case .unreachable: self = .lostConnection
            default: self = .other
            }
        } else if error is URLError {
            self = .lostConnection
        } else {
            self = .other
        }
    }

    /// Nothing to retry: the wizard can only be closed.
    public var isFinal: Bool { self == .noIMU || self == .unsupported }

    public var title: String {
        switch self {
        case .notStill: "PixelClip moved"
        case .ambiguousPose: "Not quite straight"
        case .calibrationFailed: "Both positions looked the same"
        case .noIMU: "No motion sensor answered"
        case .unsupported: "Update PixelClip first"
        case .lostConnection: "Lost the connection"
        case .other: "That didn’t work"
        }
    }

    public func message(for step: CalibrationWizard.Step) -> String {
        switch self {
        case .notStill:
            "Keep it still until the check mark: it measures for half a second after the countdown."
        case .ambiguousPose:
            step == .faceUp ? "Lay it flat on a table, screen up, so it isn’t leaning on anything."
                            : "Hold it straight up with the screen facing you, not tilted to either side."
        case .calibrationFailed:
            "Let’s do both again: first upright, then flat on its back."
        case .noIMU:
            "PixelClip didn’t find its motion sensor. Scenes still play, with down fixed to the bottom of the screen."
        case .unsupported:
            "This firmware can’t calibrate the motion sensor. Update it from Settings ▸ Update Firmware…"
        case .lostConnection:
            "PixelClip stopped answering. Bring your iPhone closer and try again."
        case .other:
            "Try that step again."
        }
    }

    public var retryLabel: String {
        switch self {
        case .calibrationFailed: "Start Over"
        case .lostConnection: "Reconnect"
        default: "Try Again"
        }
    }
}

/// The calibration wizard's state machine (Settings ▸ Motion Sensor ▸ Calibrate), free of UI and
/// networking: fed with `GET /imu` readings (4 Hz) it decides when PixelClip has been held still long
/// enough to capture a pose, then takes the clip's answers and errors.
///
/// `upright(holding → counting 3·2·1 → measuring) → faceUp(…) → done(axis map)`; a problem stops at
/// `.problem` until `retry()`; `calibration_failed` sends it back to upright (the clip discarded both).
public struct CalibrationWizard: Sendable, Equatable {
    public enum Step: Int, Sendable, Comparable, CaseIterable {
        case upright, faceUp, done
        public static func < (a: Step, b: Step) -> Bool { a.rawValue < b.rawValue }

        public var request: IMUCalibrationStep? {
            switch self {
            case .upright: .upright
            case .faceUp: .faceup
            case .done: nil
            }
        }
    }

    public enum Phase: Equatable, Sendable {
        /// Waiting for it to be still and square.
        case holding
        /// Still: seconds left before the capture (3, 2, 1).
        case counting(Int)
        /// `POST /imu/calibrate` in flight.
        case measuring
        case problem(CalibrationProblem)
    }

    public enum Action: Equatable, Sendable {
        case capture(IMUCalibrationStep)
    }

    /// Seconds of stillness before the capture.
    public static let countdown: TimeInterval = 3
    /// Readings over this long (s) must agree to count as still…
    public static let stillWindow: TimeInterval = 0.7
    /// …within this many g on every axis (the clip itself refuses above 0.1 g).
    public static let stillSpread = 0.06

    public private(set) var step: Step = .upright
    public private(set) var phase: Phase = .holding
    /// The last gravity reading (for the live ball).
    public private(set) var latest: IMUVector?
    /// The map in use before calibrating (for "before, sand fell to the left").
    public private(set) var previousMap: IMUAxisMap?
    public private(set) var result: IMUAxisMap?

    private var history: [Sample] = []
    private var stillSince: Date?
    /// The dominant axes of the poses captured so far: the next pose must be on another one (still in
    /// the first pose is the person not having turned it yet — capturing that would be a
    /// `calibration_failed`).
    private var capturedAxes: [Int] = []

    private struct Sample: Sendable, Equatable { var at: Date; var g: IMUVector }

    public init() {}

    /// Start (or start over) from the first reading's axis map.
    public mutating func begin(previous: IMUReading?) {
        self = CalibrationWizard()
        previousMap = previous?.axisMap
        latest = previous?.g
        if previous?.present == false { phase = .problem(.noIMU) }
    }

    public var change: AxisMapChange? { result.map { AxisMapChange(old: previousMap, new: $0) } }

    /// True while the readings say it's still (and square).
    public var isStill: Bool { stillSince != nil }

    /// It's still held the way the last pose was captured: it needs turning first.
    public var needsTurning: Bool {
        guard step != .done, let axis = latest?.dominantAxis else { return false }
        return capturedAxes.contains(axis)
    }

    /// A new reading. Returns `.capture` once it has been still for `countdown` seconds.
    public mutating func ingest(_ g: IMUVector, at now: Date) -> Action? {
        latest = g
        switch phase {
        case .holding, .counting: break
        case .measuring, .problem: return nil
        }
        guard step != .done else { return nil }
        history.append(Sample(at: now, g: g))
        history.removeAll { now.timeIntervalSince($0.at) > Self.stillWindow }
        guard steady(now), g.isSquare, !needsTurning else {
            stillSince = nil
            phase = .holding
            return nil
        }
        let since = stillSince ?? now
        stillSince = since
        let elapsed = now.timeIntervalSince(since)
        if elapsed >= Self.countdown, let request = step.request {
            phase = .measuring
            return .capture(request)
        }
        phase = .counting(max(1, Int((Self.countdown - elapsed).rounded(.up))))
        return nil
    }

    /// The readings in the window agree (and cover most of it: one reading is never "still").
    private func steady(_ now: Date) -> Bool {
        guard history.count >= 2, let first = history.first, now.timeIntervalSince(first.at) >= Self.stillWindow * 0.6 else { return false }
        for axis in 0..<3 {
            let v = history.map { $0.g.components[axis] }
            if (v.max()! - v.min()!) > Self.stillSpread { return false }
        }
        return true
    }

    /// The clip took the pose.
    public mutating func captured(_ r: IMUCalibrationResult) {
        if let axis = history.last?.g.dominantAxis ?? latest?.dominantAxis { capturedAxes.append(axis) }
        resetStillness()
        if r.calibrated, let map = r.axisMap, r.next == nil, r.step != .reset {
            result = map
            step = .done
            phase = .holding
            return
        }
        // One pose stored: the clip names the other (it may have lost the first, e.g. after a reboot).
        switch r.next {
        case .upright?: step = .upright
        case .faceup?: step = .faceUp
        default: step = r.step == .upright ? .faceUp : .upright
        }
        phase = .holding
    }

    public mutating func failed(_ error: any Error) {
        resetStillness()
        let p = CalibrationProblem(error)
        if p == .calibrationFailed { step = .upright; capturedAxes = [] }
        phase = .problem(p)
    }

    /// After a problem: hold the pose again (a final problem stays).
    public mutating func retry() {
        guard case .problem(let p) = phase, !p.isFinal else { return }
        resetStillness()
        phase = .holding
    }

    public var problem: CalibrationProblem? { if case .problem(let p) = phase { p } else { nil } }

    private mutating func resetStillness() {
        history = []
        stillSince = nil
    }
}
