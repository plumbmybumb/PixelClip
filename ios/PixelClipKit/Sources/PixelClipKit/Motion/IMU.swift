import Foundation

// The motion sensor (QMI8658C) endpoints — firmware extensions, non-normative (firmware/README.md
// "IMU bench check"): `GET /imu` and `POST /imu/calibrate {"step":"upright"|"faceup"|"reset"}`.

/// A gravity vector in g. In the display frame (`g`): +x right, +y down, +z out of the glass, so
/// upright reads ≈ (0, 1, 0) and lying face up ≈ (0, 0, −1).
public struct IMUVector: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(_ x: Double, _ y: Double, _ z: Double) { self.x = x; self.y = y; self.z = z }

    public static let upright = IMUVector(0, 1, 0)
    public static let faceUp = IMUVector(0, 0, -1)

    public var components: [Double] { [x, y, z] }
    public var magnitude: Double { (x * x + y * y + z * z).squareRoot() }

    /// The one axis carrying more than 0.7 g (as the firmware's `ambiguous_pose` check), or nil.
    public var dominantAxis: Int? {
        let big = components.enumerated().filter { abs($0.element) > 0.7 }
        return big.count == 1 ? big[0].offset : nil
    }

    /// Roughly 1 g along a single axis: a pose the clip can calibrate from.
    public var isSquare: Bool { (0.8...1.2).contains(magnitude) && dominantAxis != nil }

    public init(from decoder: any Decoder) throws {
        var c = try decoder.unkeyedContainer()
        x = try c.decode(Double.self); y = try c.decode(Double.self); z = try c.decode(Double.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(x); try c.encode(y); try c.encode(z)
    }
}

/// The chip → display matrix (`g[i] = Σ axis_map[i][j]·raw[j]`), a signed permutation.
public struct IMUAxisMap: Codable, Sendable, Equatable {
    public var rows: [[Int]]

    public init(_ rows: [[Int]]) { self.rows = rows }

    public static let identity = IMUAxisMap([[1, 0, 0], [0, 1, 0], [0, 0, 1]])

    public init(from decoder: any Decoder) throws { rows = try decoder.singleValueContainer().decode([[Int]].self) }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rows)
    }

    /// Each row has exactly one ±1 and the columns are distinct.
    public var isSignedPermutation: Bool {
        guard rows.count == 3, rows.allSatisfy({ $0.count == 3 }) else { return false }
        var cols = Set<Int>()
        for r in rows {
            let nz = r.enumerated().filter { $0.element != 0 }
            guard nz.count == 1, abs(nz[0].element) == 1 else { return false }
            cols.insert(nz[0].offset)
        }
        return cols.count == 3
    }

    /// display = M · chip.
    public func apply(_ v: IMUVector) -> IMUVector {
        let c = v.components
        func row(_ i: Int) -> Double { (0..<3).reduce(0) { $0 + Double(rows[i][$1]) * c[$1] } }
        return IMUVector(row(0), row(1), row(2))
    }

    /// chip = Mᵀ · display (a signed permutation's inverse is its transpose).
    public func inverse(_ v: IMUVector) -> IMUVector {
        let c = v.components
        func col(_ j: Int) -> Double { (0..<3).reduce(0) { $0 + Double(rows[$1][j]) * c[$1] } }
        return IMUVector(col(0), col(1), col(2))
    }

    /// `scene_axis_map_calibrate()` (core/src/scene.c, mirrored by scripts/mock_clip.py): row y is the
    /// upright reading's dominant chip axis (with its sign), row z minus the face-up reading's, row x =
    /// y × z. Nil when both readings are on the same chip axis (`calibration_failed`).
    public static func calibrate(upright up: IMUVector, faceUp face: IMUVector) -> IMUAxisMap? {
        let u = up.components, f = face.components
        let ay = (0..<3).max { abs(u[$0]) < abs(u[$1]) }!
        let az = (0..<3).max { abs(f[$0]) < abs(f[$1]) }!
        guard ay != az else { return nil }
        var ry = [0, 0, 0]; ry[ay] = u[ay] > 0 ? 1 : -1
        var rz = [0, 0, 0]; rz[az] = f[az] > 0 ? -1 : 1
        let rx = [ry[1] * rz[2] - ry[2] * rz[1], ry[2] * rz[0] - ry[0] * rz[2], ry[0] * rz[1] - ry[1] * rz[0]]
        return IMUAxisMap([rx, ry, rz])
    }
}

/// `GET /imu`.
public struct IMUReading: Codable, Sendable, Equatable {
    public var present: Bool
    /// Gravity in the display frame (through the axis map in use).
    public var g: IMUVector
    public var shake: Double?
    public var samples: Int?
    public var gLowPass: IMUVector?
    /// The chip's own reading (+1 g on the axis pointing up).
    public var raw: IMUVector?
    /// A bench calibration is stored (else the compiled map + Kconfig flips are in use).
    public var calibrated: Bool
    public var axisMap: IMUAxisMap?
    public var addr: String?
    /// The screen is turned 180° (PROTOCOL §4 Orientation). `g` stays the unrotated display-frame
    /// vector either way. Nil on firmware that predates the flip.
    public var flipped: Bool?

