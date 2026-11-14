import Foundation

/// Every endpoint of PROTOCOL §4 over the BLE fast lane (§3b): the same paths, JSON bodies, status
/// codes and `ClipError`s as `HTTPClipClient`, carried by a `FastLaneTransporting` (`BLETransport`).
/// The bulk transfers (`PUT /assets/{id}`, `PUT /texts/{id}`, `POST /ota`, `GET /screenshot`,
/// `GET /assets/{id}`, `GET /batlog`) throw `FastLaneError.needsWiFi` without touching the link, and
/// so does a `413 use_wifi` from the clip (e.g. a `GET /assets` list over 16 KB).
public final class FastLaneClipClient: ClipClient {
    public let transport: any FastLaneTransporting

    public init(transport: any FastLaneTransporting) { self.transport = transport }

    // MARK: Endpoints

    public func status() async throws -> ClipStatus { try await json("GET", "/status") }

    public func assets() async throws -> [ClipAsset] {
        let list: AssetList = try await json("GET", "/assets")
        return list.assets
    }

    public func putAsset(id: String, data: Data, progress: ProgressHandler?) async throws -> AssetPutResult {
        throw FastLaneError.needsWiFi
    }

    public func deleteAsset(id: String) async throws {
        guard HCA.isValidAssetID(id) else { throw ClipError.invalidAssetID(id) }
        let _: OKResponse = try await json("DELETE", "/assets/\(id)")
    }

    public func getAsset(id: String) async throws -> Data { throw FastLaneError.needsWiFi }

    public func playlist() async throws -> Playlist { try await json("GET", "/playlist") }

    public func putPlaylist(_ playlist: Playlist) async throws {
        let _: OKResponse = try await json("PUT", "/playlist", body: playlist)
    }

    public func config() async throws -> ClipConfig { try await json("GET", "/config") }

    public func putConfig(_ patch: ClipConfig) async throws -> ClipConfig { try await json("PUT", "/config", body: patch) }

    public func setTime(_ time: TimeSync) async throws {
        let _: OKResponse = try await json("POST", "/time", body: time)
    }

    public func show(id: String, durationMs: Int?, scroll: PlaylistItem.Scroll?) async throws {
        guard HCA.isValidAssetID(id) else { throw ClipError.invalidAssetID(id) }
        let _: OKResponse = try await json("POST", "/show/\(id)", body: ShowRequest(durationMs: durationMs, scroll: scroll))
    }

    public func next() async throws { let _: OKResponse = try await json("POST", "/next") }
    public func previous() async throws { let _: OKResponse = try await json("POST", "/prev") }

    public func setBrightness(_ value: Int) async throws {
        let _: OKResponse = try await json("POST", "/brightness", body: BrightnessRequest(value: min(max(value, 0), 255)))
    }

    public func screenshot() async throws -> RGB565Frame { throw FastLaneError.needsWiFi }

    public func ota(firmware: Data, progress: ProgressHandler?) async throws { throw FastLaneError.needsWiFi }

    public func endSession() async throws { let _: OKResponse = try await json("POST", "/session/end") }

    public func scenes() async throws -> SceneCatalog { try await json("GET", "/scenes") }

    public func batteryLog() async throws -> String { throw FastLaneError.needsWiFi }

    public func clearBatteryLog() async throws { let _: OKResponse = try await json("DELETE", "/batlog") }

    // MARK: Reader (§5c)

    public func texts() async throws -> [ClipText] {
        let list: TextList = try await json("GET", "/texts")
        return list.texts
    }

    public func putText(id: String, data: Data) async throws -> AssetPutResult { throw FastLaneError.needsWiFi }

    public func deleteText(id: String) async throws {
        guard HCA.isValidAssetID(id) else { throw ClipError.invalidAssetID(id) }
        let _: OKResponse = try await json("DELETE", "/texts/\(id)")
    }

    public func putFont(id: String, _ font: ReaderFontDocument) async throws {
        guard HCA.isValidAssetID(id) else { throw ClipError.invalidAssetID(id) }
        let _: OKResponse = try await json("PUT", "/fonts/\(id)", body: font)
    }

    public func font(id: String) async throws -> ReaderFontDocument {
        guard HCA.isValidAssetID(id) else { throw ClipError.invalidAssetID(id) }
        return try await json("GET", "/fonts/\(id)")
    }

    public func reader() async throws -> ReaderStatus { try await json("GET", "/reader") }

    public func readerControl(_ command: ReaderCommand) async throws {
        let _: OKResponse = try await json("POST", "/reader", body: command)
    }

    // MARK: Oracle (§5f)

    public func oracleDraw(cards: [Int]?) async throws {
        let _: OKResponse = try await json("POST", "/oracle/draw", body: OracleDrawRequest(cards: cards))
    }

    public func oracleBack() async throws {
        let _: OKResponse = try await json("POST", "/oracle/back")
    }

    public func oracleTurn() async throws {
        let _: OKResponse = try await json("POST", "/oracle/turn")
    }

    // MARK: Motion sensor

    public func imu() async throws -> IMUReading { try await json("GET", "/imu") }

    public func calibrateIMU(_ step: IMUCalibrationStep) async throws -> IMUCalibrationResult {
        try await json("POST", "/imu/calibrate", body: IMUCalibrationRequest(step: step))
    }

    // MARK: Plumbing

    private func json<T: Decodable>(_ method: String, _ path: String) async throws -> T {
        try decode(try await call(method, path))
    }

    private func json<T: Decodable, B: Encodable>(_ method: String, _ path: String, body: B) async throws -> T {
        try decode(try await call(method, path, body: try ClipJSON.encoder().encode(body)))
    }

    private func call(_ method: String, _ path: String, body: Data = Data()) async throws -> Data {
        let request = FastLaneRequest(method, path, body: body)
        guard request.route.isEligible else { throw FastLaneError.needsWiFi }
        let response = try await transport.send(request)
        try Self.check(response)
        return response.body
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do { return try ClipJSON.decoder().decode(T.self, from: data) } catch {
            throw ClipError.badResponse("\(T.self): \(error.localizedDescription)")
        }
    }

    /// The HTTP client's status check, plus the fast lane's own answers: `413 use_wifi` →
    /// `needsWiFi`; `400 bad_frame` (plain text) → a `bad_frame` envelope.
    static func check(_ r: FastLaneResponse) throws {
        guard !(200..<300).contains(r.status) else { return }
        let env = try? ClipJSON.decoder().decode(ErrorEnvelope.self, from: r.body)
        if r.status == 413, env?.error == "use_wifi" { throw FastLaneError.needsWiFi }
        if r.status == 400, env == nil, String(decoding: r.body, as: UTF8.self).hasPrefix("bad_frame") {
            throw ClipError.http(status: 400, envelope: ErrorEnvelope(error: "bad_frame", message: "The clip couldn’t read the request sent over Bluetooth."))
        }
        throw ClipError.http(status: r.status, envelope: env)
    }
}
