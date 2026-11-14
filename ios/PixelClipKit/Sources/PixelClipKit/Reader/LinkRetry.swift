import Foundation

/// What to do with a shared link that couldn't be fetched: ask again at a later launch, or give up.
///
/// A link is asked for a few times at most (`maxAttempts`), not at every launch for a day: a site that
/// keeps failing isn't told each time the app is opened. Being offline doesn't count as a try (nothing
/// was asked of the site), so a link shared on the underground is still there when the phone is back
/// online; an answer that will be the same next time (not a web page, no text, too big, "404") is final.
public enum LinkRetry {
    public static let maxAttempts = 3
    /// A link nobody could fetch for this long is dropped.
    public static let maxAge: TimeInterval = 86_400

    public enum Decision: Sendable, Equatable {
        case drop
        /// Keep it for a later launch, with this many tries used.
        case keep(attempts: Int)
    }

    /// No route to anywhere: the request never left the phone.
    static let offline: Set<URLError.Code> = [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
                                              .internationalRoamingOff, .callIsActive]

    public static func decide(after error: any Error, attempts: Int, age: TimeInterval) -> Decision {
        if let e = error as? TextImportError {
            switch e {
            case .empty, .unsupported, .unreadable, .tooLarge, .blockedLink: return .drop
            case .http(let code) where (400..<500).contains(code) && code != 408 && code != 429: return .drop
            case .http, .timedOut: break
            }
        }
        if age > maxAge { return .drop }
        if error is CancellationError { return .keep(attempts: attempts) }
        if let e = error as? URLError, offline.contains(e.code) { return .keep(attempts: attempts) }
        let used = attempts + 1
        return used >= maxAttempts ? .drop : .keep(attempts: used)
    }
}
