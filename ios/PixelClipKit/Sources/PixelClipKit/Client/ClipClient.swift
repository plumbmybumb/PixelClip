import Foundation

/// Fraction 0…1 reported while a request body is being sent.
public typealias ProgressHandler = @Sendable (Double) -> Void

/// Every endpoint of docs/PROTOCOL.md §4.
public protocol ClipClient: Sendable {
    func status() async throws -> ClipStatus
    func assets() async throws -> [ClipAsset]
    /// `PUT /assets/{id}`; a 409 (identical asset present) is reported as `.alreadyPresent`.
    func putAsset(id: String, data: Data, progress: ProgressHandler?) async throws -> AssetPutResult
    func deleteAsset(id: String) async throws
    func getAsset(id: String) async throws -> Data
    func playlist() async throws -> Playlist
    func putPlaylist(_ playlist: Playlist) async throws
    func config() async throws -> ClipConfig
    /// Merge-PUT; returns the full config.
    func putConfig(_ patch: ClipConfig) async throws -> ClipConfig
    func setTime(_ time: TimeSync) async throws
    /// `scroll`: for a strip, how to scroll it (nil: the clip uses its playlist item's scroll, else defaults).
    func show(id: String, durationMs: Int?, scroll: PlaylistItem.Scroll?) async throws
    func next() async throws
    func previous() async throws
    func setBrightness(_ value: Int) async throws
    func screenshot() async throws -> RGB565Frame
    func ota(firmware: Data, progress: ProgressHandler?) async throws
    func endSession() async throws
    /// `GET /scenes`: live scenes the firmware supports.
    func scenes() async throws -> SceneCatalog
    /// `GET /batlog` (optional endpoint; 404 when absent): CSV `t,mv,pct,state,display,brightness`.
    func batteryLog() async throws -> String
    func clearBatteryLog() async throws

    // Reader mode (PROTOCOL §5c)
    /// `GET /texts`.
    func texts() async throws -> [ClipText]
    /// `PUT /texts/{id}` (UTF-8, ≤ 1 MB, `X-Content-SHA256`); a 409 (identical text present) is `.alreadyPresent`.
    func putText(id: String, data: Data) async throws -> AssetPutResult
    func deleteText(id: String) async throws
    /// `PUT /fonts/{id}`: the font document (its atlases must be on the clip first).
    func putFont(id: String, _ font: ReaderFontDocument) async throws
    /// `GET /fonts/{id}`.
    func font(id: String) async throws -> ReaderFontDocument
    /// `GET /reader`.
    func reader() async throws -> ReaderStatus
    /// `POST /reader`: pause, resume or seek the reading on screen.
    func readerControl(_ command: ReaderCommand) async throws

    // Oracle (PROTOCOL §5f)
    /// `POST /oracle/draw {"cards":[a,b,c]}` (§5f.6): draw a row now (`cards`, three distinct 0-based cards, forces
    /// it; nil lets the clip pick). `409 not_showing` when no oracle item is on screen, 422 for a bad row.
    func oracleDraw(cards: [Int]?) async throws
    /// `POST /oracle/turn`: advance like a short press. `409 not_showing` when no oracle item is on screen.
    func oracleTurn() async throws
    /// `POST /oracle/back` (firmware extension, §5f.3): one screen back, like the clip's double-tap. `409 not_showing`.
    func oracleBack() async throws

    // Motion sensor (firmware extension, non-normative)
    /// `GET /imu`: gravity in the display frame, whether a bench calibration is stored, the axis map.
    func imu() async throws -> IMUReading
    /// `POST /imu/calibrate`: capture a still pose (`upright`, `faceup`; the second derives and stores the
    /// axis map) or erase the stored map (`reset`). 422 `not_still` / `ambiguous_pose` / `calibration_failed`, 409 `no_imu`.
    func calibrateIMU(_ step: IMUCalibrationStep) async throws -> IMUCalibrationResult
}

public enum ClipError: Error, Sendable, Equatable {
    /// The clip answered with an error status (and usually an error envelope).
    case http(status: Int, envelope: ErrorEnvelope?)
    /// Could not reach the clip at all (not joined, upload mode off, timed out…).
    case unreachable(String)
    case badResponse(String)
    case invalidAssetID(String)
    /// The clip speaks a newer protocol major than this app understands.
    case protocolTooNew(Int)

    public var isUnreachable: Bool { if case .unreachable = self { return true } else { return false } }

    public var code: String? {
        if case .http(_, let env) = self { return env?.error }
        return nil
    }
}

extension ClipError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .http(let status, let env):
            if let env { return env.message.isEmpty ? env.error : env.message }
            return "The clip returned an error (HTTP \(status))."
        case .unreachable:
            return "Can’t reach the clip."
        case .badResponse(let s):
            return "Unexpected reply from the clip: \(s)"
        case .invalidAssetID(let id):
            return "“\(id)” isn’t a valid asset id."
        case .protocolTooNew(let v):
            return "This clip uses protocol \(v). Update the app to talk to it."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .unreachable:
            return "Hold the button on the clip for two seconds until it shows WiFi, then try again."
        case .protocolTooNew:
            return "Install the latest version of the app."
        default:
            return nil
        }
    }
}

public extension ClipClient {
    /// "Show now" without a scroll block.
    func show(id: String, durationMs: Int?) async throws { try await show(id: id, durationMs: durationMs, scroll: nil) }
}

public extension ClipStatus {
    /// Throws when the clip's protocol major is newer than ours.
    func checkProtocol() throws {
        if device.protocolVersion > clipProtocolVersion { throw ClipError.protocolTooNew(device.protocolVersion) }
    }
}
