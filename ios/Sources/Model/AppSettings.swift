import Foundation
import Observation

/// Settings that live on the phone (not on the clip), in UserDefaults: whether the welcome pages
/// have been seen, the last firmware version the app saw and the Bluetooth wake preference. Clip-side settings (name, brightness, timeouts) live in `ClipSession`.
@MainActor @Observable
final class AppSettings {
    static let shared = AppSettings()

    enum Keys {
        static let onboarded = "onboardingDone.v1"
        static let firmware = "lastFirmwareVersion"
        static let bluetoothWake = "bluetoothWake"
        static let bluetoothWakePending = "bluetoothWakePending"
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// The welcome pages have been seen (or skipped).
    var onboarded: Bool { didSet { defaults.set(onboarded, forKey: Keys.onboarded) } }
    /// Firmware version from the last status read, for About when the clip isn't connected.
    var lastFirmware: String? { didSet { defaults.set(lastFirmware, forKey: Keys.firmware) } }
    /// Ring the clip over Bluetooth before joining its Wi‑Fi (default on). Mirrors the clip's
    /// `ble_wake` once connected; changed while away, it's sent at the next connect (`bluetoothWakePending`).
    var bluetoothWake: Bool { didSet { defaults.set(bluetoothWake, forKey: Keys.bluetoothWake) } }
    /// `bluetoothWake` was changed while not connected and the clip hasn't been told yet.
    var bluetoothWakePending: Bool { didSet { defaults.set(bluetoothWakePending, forKey: Keys.bluetoothWakePending) } }


    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        onboarded = defaults.bool(forKey: Keys.onboarded)
        lastFirmware = defaults.string(forKey: Keys.firmware)
        bluetoothWake = defaults.object(forKey: Keys.bluetoothWake) as? Bool ?? true
        bluetoothWakePending = defaults.bool(forKey: Keys.bluetoothWakePending)
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-PixelClipOnboarding") { onboarded = false }
        else if args.contains("-PixelClipSkipOnboarding") || args.contains("-PixelClipDemo") || args.contains("-PixelClipTab") { onboarded = true }
        #endif
    }

    var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(v) (\(b))"
    }
}
