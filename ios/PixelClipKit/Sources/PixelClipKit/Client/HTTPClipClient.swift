import Foundation

/// Talks to the real clip over its SoftAP (`http://192.168.4.1`).
///
/// - Short timeouts (the clip is one hop away; a slow answer means it is gone).
/// - Retries a request once when the connection drops or can't be opened, which happens routinely
///   in the first second after iOS joins the hotspot.
/// - Bodies are sent with a `Content-Length` (no chunked transfer-encoding); URLSession streams
///   them in TCP-sized pieces and reports progress through a per-task delegate.
public final class HTTPClipClient: ClipClient {
    public static let defaultBaseURL = URL(string: "http://192.168.4.1")!

    public let baseURL: URL
    private let session: URLSession

    /// - Parameter protocolClasses: URL protocols to put first (tests stub the clip with one).
    public init(baseURL: URL = HTTPClipClient.defaultBaseURL, requestTimeout: TimeInterval = 6, protocolClasses: [AnyClass] = []) {
        self.baseURL = baseURL
        let cfg = URLSessionConfiguration.ephemeral
        if !protocolClasses.isEmpty { cfg.protocolClasses = protocolClasses + (cfg.protocolClasses ?? []) }
        cfg.timeoutIntervalForRequest = requestTimeout
        cfg.timeoutIntervalForResource = 300
        cfg.waitsForConnectivity = false
        cfg.httpMaximumConnectionsPerHost = 1
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        // The clip is only reachable over WiFi; never let iOS try cellular for it.
        cfg.allowsCellularAccess = false
        session = URLSession(configuration: cfg)
    }

    // MARK: Endpoints

    public func status() async throws -> ClipStatus {
        try await json(.get, "/status")
    }

    public func assets() async throws -> [ClipAsset] {
        let list: AssetList = try await json(.get, "/assets")
        return list.assets
    }

    public func putAsset(id: String, data: Data, progress: ProgressHandler?) async throws -> AssetPutResult {
        guard HCA.isValidAssetID(id) else { throw ClipError.invalidAssetID(id) }
        let sha = Hashing.sha256Hex(data)
        var req = request(.put, "/assets/\(id)")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.setValue(sha, forHTTPHeaderField: "X-Content-SHA256")
        req.timeoutInterval = 20
        do {
            let (body, resp) = try await send(req, upload: data, progress: progress)
            if resp.statusCode == 409 { return .alreadyPresent }
            try check(resp, body)
            return .created(try decode(AssetPutResponse.self, body))
        } catch let error as ClipError where error.isUnreachable {
            // The firmware decides 409 from the headers and may answer (and close) before we finish
            // sending the body, which URLSession reports as a dropped connection. Ask the clip.
            if let present = try? await assets().first(where: { $0.id == id }),
               present.sha256.lowercased() == sha, present.size == data.count {
                return .alreadyPresent
            }
            throw error
        }
    }

    public func deleteAsset(id: String) async throws {
        guard HCA.isValidAssetID(id) else { throw ClipError.invalidAssetID(id) }
        let _: OKResponse = try await json(.delete, "/assets/\(id)")
    }

    public func getAsset(id: String) async throws -> Data {
        guard HCA.isValidAssetID(id) else { throw ClipError.invalidAssetID(id) }
        var req = request(.get, "/assets/\(id)")
        req.timeoutInterval = 20
        let (body, resp) = try await send(req)
        try check(resp, body)
        return body
    }

    public func playlist() async throws -> Playlist { try await json(.get, "/playlist") }

    public func putPlaylist(_ playlist: Playlist) async throws {
        let _: OKResponse = try await json(.put, "/playlist", body: playlist)
    }

    public func config() async throws -> ClipConfig { try await json(.get, "/config") }

    public func putConfig(_ patch: ClipConfig) async throws -> ClipConfig {
        try await json(.put, "/config", body: patch)
    }

