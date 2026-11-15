import Foundation

/// The virtual clip's end of the BLE fast lane (PROTOCOL §3b), as a `FastLaneLink`: it reassembles
/// the request frames `BLETransport` writes, runs the request on the `VirtualClipClient` through the
/// same route table as HTTP (`VirtualClipClient.transport = .bluetooth`: no session, no idle timer,
/// works with the Wi‑Fi off) and notifies the response in frames, with the firmware's protocol
/// answers: `400 bad_frame` on a sequence gap, `429 busy` for a request sent before the previous
/// response finished, `413 use_wifi` for the bulk routes and for responses over 16 KB.
///
/// `Timing.realistic` paces it like a phone link (MTU 185, a write-without-response burst of 4 frames
/// per 30 ms connection event, a few ms of handler), so the simulator feels the fast lane's speed;
/// `.instant` (tests) keeps the same flow control with no waiting.
@MainActor
public final class VirtualFastLane: FastLaneLink {
    public struct Timing: Sendable {
        public var mtu: Int
        public var connectionInterval: Duration
        /// Write-without-response packets per connection event (both directions).
        public var framesPerEvent: Int
        /// The clip's handler time (validation, a LittleFS write).
        public var handler: Duration
        /// Scan + connect + discovery when the link isn't up yet.
        public var connect: Duration

        public init(mtu: Int = 185, connectionInterval: Duration = .milliseconds(30), framesPerEvent: Int = 4,
                    handler: Duration = .milliseconds(15), connect: Duration = .milliseconds(700)) {
            self.mtu = mtu; self.connectionInterval = connectionInterval; self.framesPerEvent = max(1, framesPerEvent)
            self.handler = handler; self.connect = connect
        }

        public static let realistic = Timing()
        public static let instant = Timing(connectionInterval: .zero, handler: .zero, connect: .zero)
    }

    public let clip: VirtualClipClient
    public var timing: Timing
    public var onEvent: ((FastLaneLinkEvent) -> Void)?
    public private(set) var isConnected = false
    public private(set) var isSubscribed = false
    public private(set) var canSendWriteWithoutResponse = true
    public var maximumWriteLength: Int { timing.mtu - 3 }
    /// Requests answered, "PUT /playlist -> 200" (debug, tests).
    public private(set) var served: [String] = []

    private var writesThisEvent = 0
    private var eventTimer: Task<Void, Never>?
    private var rx = BLEFrameReassembler()
    private var dropping = false
    private var responding = false
    private var pendingBusy = 0

    public init(clip: VirtualClipClient, timing: Timing = .realistic) {
        self.clip = clip
        self.timing = timing
    }

    /// The doorbell linked (true) or dropped (false) the connection.
    public func setConnected(_ connected: Bool) {
        guard connected != isConnected else { return }
        isConnected = connected
        if !connected {
            isSubscribed = false
            rx.reset()
            canSendWriteWithoutResponse = true
            writesThisEvent = 0
            post(.disconnected)
        }
    }

    public func subscribe() {
        let ok = isConnected
        isSubscribed = ok
        post(.subscribed(ok))
    }

    public func write(_ frame: Data) {
        guard isConnected else { return }
        pace()
        do {
            if frame.first.map({ $0 & PixelClipBLE.frameFirst != 0 }) == true { dropping = false }
            guard !dropping else { return }
            if let message = try rx.push(frame) { received(message) }
        } catch {
            // One `400 bad_frame` (plain text), then frames are dropped until the next first frame.
            dropping = true
            respond(FastLaneResponse(status: 400, body: Data("bad_frame".utf8)))
        }
    }

    // MARK: Flow control

    /// Each write takes a slot in the current connection event; a full event makes the writer wait
    /// for `readyToSend` (CoreBluetooth's `canSendWriteWithoutResponse` / `peripheralIsReady`).
    private func pace() {
        writesThisEvent += 1
        guard writesThisEvent >= timing.framesPerEvent else { return }
        canSendWriteWithoutResponse = false
        eventTimer?.cancel()
        eventTimer = Task { [weak self, interval = timing.connectionInterval] in
            if interval > .zero { try? await Task.sleep(for: interval) } else { await Task.yield() }
            guard let self, !Task.isCancelled else { return }
            self.writesThisEvent = 0
            self.canSendWriteWithoutResponse = true
            self.onEvent?(.readyToSend)
        }
    }

