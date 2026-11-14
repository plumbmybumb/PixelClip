import Foundation

// MARK: - The link (CoreBluetooth's peripheral, the virtual clip, or a test fake)

/// What a link reports. Never sent from inside a call into the link (always on a later main-actor turn).
public enum FastLaneLinkEvent: Equatable, Sendable {
    /// `setNotifyValue(true, for: rsp)` finished (false: refused).
    case subscribed(Bool)
    /// One `rsp` notification: a response frame.
    case notified(Data)
    /// `peripheralIsReady(toSendWriteWithoutResponse:)`: room for more writes.
    case readyToSend
    case disconnected
}

/// One connected clip whose `req` / `rsp` characteristics were found: the doorbell's link
/// (`CoreBluetoothRadio`), or `VirtualFastLane`.
@MainActor
public protocol FastLaneLink: AnyObject {
    /// Largest write without response: ATT MTU − 3 (`maximumWriteValueLength(for: .withoutResponse)`).
    var maximumWriteLength: Int { get }
    /// CoreBluetooth's `canSendWriteWithoutResponse`: false while its queue is full.
    var canSendWriteWithoutResponse: Bool { get }
    var isConnected: Bool { get }
    /// Notifications on `rsp` are on.
    var isSubscribed: Bool { get }
    var onEvent: ((FastLaneLinkEvent) -> Void)? { get set }
    /// Turn `rsp` notifications on; answers `.subscribed`.
    func subscribe()
    /// One frame to `req`, write without response.
    func write(_ frame: Data)
}

/// Sends one fast-lane request and returns the clip's response (`BLETransport`, or a test double).
public protocol FastLaneTransporting: Sendable {
    func send(_ request: FastLaneRequest) async throws -> FastLaneResponse
}

/// Why the fast lane couldn't carry a request.
public enum FastLaneError: Error, Equatable, Sendable {
    /// No fast lane right now: Bluetooth off or not allowed, the clip not linked, firmware without
    /// the `req`/`rsp` characteristics, or `rsp` notifications refused. Nothing was sent.
    case unavailable
    /// A bulk transfer (or the clip answered `413 use_wifi`): use the doorbell + hotspot.
    case needsWiFi
    /// No complete response within the timeout (5 s); the transport was reset.
    case timeout
    /// The link dropped during the exchange.
    case disconnected
    /// The response frames were malformed.
    case badFrames(String)

    /// Nothing reached the clip, or it refused to run the request: safe to send it over Wi‑Fi.
    public var nothingRan: Bool { self == .unavailable || self == .needsWiFi }
}

extension FastLaneError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unavailable: "The clip can’t be reached over Bluetooth."
        case .needsWiFi: "This needs the clip’s Wi‑Fi."
        case .timeout: "The clip didn’t answer over Bluetooth."
        case .disconnected: "The Bluetooth link dropped."
        case .badFrames(let why): "Garbled answer over Bluetooth (\(why))."
        }
    }
}

/// One request/response over the fast lane, for the log and the send sheet.
public struct FastLaneExchange: Sendable, Equatable {
    public var route: FastLaneRoute
    public var status: Int
    public var framesUp: Int
    public var framesDown: Int
    public var bytesUp: Int
    public var bytesDown: Int
    /// Frame size used (ATT MTU − 3).
    public var frameSize: Int
    /// 2 when a 429 / 503 was retried.
    public var attempts: Int
    public var seconds: Double

    /// "PUT /playlist → 200, 2048 B up in 12 frames, 11 B back, 0.24 s (MTU 185)".
    public var summary: String {
        "\(route.line) → \(status), \(bytesUp) B up in \(framesUp) frame\(framesUp == 1 ? "" : "s"), \(bytesDown) B back, "
            + String(format: "%.2f s", seconds) + " (MTU \(frameSize + 3)\(attempts > 1 ? ", retried" : ""))"
    }
}

// MARK: - The transport

/// The fast lane over one link (PROTOCOL §3b): subscribes to `rsp`, sends one request at a time
/// (others wait their turn), writes the frames without response at the link's frame size while
/// `canSendWriteWithoutResponse` allows, reassembles the notified response, and answers the status
/// and body exactly as the HTTP endpoint would. A `429 busy` or `503 busy` is retried once after
/// 300 ms. No complete answer within 5 s → `FastLaneError.timeout` and a clean reset (half-received
/// frames dropped; late frames of the abandoned response are ignored).
@MainActor
public final class BLETransport: FastLaneTransporting {
    public struct Timings: Sendable {
        /// From the first frame written to the last response frame.
        public var response: Duration
        /// Before the one retry of a 429 / 503.
        public var retryDelay: Duration
        /// For `rsp` notifications to switch on.
        public var subscribe: Duration

        public init(response: Duration = .seconds(5), retryDelay: Duration = .milliseconds(300), subscribe: Duration = .seconds(2)) {
            self.response = response; self.retryDelay = retryDelay; self.subscribe = subscribe
        }
        public static let standard = Timings()
    }

    public let link: any FastLaneLink
    public let timings: Timings
    /// The last completed exchange.
    public private(set) var lastExchange: FastLaneExchange?
    /// Timeouts / drops that reset the transport (tests, debug).
    public private(set) var resets = 0
    /// Every completed exchange (the app logs them).
    public var onExchange: ((FastLaneExchange) -> Void)?

