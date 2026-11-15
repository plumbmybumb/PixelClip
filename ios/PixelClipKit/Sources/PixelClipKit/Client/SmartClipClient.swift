import Foundation

/// Which way a request reached the clip.
public enum ClipTransport: String, Sendable, Equatable {
    case bluetooth
    case wifi
}

/// One routed request (the app's send sheet badge and timings, the routing tests).
public struct ClipRouteRecord: Sendable, Equatable {
    public var route: FastLaneRoute
    public var transport: ClipTransport
    public var seconds: Double
    /// The fast lane was tried first, then the request went over Wi‑Fi.
    public var fellBack: Bool

    public init(route: FastLaneRoute, transport: ClipTransport, seconds: Double, fellBack: Bool) {
        self.route = route; self.transport = transport; self.seconds = seconds; self.fellBack = fellBack
    }
}

/// What `SmartClipClient` asks the app: is the clip's Wi‑Fi session open, the fast lane (connecting
/// to the nearby clip if needed, through the doorbell's scan), and the doorbell + hotspot path.
@MainActor
public protocol ClipLinks: AnyObject, Sendable {
    /// This iPhone is on the clip's Wi‑Fi (a session is open).
    var wifiOpen: Bool { get }
    /// The fast lane to the nearby clip, linking over Bluetooth if needed; nil when there's none
    /// (Bluetooth off or not allowed, Bluetooth Wake off, clip out of range, firmware without it).
    func fastLane() async -> (any ClipClient)?
    /// Wake the clip over Bluetooth and join its hotspot; throws (a `ClipError`) when that fails.
    func openWiFi() async throws
    /// A request went through (or fell back).
    func routed(_ record: ClipRouteRecord)
}

/// The client the app uses. For each request: when no Wi‑Fi session is open and the route is
/// fast-lane eligible (everything but the bulk transfers), it goes over Bluetooth; otherwise — or
/// when the fast lane isn't there, or the clip answers `413 use_wifi` — the doorbell + hotspot path
/// opens Wi‑Fi and the request goes over HTTP. Once Wi‑Fi is up, everything goes over HTTP.
///
/// A Bluetooth exchange that breaks off midway (timeout, dropped link) is retried over Wi‑Fi only
/// for idempotent routes; `POST /next` / `/prev` then fail with `ClipError.unreachable` (the clip
/// may already have stepped).
public final class SmartClipClient: ClipClient {
    public let http: any ClipClient
    public let links: any ClipLinks

    public init(http: any ClipClient, links: any ClipLinks) {
        self.http = http
        self.links = links
    }

    /// Runs `op` on the fast lane or on HTTP, per the rules above. `wifiOnly`: never the fast lane
    /// (a request whose body must not travel over Bluetooth, such as a new hotspot passphrase).
    func route<T>(_ method: String, _ path: String, wifiOnly: Bool = false, _ op: (any ClipClient) async throws -> T) async throws -> T {
        let route = FastLaneRoute(method, path)
        let clock = ContinuousClock()
        let start = clock.now
        var triedLane = false
        if route.isEligible, !wifiOnly, await !links.wifiOpen, let lane = await links.fastLane() {
            triedLane = true
            do {
                let value = try await op(lane)
                await links.routed(ClipRouteRecord(route: route, transport: .bluetooth, seconds: (clock.now - start).seconds, fellBack: false))
                return value
            } catch let e as FastLaneError {
                if !e.nothingRan && !route.isIdempotent {
                    throw ClipError.unreachable(e.localizedDescription)
                }
                // Fall through to Wi‑Fi.
            }
        }
        if await !links.wifiOpen { try await links.openWiFi() }
        let value = try await op(http)
        await links.routed(ClipRouteRecord(route: route, transport: .wifi, seconds: (clock.now - start).seconds, fellBack: triedLane))
        return value
    }

    // MARK: ClipClient

    public func status() async throws -> ClipStatus { try await route("GET", "/status") { try await $0.status() } }
    public func assets() async throws -> [ClipAsset] { try await route("GET", "/assets") { try await $0.assets() } }

    public func putAsset(id: String, data: Data, progress: ProgressHandler?) async throws -> AssetPutResult {
        try await route("PUT", "/assets/\(id)") { try await $0.putAsset(id: id, data: data, progress: progress) }
    }