    // MARK: Requests

    private func received(_ message: Data) {
        guard !responding else {
            // One request in flight: answered 429 after the running response.
            pendingBusy += 1
            return
        }
        responding = true
        Task { [weak self] in
            guard let self else { return }
            // The last frames ride on the next connection event.
            if self.timing.connectionInterval > .zero { try? await Task.sleep(for: self.timing.connectionInterval) }
            let request = FastLaneRequest(decoding: message)
            let response = await Self.respond(to: request, clip: self.clip)
            if self.timing.handler > .zero { try? await Task.sleep(for: self.timing.handler) }
            if let request { self.served.append("\(request.route.line) -> \(response.status)") }
            // `PUT /config {"ble_wake":false}` switches the radio off: the response is lost.
            guard await self.clip.isAdvertising else {
                self.responding = false
                self.setConnected(false)
                return
            }
            await self.notify(response)
            while self.pendingBusy > 0 {
                self.pendingBusy -= 1
                await self.notify(FastLaneResponse(status: 429, body: Self.envelope("busy", "One request at a time over Bluetooth.")))
            }
            self.responding = false
        }
    }

    private func respond(_ response: FastLaneResponse) {
        Task { [weak self] in await self?.notify(response) }
    }

    /// Notifies the response frames, `framesPerEvent` per connection event.
    private func notify(_ response: FastLaneResponse) async {
        let frames = BLEFrameCodec.frames(response.encoded, maxFrame: maximumWriteLength)
        for (i, frame) in frames.enumerated() {
            if i > 0, i % timing.framesPerEvent == 0 {
                if timing.connectionInterval > .zero { try? await Task.sleep(for: timing.connectionInterval) } else { await Task.yield() }
            }
            guard isConnected, isSubscribed else { return }
            onEvent?(.notified(frame))
        }
    }

    private func post(_ event: FastLaneLinkEvent) {
        Task { [weak self] in self?.onEvent?(event) }
    }

    // MARK: The clip's route table (the firmware's `api_ble.c` → `http_api.c`)

    static func envelope(_ code: String, _ message: String) -> Data {
        (try? ClipJSON.encoder().encode(ErrorEnvelope(error: code, message: message))) ?? Data()
    }

    /// Runs one fast-lane request on the virtual clip and answers it as the firmware would.
    public static func respond(to request: FastLaneRequest?, clip: VirtualClipClient) async -> FastLaneResponse {
        guard let request else { return FastLaneResponse(status: 400, body: envelope("bad_request", "Malformed request line.")) }
        if request.route.isBulk || request.route.isWiFiOnly {
            return FastLaneResponse(status: 413, body: envelope("use_wifi", "Bulk transfers need the clip’s Wi‑Fi."))
        }
        if request.body.count > PixelClipBLE.apiMaxBytes {
            return FastLaneResponse(status: 413, body: envelope("too_large", "At most 16 KB over Bluetooth."))
        }
        let response: FastLaneResponse
        do {
            response = try await VirtualClipClient.$transport.withValue(.bluetooth) {
                try await route(request, clip: clip)
            }
        } catch let ClipError.http(status, env) {
            response = FastLaneResponse(status: status, body: env.map { (try? ClipJSON.encoder().encode($0)) ?? Data() } ?? Data())
        } catch let ClipError.unreachable(why) {
            response = FastLaneResponse(status: 503, body: envelope("busy", why))
        } catch is DecodingError {
            response = FastLaneResponse(status: 400, body: envelope("bad_request", "Invalid JSON."))
        } catch {
            response = FastLaneResponse(status: 500, body: envelope("internal", error.localizedDescription))
        }
        if response.body.count > PixelClipBLE.apiMaxBytes {
            return FastLaneResponse(status: 413, body: envelope("use_wifi", "The answer is over 16 KB: use the clip’s Wi‑Fi."))
        }
        return response
    }

