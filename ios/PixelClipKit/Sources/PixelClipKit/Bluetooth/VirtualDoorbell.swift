import Foundation
import Observation

/// The simulator's doorbell: rings the `VirtualClipClient` directly. A wake resolves at once
/// (scanning → found → waking → hotspotUp) and flips the virtual clip into an upload session; a peek
/// reads its `status` characteristic. Out of range (`setBluetoothPresent(false)`), `ble_wake` off and
/// a battery under 3.5 V behave like the real clip. Its link carries the BLE fast lane
/// (`VirtualFastLane`), and while linked it re-reads the status every 2 s like the firmware's
/// notifications.
@MainActor @Observable
public final class VirtualDoorbell: DoorbellRinging {
    public private(set) var state: DoorbellState = .idle
    public private(set) var nearby: DoorbellNearby?

    @ObservationIgnored private let clip: VirtualClipClient
    @ObservationIgnored private let name: String
    @ObservationIgnored private let rssi: Int
    @ObservationIgnored private var linked = false
    @ObservationIgnored private var poll: Task<Void, Never>?
    /// The fast lane over this link (PROTOCOL §3b).
    @ObservationIgnored public let fastLane: VirtualFastLane

    public init(clip: VirtualClipClient, name: String = "PixelClip-7C1E", rssi: Int = -52, fastLaneTiming: VirtualFastLane.Timing = .realistic) {
        self.clip = clip
        self.name = name
        self.rssi = rssi
        fastLane = VirtualFastLane(clip: clip, timing: fastLaneTiming)
    }

    public var fastLaneLinked: Bool { linked && fastLane.isConnected }

    public func fastLaneLink() async -> (any FastLaneLink)? {
        guard state != .scanning, state != .waking, state != .accepted else { return nil }
        if !linked || !fastLane.isConnected {
            // Scan + connect + discovery.
            if fastLane.timing.connect > .zero { try? await Task.sleep(for: fastLane.timing.connect) }
            await peek()
        }
        guard linked else { return nil }
        fastLane.setConnected(true)
        return fastLane
    }

    /// The firmware notifies status changes while subscribed (checked every 2 s).
    private func startPolling() {
        guard poll == nil else { return }
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled, self.linked else { return }
                if let s = await self.clip.bleStatus() {
                    if self.nearby?.status != s { self.nearby?.status = s }
                } else {
                    self.drop()
                    self.nearby = nil
                }
            }
        }
    }

    private func drop() {
        poll?.cancel()
        poll = nil
        linked = false
        nearby?.linked = false
        fastLane.setConnected(false)
    }

    public var canScanSilently: Bool { true }
    @ObservationIgnored public var onLog: (@MainActor (String) -> Void)?

    public func wake() -> AsyncStream<DoorbellState> {
        let (stream, continuation) = AsyncStream.makeStream(of: DoorbellState.self)
        Task { await ring(continuation) }
        return stream
    }

    private func ring(_ continuation: AsyncStream<DoorbellState>.Continuation) async {
        defer { continuation.finish() }
        func emit(_ s: DoorbellState) { state = s; continuation.yield(s) }
        emit(.scanning)
        onLog?("bluetooth: wake requested")
        guard let status = await clip.bleStatus() else {
            onLog?("bluetooth: not heard (wake)")
            nearby = nil
            emit(.failed(.notFound))
            return
        }
        nearby = DoorbellNearby(name: name, rssi: rssi, status: status, info: clip.bleInfo, linked: true)
        emit(.found(name: name, rssi: rssi))
        emit(.waking)
        let result = await clip.bleWake()
        onLog?("bluetooth: wake → \(result)")
        if result == .woke { emit(.accepted) }
        nearby?.status = await clip.bleStatus()
        // Bluetooth is dropped once the Wi‑Fi is up (or the wake was refused).
        drop()
        switch result {
        case .woke, .alreadyActive: emit(.hotspotUp)
        case .lowBattery: emit(.failed(.lowBattery))
        case .notAdvertising: emit(.failed(.notFound))
        }
    }

    public func peek() async {
        guard let status = await clip.bleStatus() else {
            onLog?("bluetooth: not heard (virtual clip out of range or not advertising)")
            drop()
            nearby = nil
            return
        }
        onLog?("bluetooth: heard \(name) (\(rssi) dBm)\(linked ? ", link answers" : "")")
        linked = true
        nearby = DoorbellNearby(name: name, rssi: rssi, status: status, info: clip.bleInfo, linked: true)
        fastLane.setConnected(true)
        startPolling()
    }

    public func endSession() async -> Bool {
        guard linked, await clip.bleEnd() else { return false }
        nearby?.status = await clip.bleStatus()
        return true
    }

    public func release() {
        drop()
        if !state.isFinal { state = .idle }
    }

}