    private var busy = false
    private var queue: [CheckedContinuation<Void, Never>] = []
    private var reassembler = BLEFrameReassembler()
    private var attemptID = 0
    private var active: Int?
    private var failure: FastLaneError?
    private var received: Data?
    private var framesDown = 0
    private var responseWaiter: CheckedContinuation<Data, any Error>?
    private var readyWaiter: CheckedContinuation<Void, any Error>?
    private var subscribeWaiter: CheckedContinuation<Void, any Error>?

    public init(link: any FastLaneLink, timings: Timings = .standard) {
        self.link = link
        self.timings = timings
        link.onEvent = { [weak self] e in self?.handle(e) }
    }

    public nonisolated func send(_ request: FastLaneRequest) async throws -> FastLaneResponse {
        try await exchange(request)
    }

    /// One request, in turn behind any already queued.
    public func exchange(_ request: FastLaneRequest) async throws -> FastLaneResponse {
        await acquire()
        defer { relinquish() }
        let clock = ContinuousClock()
        let start = clock.now
        var attempts = 1
        var (response, up) = try await attempt(request)
        if response.status == 429 || response.status == 503 {
            // One request in flight on the clip (429), or a Wi‑Fi upload holds the handlers (503).
            try? await Task.sleep(for: timings.retryDelay)
            attempts = 2
            (response, up) = try await attempt(request)
        }
        let size = max(2, link.maximumWriteLength)
        let e = FastLaneExchange(route: request.route, status: response.status, framesUp: up, framesDown: framesDown,
                                 bytesUp: request.encoded.count, bytesDown: response.body.count, frameSize: size,
                                 attempts: attempts, seconds: (clock.now - start).seconds)
        lastExchange = e
        onExchange?(e)
        return response
    }

    // MARK: Turn-taking

    private func acquire() async {
        guard busy else { busy = true; return }
        await withCheckedContinuation { queue.append($0) }   // relinquish() hands over with busy still set
    }

    private func relinquish() {
        if queue.isEmpty { busy = false } else { queue.removeFirst().resume() }
    }

    // MARK: One attempt

    private func attempt(_ request: FastLaneRequest) async throws -> (FastLaneResponse, Int) {
        guard link.isConnected else { throw FastLaneError.unavailable }
        if !link.isSubscribed { try await subscribe() }
        attemptID += 1
        let id = attemptID
        active = id
        failure = nil
        received = nil
        framesDown = 0
        reassembler.reset()
        let frames = BLEFrameCodec.frames(request.encoded, maxFrame: link.maximumWriteLength)
        let timer = Task { [weak self, timeout = timings.response] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.fail(id, .timeout)
        }
        defer {
            timer.cancel()
            if active == id { active = nil }
        }
        do {
            for frame in frames {
                try await waitUntilCanSend()
                link.write(frame)
            }
            let message = try await awaitResponse()
            do {
                return (try FastLaneResponse(decoding: message), frames.count)
            } catch {
                throw FastLaneError.badFrames("no status line")
            }
        } catch let error as FastLaneError {
            cleanReset()
            throw error
        }
    }

    private func subscribe() async throws {
        let timer = Task { [weak self, wait = timings.subscribe] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            self?.resolveSubscribe(.failure(FastLaneError.unavailable))
        }
        defer { timer.cancel() }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
            subscribeWaiter = c
            link.subscribe()
        }
    }

    private func waitUntilCanSend() async throws {
        while true {
            if let failure { throw failure }
            if link.canSendWriteWithoutResponse { return }
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in readyWaiter = c }
        }
    }

    private func awaitResponse() async throws -> Data {
        if let message = received {
            received = nil
            return message
        }
        if let failure { throw failure }
        return try await withCheckedThrowingContinuation { responseWaiter = $0 }
    }

    /// The attempt is over without an answer: wake whatever it waits on.
    private func fail(_ id: Int, _ error: FastLaneError) {
        guard active == id, failure == nil else { return }
        failure = error
        readyWaiter?.resume(throwing: error)
        readyWaiter = nil
        responseWaiter?.resume(throwing: error)
        responseWaiter = nil
    }

    private func cleanReset() {
        resets += 1
        reassembler.reset()
        received = nil
        active = nil
    }

    private func resolveSubscribe(_ result: Result<Void, FastLaneError>) {
        guard let w = subscribeWaiter else { return }
        subscribeWaiter = nil
        switch result {
        case .success: w.resume()
        case .failure(let e): w.resume(throwing: e)
        }
    }

    // MARK: Link events

    private func handle(_ event: FastLaneLinkEvent) {
        switch event {
        case .subscribed(let ok):
            resolveSubscribe(ok ? .success(()) : .failure(.unavailable))
        case .readyToSend:
            readyWaiter?.resume()
            readyWaiter = nil
        case .disconnected:
            resolveSubscribe(.failure(.unavailable))
            if let id = active { fail(id, .disconnected) }
        case .notified(let frame):
            // No request in flight (a response we gave up on, still arriving): dropped.
            guard active != nil, failure == nil, received == nil else { return }
            framesDown += 1
            do {
                if let message = try reassembler.push(frame) { deliver(message) }
            } catch BLEFrameError.strayContinuation {
                // The tail of an abandoned response: ignored.
            } catch {
                if let id = active { fail(id, .badFrames(String(describing: error))) }
            }
        }
    }

    private func deliver(_ message: Data) {
        if let w = responseWaiter {
            responseWaiter = nil
            w.resume(returning: message)
        } else {
            received = message
        }
    }
}

extension Duration {
    /// Whole duration in seconds, as a Double.
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