    public func setTime(_ time: TimeSync) async throws {
        let _: OKResponse = try await json(.post, "/time", body: time)
    }

    public func show(id: String, durationMs: Int?, scroll: PlaylistItem.Scroll?) async throws {
        guard HCA.isValidAssetID(id) else { throw ClipError.invalidAssetID(id) }
        let _: OKResponse = try await json(.post, "/show/\(id)", body: ShowRequest(durationMs: durationMs, scroll: scroll))
    }

    public func next() async throws { let _: OKResponse = try await json(.post, "/next") }
    public func previous() async throws { let _: OKResponse = try await json(.post, "/prev") }

    public func setBrightness(_ value: Int) async throws {
        let _: OKResponse = try await json(.post, "/brightness", body: BrightnessRequest(value: min(max(value, 0), 255)))
    }

    public func screenshot() async throws -> RGB565Frame {
        var req = request(.get, "/screenshot")
        req.timeoutInterval = 15
        let (body, resp) = try await send(req)
        try check(resp, body)
        do {
            return try RGB565Frame(bigEndianBytes: body, width: ClipCanvas.width, height: ClipCanvas.height)
        } catch {
            throw ClipError.badResponse("screenshot was \(body.count) bytes, expected \(RGB565Frame.clipFrameBytes)")
        }
    }

    public func ota(firmware: Data, progress: ProgressHandler?) async throws {
        var req = request(.post, "/ota")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.setValue(Hashing.sha256Hex(firmware), forHTTPHeaderField: "X-Content-SHA256")
        req.timeoutInterval = 60
        // Never retry an OTA automatically: a half-flashed image is the device's problem to reject.
        let (body, resp) = try await send(req, upload: firmware, progress: progress, retry: false)
        try check(resp, body)
    }

    public func endSession() async throws {
        let _: OKResponse = try await json(.post, "/session/end")
    }

    public func scenes() async throws -> SceneCatalog { try await json(.get, "/scenes") }

    public func batteryLog() async throws -> String {
        let (body, resp) = try await send(request(.get, "/batlog"))
        try check(resp, body)
        return String(decoding: body, as: UTF8.self)
    }

    public func clearBatteryLog() async throws {
        let _: OKResponse = try await json(.delete, "/batlog")
    }

    // MARK: Reader (§5c)

    public func texts() async throws -> [ClipText] {
        let list: TextList = try await json(.get, "/texts")
        return list.texts
    }

    public func putText(id: String, data: Data) async throws -> AssetPutResult {
        guard HCA.isValidAssetID(id) else { throw ClipError.invalidAssetID(id) }
        let sha = Hashing.sha256Hex(data)
        var req = request(.put, "/texts/\(id)")
        req.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.setValue(sha, forHTTPHeaderField: "X-Content-SHA256")
        req.timeoutInterval = 30
        do {
            let (body, resp) = try await send(req, upload: data)
            if resp.statusCode == 409 { return .alreadyPresent }
            try check(resp, body)
            // The reply's fields aren't specified beyond "ok"; fill in what we sent.
            let reply = try? ClipJSON.decoder().decode(AssetPutResponse.self, from: body)
            return .created(reply ?? AssetPutResponse(id: id, size: data.count, sha256: sha))
        } catch let error as ClipError where error.isUnreachable {
            // Same early-409 race as assets: ask the clip whether it has this text.
            if let present = try? await texts().first(where: { $0.id == id }), present.bytes == data.count { return .alreadyPresent }
            throw error
        }
    }

    public func deleteText(id: String) async throws {
        guard HCA.isValidAssetID(id) else { throw ClipError.invalidAssetID(id) }
        let _: OKResponse = try await json(.delete, "/texts/\(id)")
    }

    public func putFont(id: String, _ font: ReaderFontDocument) async throws {
        guard HCA.isValidAssetID(id) else { throw ClipError.invalidAssetID(id) }
        let _: OKResponse = try await json(.put, "/fonts/\(id)", body: font)
    }