    public func deleteAsset(id: String) async throws { try await route("DELETE", "/assets/\(id)") { try await $0.deleteAsset(id: id) } }
    public func getAsset(id: String) async throws -> Data { try await route("GET", "/assets/\(id)") { try await $0.getAsset(id: id) } }
    public func playlist() async throws -> Playlist { try await route("GET", "/playlist") { try await $0.playlist() } }
    public func putPlaylist(_ playlist: Playlist) async throws { try await route("PUT", "/playlist") { try await $0.putPlaylist(playlist) } }
    public func config() async throws -> ClipConfig { try await route("GET", "/config") { try await $0.config() } }
    /// A new hotspot passphrase (`ap_password`) only ever goes over the clip's Wi‑Fi (the firmware refuses it over Bluetooth).
    public func putConfig(_ patch: ClipConfig) async throws -> ClipConfig {
        try await route("PUT", "/config", wifiOnly: patch.apPassword != nil) { try await $0.putConfig(patch) }
    }
    public func setTime(_ time: TimeSync) async throws { try await route("POST", "/time") { try await $0.setTime(time) } }

    public func show(id: String, durationMs: Int?, scroll: PlaylistItem.Scroll?) async throws {
        try await route("POST", "/show/\(id)") { try await $0.show(id: id, durationMs: durationMs, scroll: scroll) }
    }

    public func next() async throws { try await route("POST", "/next") { try await $0.next() } }
    public func previous() async throws { try await route("POST", "/prev") { try await $0.previous() } }
    public func setBrightness(_ value: Int) async throws { try await route("POST", "/brightness") { try await $0.setBrightness(value) } }
    public func screenshot() async throws -> RGB565Frame { try await route("GET", "/screenshot") { try await $0.screenshot() } }

    public func ota(firmware: Data, progress: ProgressHandler?) async throws {
        try await route("POST", "/ota") { try await $0.ota(firmware: firmware, progress: progress) }
    }

    public func otaState() async throws -> OTAState { try await route("GET", "/ota") { try await $0.otaState() } }
    public func askOTA() async throws -> OTAState { try await route("POST", "/ota/ask") { try await $0.askOTA() } }

    public func endSession() async throws { try await route("POST", "/session/end") { try await $0.endSession() } }
    public func scenes() async throws -> SceneCatalog { try await route("GET", "/scenes") { try await $0.scenes() } }
    public func batteryLog() async throws -> String { try await route("GET", "/batlog") { try await $0.batteryLog() } }
    public func clearBatteryLog() async throws { try await route("DELETE", "/batlog") { try await $0.clearBatteryLog() } }
    public func texts() async throws -> [ClipText] { try await route("GET", "/texts") { try await $0.texts() } }

    public func putText(id: String, data: Data) async throws -> AssetPutResult {
        try await route("PUT", "/texts/\(id)") { try await $0.putText(id: id, data: data) }
    }

    public func deleteText(id: String) async throws { try await route("DELETE", "/texts/\(id)") { try await $0.deleteText(id: id) } }
    public func fonts() async throws -> [ClipFontInfo] { try await route("GET", "/fonts") { try await $0.fonts() } }
    public func putFont(id: String, _ font: ReaderFontDocument) async throws { try await route("PUT", "/fonts/\(id)") { try await $0.putFont(id: id, font) } }
    public func font(id: String) async throws -> ReaderFontDocument { try await route("GET", "/fonts/\(id)") { try await $0.font(id: id) } }
    public func reader() async throws -> ReaderStatus { try await route("GET", "/reader") { try await $0.reader() } }
    public func readerControl(_ command: ReaderCommand) async throws { try await route("POST", "/reader") { try await $0.readerControl(command) } }

    public func oracleDraw(cards: [Int]?) async throws { try await route("POST", "/oracle/draw") { try await $0.oracleDraw(cards: cards) } }
    public func oracleBack() async throws { try await route("POST", "/oracle/back") { try await $0.oracleBack() } }
    public func oracleTurn() async throws { try await route("POST", "/oracle/turn") { try await $0.oracleTurn() } }

    public func imu() async throws -> IMUReading { try await route("GET", "/imu") { try await $0.imu() } }

    public func calibrateIMU(_ step: IMUCalibrationStep) async throws -> IMUCalibrationResult {
        try await route("POST", "/imu/calibrate") { try await $0.calibrateIMU(step) }
    }
}
