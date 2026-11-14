import Foundation
import OSLog
import PixelClipKit

/// The app's answers to `SmartClipClient` (PixelClipKit `ClipLinks`): Wi‑Fi is open when the hotspot is
/// joined; the fast lane is the doorbell's Bluetooth link (linking to the nearby clip if needed,
/// through the doorbell's scan) while Settings ▸ Bluetooth Wake is on; Wi‑Fi opens through the
/// doorbell + hotspot path — or through the send sheet's own steps while one is running.
@MainActor
final class ClipLinkBroker: ClipLinks {
    private let doorbell: any DoorbellRinging
    private let joiner: HotspotJoiner
    /// Called after the hotspot is joined (the session drops Bluetooth then).
    var onJoined: (() -> Void)?
    /// A send sheet installs this while it runs, so opening Wi‑Fi mid-send shows in its rows.
    var wifiOpener: (@MainActor () async throws -> Void)?
    /// Every routed request (the send sheets count Bluetooth vs Wi‑Fi from it).
    var onRoute: ((ClipRouteRecord) -> Void)?
    private(set) var lastRoute: ClipRouteRecord?

    private var transport: BLETransport?
    private var lane: FastLaneClipClient?
    static let log = Logger(subsystem: "com.example.pixelclip", category: "fastlane")

    init(doorbell: any DoorbellRinging, joiner: HotspotJoiner) {
        self.doorbell = doorbell
        self.joiner = joiner
    }

    var wifiOpen: Bool { joiner.state == .joined }

    func fastLane() async -> (any ClipClient)? {
        // Waking or joining means Wi‑Fi is on its way: let it.
        guard AppSettings.shared.bluetoothWake, joiner.state != .waking, joiner.state != .joining else { return nil }
        guard let link = await doorbell.fastLaneLink() else { return nil }
        if let transport, transport.link === link, let lane { return lane }
        let t = BLETransport(link: link)
        t.onExchange = { e in
            Self.log.notice("fast lane: \(e.summary, privacy: .public)")
            #if DEBUG
            print("FASTLANE \(e.summary)")
            #endif
        }
        transport = t
        let l = FastLaneClipClient(transport: t)
        lane = l
        return l
    }

    func openWiFi() async throws {
        if let wifiOpener { try await wifiOpener(); return }
        joiner.bluetoothWake = AppSettings.shared.bluetoothWake
        guard await joiner.connect() == .joined else {
            throw ClipError.unreachable(joiner.message ?? "Couldn’t join the clip’s Wi‑Fi.")
        }
        onJoined?()
    }

    func routed(_ record: ClipRouteRecord) {
        lastRoute = record
        onRoute?(record)
    }
}
