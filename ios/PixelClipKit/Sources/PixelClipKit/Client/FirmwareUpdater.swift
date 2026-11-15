import Foundation

/// A firmware update with the clip's button gate (SECURITY-AUDIT WIFI-2): `POST /ota/ask` (the clip shows
/// "Update? press the button" for 60 s), then `GET /ota` about once a second until the press allowed it (or
/// the window ran out), then `POST /ota` as before. Firmware that predates the gate (404 on the ask or the
/// state) gets the upload at once. A `403 press_button` from the upload itself (the allowance ran out in
/// between) goes back to waiting for the press, once.
public struct FirmwareUpdater: Sendable {
    public enum Event: Equatable, Sendable {
        /// The clip is asking for its button: the seconds left in its window.
        case waitingForPress(secondsLeft: Int)
        /// The image is going up.
        case uploading(Double)
    }

    public enum Failure: Error, Equatable, Sendable {
        /// The window ran out before the button was pressed (nothing was changed on the clip).
        case notPressed
    }

    public let client: any ClipClient
    public var pollInterval: Duration
    /// How the wait between polls is made (tests: instant).
    public var sleep: @Sendable (Duration) async throws -> Void

    public init(client: any ClipClient, pollInterval: Duration = .seconds(1),
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.client = client
        self.pollInterval = pollInterval
        self.sleep = sleep
    }

    /// Runs the whole update. Throws `Failure.notPressed`, `CancellationError` (the task was cancelled while
    /// waiting), or the client's error.
    @MainActor
    public func run(_ firmware: Data, onEvent: @escaping @MainActor (Event) -> Void) async throws {
        let asked: OTAState
        do {
            asked = try await client.askOTA()
        } catch let e as ClipError where e.isNotFound {
            try await upload(firmware, onEvent)   // older firmware: no gate
            return
        }
        try await waitForPress(from: asked, onEvent)
        do {
            try await upload(firmware, onEvent)
        } catch let e as ClipError where e.isPressButton {
            // The allowance ran out before the upload: the clip asks again.
            let state = (try? await client.otaState()) ?? OTAState(allowed: false, asking: true, secondsLeft: 60)
            try await waitForPress(from: state, onEvent)
            try await upload(firmware, onEvent)
        }
    }

    @MainActor
    private func waitForPress(from initial: OTAState, _ onEvent: @escaping @MainActor (Event) -> Void) async throws {
        var state = initial
        // The clip's window decides; this only stops a clip that keeps saying "asking" forever.
        let interval = max(pollInterval.seconds, 0.001)
        var pollsLeft = Int((Double(max(state.secondsLeft, 1)) / interval).rounded(.up)) + 5
        while !state.allowed {
            guard state.asking, pollsLeft > 0 else { throw Failure.notPressed }
            onEvent(.waitingForPress(secondsLeft: max(0, state.secondsLeft)))
            try await sleep(pollInterval)
            try Task.checkCancellation()
            pollsLeft -= 1
            do {
                state = try await client.otaState()
            } catch let e as ClipError where e.isNotFound {
                return   // no gate after all: the upload decides
            }
        }
    }

    @MainActor
    private func upload(_ firmware: Data, _ onEvent: @escaping @MainActor (Event) -> Void) async throws {
        onEvent(.uploading(0))
        try await client.ota(firmware: firmware) { p in Task { @MainActor in onEvent(.uploading(p)) } }
    }
}
