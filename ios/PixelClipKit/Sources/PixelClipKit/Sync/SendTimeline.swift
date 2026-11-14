import Foundation

/// Per-step timestamps for one send (the SyncSheet's Debug readout and the `send` log line):
/// "wake 1.2 s · join 3.4 s · upload 0.8 s · total 6.1 s".
///
/// Steps may overlap (the join starts as soon as the wake write is acknowledged), so each step keeps
/// its own start and end; `total` runs from `begin()` to `finish()` (the sheet closing), and work done
/// after that (ending the session in the background) is reported separately as `after`.
public struct SendTimeline: Sendable, Equatable {
    public enum Step: String, Sendable, CaseIterable {
        case font
        /// Linking over Bluetooth for the fast lane (PROTOCOL §3b).
        case bluetooth
        case wake
        case join
        case connect
        case upload
        case end
    }

    public struct Span: Sendable, Equatable {
        public var start: Date
        public var end: Date?
        public var seconds: Double? { end.map { $0.timeIntervalSince(start) } }
    }

    public private(set) var started: Date?
    public private(set) var finished: Date?
    public private(set) var spans: [Step: Span] = [:]

    public init() {}

    public mutating func begin(at date: Date = Date()) {
        self = SendTimeline()
        started = date
    }

    public mutating func start(_ step: Step, at date: Date = Date()) {
        spans[step] = Span(start: date, end: nil)
    }

    /// Ends a step (starting it now if it never started: a zero-length step).
    public mutating func end(_ step: Step, at date: Date = Date()) {
        if spans[step] == nil { spans[step] = Span(start: date, end: nil) }
        if spans[step]?.end == nil { spans[step]?.end = date }
    }

    /// The person's wait is over (the sheet closes or shows its result).
    public mutating func finish(at date: Date = Date()) {
        if finished == nil { finished = date }
    }

    public var total: Double? {
        guard let started, let finished else { return nil }
        return finished.timeIntervalSince(started)
    }

    public func seconds(_ step: Step) -> Double? { spans[step]?.seconds }

    /// "wake 1.2 s · join 3.4 s · upload 0.8 s · total 6.1 s" (steps that ran, in order; the
    /// background session end last, in parentheses).
    public var summary: String {
        var parts: [String] = []
        for step in Step.allCases where step != .end {
            if let s = seconds(step) { parts.append("\(step.rawValue) \(Self.format(s))") }
        }
        if let total { parts.append("total \(Self.format(total))") }
        var line = parts.joined(separator: " · ")
        if let e = seconds(.end) { line += line.isEmpty ? "end \(Self.format(e))" : " (end \(Self.format(e)) after)" }
        return line
    }

    public static func format(_ s: Double) -> String {
        s < 10 ? String(format: "%.2f s", s) : String(format: "%.1f s", s)
    }
}
