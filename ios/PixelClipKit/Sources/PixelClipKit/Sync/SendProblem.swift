import Foundation

/// Every way a send (or a connect) can fail, in words a person can act on. The app never shows a
/// raw error string: the join state, the clip's HTTP status/error code and what was last known
/// about the battery are mapped here, and anything unrecognised gets a calm generic message.
public enum SendProblem: Equatable, Sendable {
    /// iOS asked to join "PixelClip-…" and the person tapped Cancel.
    case joinDeclined
    /// The stored hotspot password doesn't match the clip's.
    case wrongPassword
    /// No `PixelClip-…` network: the clip's Wi‑Fi isn't on (or it's out of range).
    case clipNotFound
    /// The phone is on the clip's Wi‑Fi but the clip doesn't answer, or stopped answering.
    case clipNotAnswering
    /// The clip ended the session to protect its battery (Wi‑Fi needs ≥ 3.5 V).
    case lowBatteryEndedSession
    /// The Bluetooth doorbell found the battery too low to turn Wi‑Fi on (nothing was joined).
    case tooLowToWake
    /// `413`: the clip has no room for this picture.
    case clipFull(asset: String?)
    /// `422` on an upload: the clip couldn't read this picture.
    case assetRejected(asset: String?)
    /// `422` on the playlist.
    case playlistRejected
    /// The clip speaks a newer protocol than this build.
    case appTooOld
    /// Anything else.
    case other

    // MARK: Mapping

    /// From the hotspot joiner's failure.
    public init(join: JoinFailure?) {
        switch join {
        case .declined: self = .joinDeclined
        case .wrongPassword: self = .wrongPassword
        case .notFound: self = .clipNotFound
        case .lowBattery: self = .tooLowToWake
        case .noAnswer, nil: self = .clipNotAnswering
        }
    }

    /// From an error thrown while talking to the clip.
    /// - Parameters:
    ///   - step: the sync step that failed (`upload`, `playlist`, …), if known.
    ///   - assetName: the person's name for the asset involved (never the id).
    ///   - batteryWasLow: the last status was close to the 3.5 V Wi‑Fi cutoff (and not on USB), so a
    ///     dropped connection is most likely the clip ending the session itself.
    public init(error: (any Error)?, step: String? = nil, assetName: String? = nil, batteryWasLow: Bool = false) {
        guard let error else { self = .other; return }
        if let clip = error as? ClipError {
            self.init(clip: clip, step: step, assetName: assetName, batteryWasLow: batteryWasLow)
        } else if error is URLError {
            self = batteryWasLow ? .lowBatteryEndedSession : .clipNotAnswering
        } else {
            self = .other
        }
    }

    public init(clip: ClipError, step: String? = nil, assetName: String? = nil, batteryWasLow: Bool = false) {
        switch clip {
        case .unreachable:
            self = batteryWasLow ? .lowBatteryEndedSession : .clipNotAnswering
        case .protocolTooNew:
            self = .appTooOld
        case .http(let status, let env):
            switch (status, step) {
            case (413, _): self = .clipFull(asset: assetName)
            case (422, "upload"), (400, "upload"): self = .assetRejected(asset: assetName)
            case (422, "playlist"): self = .playlistRejected
            case (422, _) where env?.error == "invalid_playlist" || env?.error == "unknown_asset": self = .playlistRejected
            default: self = .other
            }
        case .badResponse, .invalidAssetID:
            self = .other
        }
    }

    /// From a sync report's first failure.
    public init(failure: SyncReport.Failure, assetName: String? = nil, batteryWasLow: Bool = false) {
        if let e = failure.clipError {
            self.init(clip: e, step: failure.step, assetName: assetName, batteryWasLow: batteryWasLow)
        } else {
            self = .other
        }
    }

    // MARK: Copy

    public var title: String {
        switch self {
        case .joinDeclined: "Joining was cancelled"
        case .wrongPassword: "The Wi‑Fi password didn’t match"
        case .clipNotFound: "Can’t find your clip"
        case .clipNotAnswering: "Your clip isn’t answering"
        case .lowBatteryEndedSession, .tooLowToWake: "The battery is too low"
        case .clipFull: "Your clip is full"
        case .assetRejected: "Your clip couldn’t read a picture"
        case .playlistRejected: "Your clip didn’t accept the playlist"
        case .appTooOld: "This app needs an update"
        case .other: "Something went wrong"
        }
    }

    public var message: String {
        switch self {
        case .joinDeclined:
            "When iPhone asks to join the “PixelClip-…” network, tap Join. Then try again."
        case .wrongPassword:
            "The hotspot password in Settings must match the clip’s. Unless you changed it, it’s “\(HotspotDefaults.password)”."
        case .clipNotFound:
            "PixelClip didn’t answer. Hold the button on the side of the clip for about two seconds, until it says “WiFi: PixelClip-…”, then try again."
        case .clipNotAnswering:
            "The clip may have turned its Wi‑Fi off. Press and hold its button for about two seconds, then try again."
        case .lowBatteryEndedSession:
            "The clip turned its Wi‑Fi off to save power. Charge it for a few minutes over USB‑C, then send again."
        case .tooLowToWake:
            "PixelClip answered over Bluetooth but its battery is too low to turn on Wi‑Fi. Charge it for a few minutes over USB‑C, then try again."
        case .clipFull(let name):
            "\(Self.quoted(name, fallback: "This picture")) doesn’t fit. Take a few things out of the playlist, then send again."
        case .assetRejected(let name):
            "\(Self.quoted(name, fallback: "One picture")) didn’t arrive intact. Send again; if it keeps happening, open it in the Library and save it again."
        case .playlistRejected:
            "Nothing was lost. Send again; if it keeps happening, update the clip from Settings."
        case .appTooOld:
            "Your clip is newer than this app. Install the latest version of the app."
        case .other:
            "Nothing was lost. Try again in a moment."
        }
    }

    /// The connection-help steps are the way forward.
    public var needsConnectionHelp: Bool {
        switch self {
        case .joinDeclined, .wrongPassword, .clipNotFound, .clipNotAnswering: true
        default: false
        }
    }

    /// The clip itself needs a press of its button (its Wi‑Fi is off).
    public var needsButtonPress: Bool {
        switch self {
        case .clipNotFound, .clipNotAnswering: true
        default: false
        }
    }

    public var systemImage: String {
        switch self {
        case .joinDeclined, .wrongPassword, .clipNotFound, .clipNotAnswering: "wifi.exclamationmark"
        case .lowBatteryEndedSession, .tooLowToWake: "battery.25percent"
        case .clipFull: "externaldrive.badge.exclamationmark"
        case .assetRejected: "photo.badge.exclamationmark"
        case .playlistRejected: "list.bullet.rectangle"
        case .appTooOld: "arrow.down.app"
        case .other: "exclamationmark.triangle"
        }
    }

    private static func quoted(_ name: String?, fallback: String) -> String {
        guard let name, !name.isEmpty else { return fallback }
        return "“\(name)”"
    }
}
