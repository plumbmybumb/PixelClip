import Foundation
import Observation
import OSLog
import PixelClipKit

/// Sending, made invisible (docs/DESIGN.md ▸ "The connection is invisible"): every Send runs the
/// existing send controller (`SyncController`) in the background — the Bluetooth
/// doorbell, the fast lane and the Wi‑Fi path exactly as before — and the person sees its `stage` in the
/// send-status capsule (Home, Playlist): looking, waking, connecting, "Sending 2 of 5 · 40%", "Sent" with
/// Undo. When the clip can't be reached the send is kept ("Can't reach the clip — will retry", Retry,
/// Cancel): a Bluetooth look every 10 s while the app is open, and it goes out as soon as the clip is
/// heard. Every step goes to `SendLog` (Settings ▸ Advanced ▸ Send log).
@MainActor @Observable
final class Sender {
    enum Job: Equatable {
        /// PUT the composed document (Now + the playlist) and whatever it needs.
        case playlist
        /// Read a saved text now (its typeface and text first).
        case reader(docID: String)
    }

    /// What the toast says when the job is done.
    enum Kind: Equatable {
        /// Something new is on the clip: "Sent · Undo".
        case sent
        /// The playlist changed: "Added to the playlist".
        case playlist
        /// Following an Undo, a playlist edit, a setting: no toast unless it has to wait.
        case quiet
    }

    private(set) var isSending = false
    /// Couldn't reach the clip: this goes out when the clip is near.
    private(set) var pending: Job?
    @ObservationIgnored private var queued: (job: Job, kind: Kind)?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    /// The app is in the foreground (retries only look for the clip then).
    @ObservationIgnored var isActive = true
    /// The send running now (its steps feed `stage`).
    private(set) var controller: SyncController?
    /// A Bluetooth look for the waiting send is running.
    private(set) var isLooking = false
    /// The last send went through (`stage` shows "Sent" for a few seconds), and what it was.
    private(set) var sentAt: Date?
    private(set) var sentKind: Kind = .sent
    /// The last attempt hit a problem that isn't "out of reach" (shown until dismissed or retried).
    private(set) var failure: SendProblem?
    @ObservationIgnored private var lastKind: Kind = .quiet
    /// How often a waiting send looks for the clip.
    static let lookEvery: Duration = .seconds(10)
    /// How long "Sent" (with Undo) stays in the capsule.
    static let sentShows: TimeInterval = 5

    /// What the send-status capsule says (nil: nothing to show).
    enum Stage: Equatable {
        case looking
        case waking
        case connecting
        /// Pictures going up: `index` of `total`, `fraction` of all of them.
        case uploading(index: Int, total: Int, fraction: Double)
        case sending
        case sent(Kind)
        /// Out of reach: kept, looked for every 10 s.
        case waiting
        case failed(String)
    }

    var stage: Stage? {
        if isSending { return controller.map(Self.stage(of:)) ?? .sending }
        if let failure { return .failed(failure.title) }
        if pending != nil { return isLooking ? .looking : .waiting }
        if let sentAt, Date().timeIntervalSince(sentAt) < Self.sentShows { return .sent(sentKind) }
        return nil
    }

    /// A running send's stage, from its rows.
    static func stage(of c: SyncController) -> Stage {
        func active(_ p: SyncController.Phase) -> String? { if case .active(let s)? = c.steps[p] { s } else { nil } }
        if active(.upload) != nil, let u = c.uploadCount { return .uploading(index: u.index, total: u.total, fraction: c.uploadFraction) }
        if active(.upload) != nil || active(.playlist) != nil || active(.finish) != nil || active(.font) != nil {
            return .sending
        }
        if active(.connect) != nil || active(.join) != nil { return .connecting }
        if let b = active(.bluetooth) {
            return b.hasPrefix("Asking") || b.hasPrefix("Awake") || b.hasPrefix("Found") ? .waking : .looking
        }
        return c.finished ? .sending : .looking
    }

    let session: ClipSession
    let library: LibraryStore
    let router: Router
    static let log = Logger(subsystem: AppLog.subsystem, category: "send")

    init(session: ClipSession, library: LibraryStore, router: Router) {
        self.session = session
        self.library = library
        self.router = router
    }

    // MARK: The verbs

    /// Puts `content` on the clip (it becomes what the clip shows until the next send).
    func sendNow(_ content: MomentContent, title: String) {
        NowOnClip.shared.set(content, title: title)
        send(.playlist, kind: .sent)
    }

    /// Adds `content` to the playlist and sends the new playlist.
    func addToPlaylist(_ content: MomentContent, name: String) {
        PlaylistStore.shared.add(content, name: name)
        send(.playlist, kind: .playlist)
    }

    /// Reads a saved text on the clip now.
    func read(docID: String) { send(.reader(docID: docID), kind: .sent) }

    /// The Playlist screen's switch. Now plays first in the rotation (`PlaylistStore`), so turning the
    /// playlist on would leave what's on the clip there for the rest of its minute, and every off/on
    /// starts that minute over: once the document is on the clip, the clip is stepped to the next entry (`POST /next`)
    /// when the rotation has one, so the switch shows something new at once.
    func turnPlaylist(on: Bool) {
        PlaylistStore.shared.isOn = on
        stepAfterSend = on && ClipDocument.playlist(library: library).items.count >= 2
        sendLog("playlist: turned \(on ? "on" : "off") · sending the new document\(stepAfterSend ? ", then stepping to the next entry" : "")")
        send(.playlist, kind: .quiet)
    }
    /// After the next successful playlist send, step the clip to the next rotation entry (see `turnPlaylist`).
    @ObservationIgnored private var stepAfterSend = false

