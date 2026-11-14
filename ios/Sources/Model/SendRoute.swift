import Foundation
import PixelClipKit

/// How a send reached the clip: the send sheets' badge.
enum SendRoute: Equatable {
    /// Everything went over the Bluetooth fast lane (no hotspot, no "WiFi:" splash).
    case bluetooth
    /// Started over Bluetooth, then new pictures needed the clip's Wi‑Fi.
    case bluetoothThenWiFi
    /// The doorbell + hotspot path.
    case wifi

    var label: String {
        switch self {
        case .bluetooth: "Bluetooth"
        case .bluetoothThenWiFi: "Bluetooth + Wi‑Fi"
        case .wifi: "Wi‑Fi"
        }
    }

    var systemImage: String {
        switch self {
        case .bluetooth, .bluetoothThenWiFi: "dot.radiowaves.left.and.right"
        case .wifi: "wifi"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .bluetooth: "Sent over Bluetooth"
        case .bluetoothThenWiFi: "Sent over Bluetooth, pictures over Wi‑Fi"
        case .wifi: "Sent over Wi‑Fi"
        }
    }
}

/// Per-row timings for a send sheet: a row's clock starts when it first turns active and stops when
/// it's done, skipped or failed ("0.12 s" at the row's end).
struct PhaseClock<Phase: Hashable> {
    private var started: [Phase: Date] = [:]
    private(set) var seconds: [Phase: Double] = [:]

    mutating func reset() {
        started = [:]
        seconds = [:]
    }

    /// `active`: the row is working; `final`: done, skipped or failed.
    mutating func observe(_ phase: Phase, active: Bool, final: Bool, now: Date = Date()) {
        if active, started[phase] == nil { started[phase] = now; seconds[phase] = nil }
        if final, let s = started[phase], seconds[phase] == nil { seconds[phase] = now.timeIntervalSince(s) }
    }
}
