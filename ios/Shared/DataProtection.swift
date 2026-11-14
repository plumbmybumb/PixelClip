import Foundation

/// The file protection classes the app asks for, named for what they mean.
///
/// - `whileUnlocked` (`NSFileProtectionComplete`): the App Group inboxes, where the Share Extension
///   leaves other apps' content (a page's HTML, a photo, a video) until the app picks it up. Both
///   only ever run on screen, so nothing needs these files while the iPhone is locked.
/// - `afterFirstUnlock` (`NSFileProtectionCompleteUntilFirstUserAuthentication`): the library and the
///   Reader's texts. It is the system default, stated here so it is a decision rather than an accident:
///   the stores load when the process starts and write their index back, and a start while the files
///   were sealed would read as "empty library".
///
/// Files made in a folder take the folder's class; files moved or copied in are set one by one.
/// (The simulator has no data protection: these calls do nothing there.)
enum DataProtection {
    enum Level {
        case whileUnlocked, afterFirstUnlock

        var type: FileProtectionType {
            switch self {
            case .whileUnlocked: .complete
            case .afterFirstUnlock: .completeUntilFirstUserAuthentication
            }
        }
    }

    static func protect(_ url: URL, _ level: Level) {
        #if !targetEnvironment(simulator)
        try? FileManager.default.setAttributes([.protectionKey: level.type], ofItemAtPath: url.path)
        #endif
    }
}
