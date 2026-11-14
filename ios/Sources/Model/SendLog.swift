import Foundation
import Observation
import OSLog
import PixelClipKit

/// One line per step of every send and every Bluetooth look ("toggle → send → look → wake → join →
/// status → PUT"), kept in memory for Settings ▸ Advanced ▸ Send log and written to the unified log
/// (subsystem = the app's bundle id, category `sendlog`), so a send that "does nothing" can be read back
/// step by step.
///
/// In the unified log (which a sysdiagnose carries off the phone) the app's own wording is public; what
/// the clip said (its name, what it reports on screen, its error text) and anything named by the user
/// (a picture's id) is **private**: a hash there, readable in the in-app log.
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
    @ObservationIgnored private static let log = Logger(subsystem: AppLog.subsystem, category: "sendlog")

    /// - Parameters:
    ///   - text: the app's own words.
    ///   - peer: what a clip (or whatever answers as one) said, or a name the user chose: shown in the
    ///     in-app log after `text` (tidied: one line, at most `AppLog.peerLimit` characters), private in the unified log.
    ///   - suffix: more of the app's own words after it.
    func add(_ text: String, peer: String? = nil, then suffix: String = "", at date: Date = Date()) {
        let said = peer.map(AppLog.tidy) ?? ""
        let line = text + said + suffix
        lines.append(Line(id: next, at: date, text: line))
        next += 1
        if lines.count > Self.capacity { lines.removeFirst(lines.count - Self.capacity) }
        if peer == nil {
            Self.log.notice("\(line, privacy: .public)")
        } else {
            Self.log.notice("\(text, privacy: .public)\(said, privacy: .private(mask: .hash))\(suffix, privacy: .public)")
        }
        #if DEBUG
        print("SENDLOG \(line)")
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

/// Shorthand: `sendLog("look: not heard")`, `sendLog("look: near · ", peer: name)`.
@MainActor func sendLog(_ text: String, peer: String? = nil, then suffix: String = "") {
    SendLog.shared.add(text, peer: peer, then: suffix)
}

/// What every `Logger` in the app shares.
enum AppLog {
    /// The unified-log subsystem: the app's bundle id, whatever the builder made it.
    static let subsystem = Bundle.main.bundleIdentifier ?? "pixelclip"
    /// Characters kept of a string the clip sent.
    static let peerLimit = 96

    /// A string from outside (the clip's name, its error text) made safe for a log line or a label:
    /// control characters and line breaks out, and no longer than `peerLimit`.
    static func tidy(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        var count = 0
        for u in s.unicodeScalars {
            if count >= peerLimit { out.append("…"); break }
            switch u.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator:
                if u.properties.isWhitespace { out.append(" "); count += 1 }   // a tab or a line break reads as a space
            case .format where u.value != 0x200C && u.value != 0x200D:
                break   // direction overrides and the like (the joiners that scripts and emoji need stay)
            default:
                out.append(u); count += 1
            }
        }
        return String(out)
    }

    /// A request's route for the log: its kind in the app's words ("PUT /assets"), and the id after it
    /// (a picture's or text's id, which can carry the name the user gave it) to be kept private.
    static func routeParts(_ route: FastLaneRoute) -> (kind: String, id: String?) {
        let parts = route.path.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, ["assets", "texts", "fonts", "show"].contains(String(parts[0])) else { return (route.line, nil) }
        return ("\(route.method) /\(parts[0])", "/\(parts[1])")
    }
}
