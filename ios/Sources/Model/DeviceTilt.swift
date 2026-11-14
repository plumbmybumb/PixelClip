import CoreMotion
import os
import PixelClipKit

/// This iPhone's own tilt, as clip-frame gravity, for the virtual clip's motion sensor (Debug's
/// virtual clip on a device: hold the phone like the clip and its "sensor" follows), and its shake
/// metric for the Tarot (a shake draws, on the virtual clip). Runs only while someone needs it (the
/// calibration wizard, Home while the Tarot is Now on the virtual clip); the simulator has no
/// accelerometer, so it stays nil there and the virtual clip uses its simulated pose (and Draw).
final class DeviceTilt: @unchecked Sendable {
    static let shared = DeviceTilt()

    private let latest = OSAllocatedUnfairLock<IMUVector?>(initialState: nil)
    /// The clip's shake metric (`firmware/components/imu`): the magnitude of acceleration minus its
    /// ~100 ms low-pass, as a decaying peak (×0.92 per 20 ms sample there, the same per second here).
    private struct Shake { var lp: IMUVector?; var peak: Double = 0 }
    private let shake = OSAllocatedUnfairLock(initialState: Shake())
    @MainActor private var manager: CMMotionManager?
    @MainActor private var users = 0

    private init() {}

    /// Display-frame gravity (+x right, +y down, +z out of the glass) from the accelerometer: the
    /// phone's (x, y, z) is (x, −y, z) on the clip — portrait upright reads (0, −1, 0) on the phone and
    /// should read (0, 1, 0) on the clip; face up is (0, 0, −1) on both.
    var clipGravity: IMUVector? { latest.withLock { $0 } }

    /// The shake metric in g (nil while not running): ≥ 0.9 is a deliberate shake.
    var shakeMetric: Double? { latest.withLock { $0 } == nil ? nil : shake.withLock { $0.peak } }

    @MainActor var isAvailable: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        (manager ?? CMMotionManager()).isAccelerometerAvailable
        #endif
    }

    @MainActor func start() {
        users += 1
        guard users == 1, isAvailable else { return }
        let m = manager ?? CMMotionManager()
        manager = m
        m.accelerometerUpdateInterval = 1.0 / 30
        m.startAccelerometerUpdates(to: .main) { [latest, shake] data, _ in
            guard let a = data?.acceleration else { return }
            let now = IMUVector(a.x, -a.y, a.z)
            shake.withLock { s in
                // At 30 Hz: the same ~100 ms low-pass (1 − e^(−33/100)) and decay (0.92^(50/30)) as the clip's 50 Hz.
                guard let lp = s.lp else { s.lp = now; return }
                let k = 0.28
                let next = IMUVector(lp.x + k * (now.x - lp.x), lp.y + k * (now.y - lp.y), lp.z + k * (now.z - lp.z))
                let hx = now.x - next.x, hy = now.y - next.y, hz = now.z - next.z
                let m = (hx * hx + hy * hy + hz * hz).squareRoot()
                s.lp = next
                s.peak = max(m, s.peak * 0.87)
            }
            latest.withLock { old in
                // A light low-pass, like the clip's own gravity filter.
                guard let o = old else { old = now; return }
                let k = 0.25
                old = IMUVector(o.x + k * (now.x - o.x), o.y + k * (now.y - o.y), o.z + k * (now.z - o.z))
            }
        }
    }

    @MainActor func stop() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        manager?.stopAccelerometerUpdates()
        latest.withLock { $0 = nil }
        shake.withLock { $0 = Shake() }
    }
}
