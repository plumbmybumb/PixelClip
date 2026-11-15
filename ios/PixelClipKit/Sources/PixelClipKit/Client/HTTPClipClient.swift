import Foundation

/// Talks to the real clip over its SoftAP (`http://192.168.4.1`).
///
/// - Short timeouts (the clip is one hop away; a slow answer means it is gone).
/// - Retries a request once when the connection drops or can't be opened, which happens routinely
///   in the first second after iOS joins the hotspot.
/// - Bodies are sent with a `Content-Length` (no chunked transfer-encoding); URLSession streams
///   them in TCP-sized pieces and reports progress through the session's delegate.
/// - Every answer is read as it streams and cut off at a size limit for its route (`ResponseLimit`):
///   whatever answers at the clip's address can't make the app buffer more than the route calls for.
/// - Redirects are refused: the clip never sends one, and following one would re-send an upload to
///   another host on the network.
public final class HTTPClipClient: ClipClient {
    public static let defaultBaseURL = URL(string: "http://192.168.4.1")!

    /// The most bytes accepted in an answer, per kind of route. The firmware's own ceilings are far
    /// lower (a playlist is at most 16 KB, a font document 16 KB, the config 4 KB, the battery log a
    /// 64 KB ring), so nothing the clip really sends comes near these.
    public enum ResponseLimit {
        /// Every JSON answer: status, lists, playlist, config, fonts, error envelopes.
        public static let json = 256 << 10
        /// `GET /screenshot`: one 536×240 RGB565 frame, exactly.
        public static let screenshot = RGB565Frame.clipFrameBytes
        /// `GET /batlog`.
        public static let batteryLog = 1 << 20
        /// `GET /assets/{id}`: the clip's whole flash is smaller.
        public static let asset = 16 << 20
    }

    public let baseURL: URL
    private let session: URLSession
    private let exchanges = ClipExchanges()

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
        session = URLSession(configuration: cfg, delegate: exchanges, delegateQueue: nil)
    }

    deinit { session.finishTasksAndInvalidate() }   // a session keeps its delegate until it is invalidated

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
        let (body, resp) = try await send(req, limit: ResponseLimit.asset)
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
        let (body, resp) = try await send(req, limit: ResponseLimit.screenshot)
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
        do {
            let (body, resp) = try await send(req, upload: firmware, progress: progress, retry: false)
            try check(resp, body)
        } catch let error as ClipError where error.isUnreachable {
            // A clip with the update gate answers `403 press_button` before reading the body and may close
            // the connection while the image is still going out, which URLSession reports as a dropped
            // connection. Ask the gate: not allowed means that answer.
            if let gate = try? await otaState(), !gate.allowed {
                throw ClipError.http(status: 403, envelope: ErrorEnvelope(error: "press_button", message: "Press the button on the clip to allow the update."))
            }
            throw error
        }
    }

    public func otaState() async throws -> OTAState { try await json(.get, "/ota") }

    public func askOTA() async throws -> OTAState { try await json(.post, "/ota/ask") }

    public func endSession() async throws {
        let _: OKResponse = try await json(.post, "/session/end")
    }

    public func scenes() async throws -> SceneCatalog { try await json(.get, "/scenes") }

    public func batteryLog() async throws -> String {
        let (body, resp) = try await send(request(.get, "/batlog"), limit: ResponseLimit.batteryLog)
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

    /// Sends a request, optionally with a body, retrying once on a dropped/refused connection. The
    /// answer is refused (`badResponse`) past `limit` bytes, or if it is a redirect.
    private func send(_ req: URLRequest, upload: Data? = nil, progress: ProgressHandler? = nil,
                      retry: Bool = true, limit: Int = ResponseLimit.json) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        while true {
            attempt += 1
            do {
                let task = upload.map { session.uploadTask(with: req, from: $0) } ?? session.dataTask(with: req)
                let (data, resp) = try await exchanges.run(task, limit: limit, progress: upload == nil ? nil : progress)
                if upload != nil { progress?(1) }
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

/// The clip session's delegate: collects each answer as it arrives and stops at the route's size limit,
/// refuses redirects, and forwards upload progress.
final class ClipExchanges: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct Exchange {
        var limit: Int
        var progress: ProgressHandler?
        var body = Data()
        var response: URLResponse?
        var refusal: String?
        var continuation: CheckedContinuation<(Data, URLResponse), any Error>
    }

    private let lock = NSLock()
    private var open: [Int: Exchange] = [:]

    /// Runs `task` to its end; throws `ClipError.badResponse` for an oversized answer or a redirect.
    func run(_ task: URLSessionTask, limit: Int, progress: ProgressHandler?) async throws -> (Data, URLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock { open[task.taskIdentifier] = Exchange(limit: limit, progress: progress, continuation: continuation) }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private func refuse(_ task: URLSessionTask, _ why: String) {
        lock.withLock { if open[task.taskIdentifier]?.refusal == nil { open[task.taskIdentifier]?.refusal = why } }
        task.cancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
        refuse(task, "a redirect (HTTP \(response.statusCode))")
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let limit = lock.withLock { () -> Int in
            open[dataTask.taskIdentifier]?.response = response
            return open[dataTask.taskIdentifier]?.limit ?? 0
        }
        if response.expectedContentLength > Int64(limit) {
            completionHandler(.cancel)
            refuse(dataTask, "an answer of \(response.expectedContentLength) bytes (at most \(limit) expected)")
        } else {
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let limit = lock.withLock { () -> Int? in
            guard var e = open[dataTask.taskIdentifier], e.refusal == nil else { return nil }
            e.body.append(data)
            open[dataTask.taskIdentifier] = e
            return e.body.count > e.limit ? e.limit : nil
        }
        if let limit { refuse(dataTask, "an answer of more than \(limit) bytes") }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0, let handler = lock.withLock({ open[task.taskIdentifier]?.progress }) else { return }
        handler(min(1, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let e = lock.withLock({ open.removeValue(forKey: task.taskIdentifier) }) else { return }
        if let why = e.refusal { e.continuation.resume(throwing: ClipError.badResponse(why)); return }
        if let error { e.continuation.resume(throwing: error); return }
        guard let response = e.response else { e.continuation.resume(throwing: ClipError.badResponse("no answer")); return }
        e.continuation.resume(returning: (e.body, response))
    }
}
