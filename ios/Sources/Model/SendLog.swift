import Foundation
import Observation
import OSLog

/// One line per step of every send and every Bluetooth look ("toggle → send → look → wake → join →
/// status → PUT"), kept in memory for Settings ▸ Advanced ▸ Send log and written to the unified log
/// (`com.example.pixelclip`, category `sendlog`), so a send that "does nothing" can be read back step by step.
@MainActor @Observable
final class SendLog {
    static let shared = SendLog()

    struct Line: Identifiable, Equatable {
        let id: Int
        let at: Date
        let text: String
    }

    private(set) var lines: [Line] = []
    @ObservationIgnored private var next = 0
    /// Lines kept (the oldest go first).
    static let capacity = 400
    @ObservationIgnored private static let log = Logger(subsystem: "com.example.pixelclip", category: "sendlog")

    func add(_ text: String, at date: Date = Date()) {
        lines.append(Line(id: next, at: date, text: text))
        next += 1
        if lines.count > Self.capacity { lines.removeFirst(lines.count - Self.capacity) }
        Self.log.notice("\(text, privacy: .public)")
        #if DEBUG
        print("SENDLOG \(text)")
        #endif
    }

    func clear() { lines = [] }

    /// "14:02:07.3  look: heard PixelClip-7C1E (−58 dBm)" per line, oldest first.
    var text: String { lines.map { "\(Self.stamp($0.at))  \($0.text)" }.joined(separator: "\n") }

    static func stamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.S"
        return f.string(from: d)
    }
}

/// Shorthand: `sendLog("look: not heard")`.
@MainActor func sendLog(_ text: String) { SendLog.shared.add(text) }