    enum CodingKeys: String, CodingKey {
        case present, g, shake, samples, raw, calibrated, addr, flipped
        case gLowPass = "g_lp"
        case axisMap = "axis_map"
    }

    public init(present: Bool = true, g: IMUVector, shake: Double? = 0, samples: Int? = nil, gLowPass: IMUVector? = nil,
                raw: IMUVector? = nil, calibrated: Bool = false, axisMap: IMUAxisMap? = .identity, addr: String? = "0x6B",
                flipped: Bool? = nil) {
        self.present = present; self.g = g; self.shake = shake; self.samples = samples; self.gLowPass = gLowPass
        self.raw = raw; self.calibrated = calibrated; self.axisMap = axisMap; self.addr = addr; self.flipped = flipped
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        present = try c.decodeIfPresent(Bool.self, forKey: .present) ?? true
        g = try c.decodeIfPresent(IMUVector.self, forKey: .g) ?? .upright
        shake = try c.decodeIfPresent(Double.self, forKey: .shake)
        samples = try c.decodeIfPresent(Int.self, forKey: .samples)
        gLowPass = try c.decodeIfPresent(IMUVector.self, forKey: .gLowPass)
        raw = try c.decodeIfPresent(IMUVector.self, forKey: .raw)
        calibrated = try c.decodeIfPresent(Bool.self, forKey: .calibrated) ?? false
        axisMap = try c.decodeIfPresent(IMUAxisMap.self, forKey: .axisMap)
        addr = try c.decodeIfPresent(String.self, forKey: .addr)
        flipped = try c.decodeIfPresent(Bool.self, forKey: .flipped)
    }
}

/// The body of `POST /imu/calibrate`.
public enum IMUCalibrationStep: String, Codable, Sendable, CaseIterable {
    case upright, faceup, reset
}

public struct IMUCalibrationRequest: Codable, Sendable, Equatable {
    public var step: IMUCalibrationStep
    public init(step: IMUCalibrationStep) { self.step = step }
}

/// `POST /imu/calibrate`'s answer: after one pose `next` names the other; after both,
/// `calibrated` is true and `axis_map` is the new matrix (applied and stored on the clip).
public struct IMUCalibrationResult: Codable, Sendable, Equatable {
    public var step: IMUCalibrationStep
    public var raw: IMUVector?
    public var next: IMUCalibrationStep?
    public var calibrated: Bool
    public var axisMap: IMUAxisMap?

    enum CodingKeys: String, CodingKey {
        case step, raw, next, calibrated
        case axisMap = "axis_map"
    }

    public init(step: IMUCalibrationStep, raw: IMUVector? = nil, next: IMUCalibrationStep? = nil, calibrated: Bool, axisMap: IMUAxisMap? = nil) {
        self.step = step; self.raw = raw; self.next = next; self.calibrated = calibrated; self.axisMap = axisMap
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        step = try c.decode(IMUCalibrationStep.self, forKey: .step)
        raw = try c.decodeIfPresent(IMUVector.self, forKey: .raw)
        next = try c.decodeIfPresent(IMUCalibrationStep.self, forKey: .next)
        calibrated = try c.decodeIfPresent(Bool.self, forKey: .calibrated) ?? false
        axisMap = try c.decodeIfPresent(IMUAxisMap.self, forKey: .axisMap)
    }
}

/// Directions on the clip, in words.
public enum ClipDirection: String, Sendable, Equatable, CaseIterable {
    case down, up, right, left, towardYou, awayFromYou

    /// The direction a display-frame unit vector points (nil unless it's along one axis).
    public init?(_ v: IMUVector) {
        guard let axis = v.dominantAxis else { return nil }
        let positive = v.components[axis] > 0
        switch axis {
        case 0: self = positive ? .right : .left
        case 1: self = positive ? .down : .up
        default: self = positive ? .towardYou : .awayFromYou
        }
    }

    public var words: String {
        switch self {
        case .down: "down"
        case .up: "up"
        case .right: "to the right"
        case .left: "to the left"
        case .towardYou: "toward you"
        case .awayFromYou: "into the screen"
        }
    }
}

/// What a calibration changed, in plain words for the wizard's last step.
public struct AxisMapChange: Sendable, Equatable {
    /// Which way sand fell before (with the old map) when PixelClip hung upright.
    public var before: ClipDirection?
    /// …and now (always `.down` for a good calibration).
    public var after: ClipDirection?

    /// - Parameters: old = the map in use before (nil: unknown), new = the calibrated one.
    public init(old: IMUAxisMap?, new: IMUAxisMap) {
        // The real "down" (upright pose) in chip terms, then seen through each map.
        let chipDown = new.inverse(.upright)
        after = ClipDirection(new.apply(chipDown))
        before = old.flatMap { ClipDirection($0.apply(chipDown)) }
    }

    public var changed: Bool { before != nil && before != after }

    /// "Down is now down".
    public var headline: String { after == .down ? "Down is now down" : "Down is now \(after?.words ?? "unknown")" }

    /// "Before, sand fell to the left." / "It was already right: nothing changed."
    public var detail: String {
        guard let before else { return "Sand and snow fall toward the floor when PixelClip is in your hair." }
        if before == after { return "It was already right: nothing changed." }
        return "Before, sand fell \(before.words). Now it falls toward the floor when PixelClip is in your hair."
    }
}