    /// Home's Undo pill and every "Sent · Undo": puts back what was on the clip before.
    /// (`NowOnClip.undo` sends through `NowOnClip.send`, which the app points at `send(.playlist, kind: .quiet)`.)
    func undo() {
        Task { await NowOnClip.shared.undo() }
    }

    func send(_ job: Job, kind: Kind) {
        failure = nil
        if isSending {
            // Latest wins: the composed document is always the current one.
            sendLog("sender: \(job) queued behind the running send")
            queued = (job, kind)
            return
        }
        sendLog("sender: \(job) requested (\(kind))")
        Task { await run(job, kind: kind) }
    }

    /// The capsule's Retry: a full attempt now (doorbell, join), whether or not a look heard the clip.
    func retryNow() {
        guard !isSending else { return }
        let job = pending ?? .playlist
        failure = nil
        sendLog("sender: retry now (\(job))")
        Task { await run(job, kind: lastKind) }
    }

    /// The capsule's "Set up again" (the clip's Wi‑Fi password was reset on the clip): forget this iPhone's
    /// copy, then the send again: it joins with the factory password and gives the clip a new one.
    func setUpAgain() {
        session.setUpHotspotPasswordAgain()
        retryNow()
    }

    /// The capsule's Cancel: stop waiting. The changes stay unsent and go with the next send.
    func cancelPending() {
        sendLog("sender: waiting send cancelled")
        pending = nil
        failure = nil
        retryTask?.cancel()
        retryTask = nil
    }

    // MARK: Running

    private func run(_ job: Job, kind: Kind) async {
        isSending = true
        lastKind = kind
        let started = Date()
        // A playlist that was just switched on steps the clip to its next entry as part of the send itself
        // (`SyncController.stepAfterPlaylist`), before the Wi‑Fi session is ended in the background.
        let step = stepAfterSend && job == .playlist
        stepAfterSend = false
        let outcome = await attempt(job, step: step)
        isSending = false
        let took = String(format: "%.1f", Date().timeIntervalSince(started))
        switch outcome {
        case .sent:
            sendLog("sender: \(job) sent in \(took) s")
            pending = nil
            failure = nil
            retryTask?.cancel()
            retryTask = nil
            sentKind = kind
            sentAt = Date()
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.sentShows + 0.2))
                self?.expireSent()
            }
        case .away:
            sendLog("sender: \(job) couldn’t reach the clip after \(took) s · waiting, looking every \(Int(Self.lookEvery.components.seconds)) s")
            pending = job
            startRetry()
        case .problem(let p):
            sendLog("sender: \(job) failed after \(took) s · \(p.title)")
            failure = p
        }
        if let next = queued {
            queued = nil
            await run(next.job, kind: next.kind)
        }
    }

    /// "Sent" fades from the capsule (an observed change, so it disappears on time).
    private func expireSent() {
        guard let at = sentAt, Date().timeIntervalSince(at) >= Self.sentShows else { return }
        sentAt = nil
    }

    /// The capsule's "Sent" was dismissed (or Undo tapped).
    func dismissSent() { sentAt = nil }

    func dismissFailure() { failure = nil }

    private enum Outcome { case sent, away, problem(SendProblem) }

    private func attempt(_ job: Job, step: Bool = false) async -> Outcome {
        switch job {
        case .playlist:
            let c = SyncController(request: .playlist)
            c.stepAfterPlaylist = step
            controller = c
            defer { controller = nil }
            await c.run(session: session, library: library)
            return outcome(succeeded: c.succeeded, problem: c.problem)
        case .reader(let id):
            let c = SyncController(request: .reader(id, readNow: true, fromWord: nil))
            controller = c
            defer { controller = nil }
            await c.run(session: session, library: library)
            return outcome(succeeded: c.succeeded, problem: c.problem)
        }
    }

    private func outcome(succeeded: Bool, problem: SendProblem?) -> Outcome {
        if succeeded { return .sent }
        guard let problem else { return .away }
        // Not reachable (asleep, out of range, Bluetooth off, the join refused): keep it for later.
        if problem.needsConnectionHelp || problem.needsButtonPress || problem == .clipNotAnswering { return .away }
        return .problem(problem)
    }

    // MARK: Waiting for the clip

    /// Looks for the clip every 10 s while a send waits and the app is open (whatever screen is up),
    /// and sends as soon as it's heard.
    private func startRetry() {
        guard retryTask == nil else { return }
        retryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Sender.lookEvery)
                guard let self, !Task.isCancelled, self.pending != nil else { break }
                await self.retryIfNear()
            }
            self?.retryTask = nil
        }
    }

    /// The app came to the foreground, or it's time for the waiting send's next look: look, and send
    /// if the clip was heard.
    func retryIfNear() async {
        guard let job = pending else { return }
        guard isActive else { sendLog("sender: waiting · app in the background, no look"); return }
        guard !isSending else { sendLog("sender: waiting · a send is running"); return }
        if !session.isConnected {
            isLooking = true
            await session.peekNearby()
            isLooking = false
        }
        guard session.nearby != nil || session.isConnected else { return }
        sendLog("sender: the clip is near · sending what was waiting (\(job))")
        Self.log.notice("the clip is near: sending what was waiting")
        await run(job, kind: lastKind == .quiet ? .quiet : .sent)
    }
}