    public func font(id: String) async throws -> ReaderFontDocument {
        guard HCA.isValidAssetID(id) else { throw ClipError.invalidAssetID(id) }
        return try await json(.get, "/fonts/\(id)")
    }

    public func reader() async throws -> ReaderStatus { try await json(.get, "/reader") }

    public func readerControl(_ command: ReaderCommand) async throws {
        let _: OKResponse = try await json(.post, "/reader", body: command)
    }

    // MARK: Oracle (§5f)

    public func oracleDraw(cards: [Int]?) async throws {
        let _: OKResponse = try await json(.post, "/oracle/draw", body: OracleDrawRequest(cards: cards))
    }

    public func oracleBack() async throws {
        let _: OKResponse = try await json(.post, "/oracle/back")
    }

    public func oracleTurn() async throws {
        let _: OKResponse = try await json(.post, "/oracle/turn")
    }

    // MARK: Motion sensor

    public func imu() async throws -> IMUReading { try await json(.get, "/imu") }

    public func calibrateIMU(_ step: IMUCalibrationStep) async throws -> IMUCalibrationResult {
        // The clip averages ~0.5 s of samples before it answers.
        try await json(.post, "/imu/calibrate", body: IMUCalibrationRequest(step: step))
    }

    // MARK: Plumbing

    enum Method: String { case get = "GET", put = "PUT", post = "POST", delete = "DELETE" }

    private func request(_ method: Method, _ path: String) -> URLRequest {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = method.rawValue
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return req
    }

    private func json<T: Decodable>(_ method: Method, _ path: String) async throws -> T {
        let req = request(method, path)
        let (body, resp) = try await send(req)
        try check(resp, body)
        return try decode(T.self, body)
    }

    private func json<T: Decodable, B: Encodable>(_ method: Method, _ path: String, body: B) async throws -> T {
        var req = request(method, path)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload = try ClipJSON.encoder().encode(body)
        let (data, resp) = try await send(req, upload: payload)
        try check(resp, data)
        return try decode(T.self, data)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try ClipJSON.decoder().decode(T.self, from: data) } catch {
            throw ClipError.badResponse("\(T.self): \(error.localizedDescription)")
        }
    }

    private func check(_ resp: HTTPURLResponse, _ body: Data) throws {
        guard (200..<300).contains(resp.statusCode) else {
            let env = try? ClipJSON.decoder().decode(ErrorEnvelope.self, from: body)
            throw ClipError.http(status: resp.statusCode, envelope: env)
        }
    }

    /// Sends a request, optionally with a body, retrying once on a dropped/refused connection.
    private func send(_ req: URLRequest, upload: Data? = nil, progress: ProgressHandler? = nil,
                      retry: Bool = true) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        while true {
            attempt += 1
            do {
                let (data, resp): (Data, URLResponse)
                if let upload {
                    let delegate = progress.map { UploadProgressDelegate($0) }
                    (data, resp) = try await session.upload(for: req, from: upload, delegate: delegate)
                    progress?(1)
                } else {
                    (data, resp) = try await session.data(for: req)
                }
                guard let http = resp as? HTTPURLResponse else { throw ClipError.badResponse("not HTTP") }
                return (data, http)
            } catch let e as URLError {
                let transient: Set<URLError.Code> = [.networkConnectionLost, .cannotConnectToHost]
                if retry, attempt == 1, transient.contains(e.code) {
                    try await Task.sleep(for: .milliseconds(400))
                    continue
                }
                if e.code == .cancelled { throw CancellationError() }
                throw ClipError.unreachable(e.localizedDescription)
            }
        }
    }
}

/// Per-task delegate that forwards upload progress.
final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    let handler: ProgressHandler
    init(_ handler: @escaping ProgressHandler) { self.handler = handler }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        handler(min(1, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
    }
}