    private static func route(_ r: FastLaneRequest, clip: VirtualClipClient) async throws -> FastLaneResponse {
        let dec = ClipJSON.decoder()
        func body<T: Decodable>(_ t: T.Type) throws -> T { try dec.decode(T.self, from: r.body) }
        func ok<T: Encodable>(_ value: T) throws -> FastLaneResponse { FastLaneResponse(status: 200, body: try ClipJSON.answerEncoder().encode(value)) }
        let done = try ok(OKResponse())
        let path = r.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? r.path
        let parts = path.split(separator: "/").map(String.init)
        switch (r.method, parts.first ?? "", parts.count) {
        case ("GET", "status", 1): return try ok(await clip.status())
        case ("GET", "assets", 1): return try ok(AssetList(assets: await clip.assets()))
        case ("DELETE", "assets", 2): try await clip.deleteAsset(id: parts[1]); return done
        case ("GET", "playlist", 1): return try ok(await clip.playlist())
        case ("PUT", "playlist", 1): try await clip.putPlaylist(body(Playlist.self)); return done
        case ("GET", "config", 1): return try ok(await clip.config())
        case ("PUT", "config", 1): return try ok(await clip.putConfig(body(ClipConfig.self)))
        case ("POST", "time", 1): try await clip.setTime(body(TimeSync.self)); return done
        case ("POST", "show", 2):
            let show = r.body.isEmpty ? ShowRequest() : try body(ShowRequest.self)
            try await clip.show(id: parts[1], durationMs: show.durationMs, scroll: show.scroll)
            return done
        case ("POST", "next", 1): try await clip.next(); return done
        case ("POST", "prev", 1): try await clip.previous(); return done
        case ("POST", "brightness", 1): try await clip.setBrightness(body(BrightnessRequest.self).value); return done
        case ("POST", "session", 2) where parts[1] == "end": try await clip.endSession(); return done
        case ("GET", "scenes", 1): return try ok(await clip.scenes())
        case ("DELETE", "batlog", 1): try await clip.clearBatteryLog(); return done
        case ("GET", "texts", 1): return try ok(TextList(texts: await clip.texts()))
        case ("DELETE", "texts", 2): try await clip.deleteText(id: parts[1]); return done
        case ("PUT", "fonts", 2): try await clip.putFont(id: parts[1], body(ReaderFontDocument.self)); return done
        case ("GET", "fonts", 2): return try ok(await clip.font(id: parts[1]))
        case ("GET", "reader", 1): return try ok(await clip.reader())
        case ("POST", "reader", 1): try await clip.readerControl(body(ReaderCommand.self)); return done
        case ("POST", "oracle", 2) where parts[1] == "draw":
            let draw = r.body.isEmpty ? OracleDrawRequest() : try body(OracleDrawRequest.self)
            try await clip.oracleDraw(cards: draw.cards)
            return done
        case ("POST", "oracle", 2) where parts[1] == "turn":
            try await clip.oracleTurn()
            return done
        case ("POST", "oracle", 2) where parts[1] == "back":
            try await clip.oracleBack()
            return done
        case ("GET", "ota", 1): return try ok(await clip.otaState())
        case ("GET", "imu", 1): return try ok(await clip.imu())
        case ("POST", "imu", 2) where parts[1] == "calibrate":
            return try ok(await clip.calibrateIMU(body(IMUCalibrationRequest.self).step))
        default:
            let known = ["status", "assets", "playlist", "config", "time", "show", "next", "prev", "brightness",
                         "session", "scenes", "batlog", "texts", "fonts", "reader", "imu", "oracle", "ota"]
            return known.contains(parts.first ?? "")
                ? FastLaneResponse(status: 405, body: envelope("method_not_allowed", "\(r.method) isn’t allowed on \(path)."))
                : FastLaneResponse(status: 404, body: envelope("not_found", "No route \(path)."))
        }
    }
}
