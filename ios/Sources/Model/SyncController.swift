import Foundation
import Observation
import OSLog
import PixelClipKit

/// What the "Send to PixelClip" sheet was asked to do.
enum SyncRequest: Identifiable, Hashable {
    /// PUT the composed playlist (`ClipDocument`: Now + the playlist), its assets and the clock.
    case playlist
    /// Put one item on the clip (if needed) and show it for a minute (`POST /show`, with a strip's scroll).
    case show(String)
    /// Reader (PROTOCOL §5c): a saved text with the current typeface and speed, then the composed
    /// playlist. `readNow` makes the reading Now (the clip starts reading when the session ends), from
    /// `fromWord` when set (this send only), else where the clip stopped; otherwise it joins
    /// the playlist (`PlaylistStore.upsertReading`).
    case reader(String, readNow: Bool, fromWord: Int?)

    var id: String {
        switch self {
        case .playlist: "playlist"
        case .show(let id): "show-\(id)"
        case .reader(let id, let now, let w): "reader-\(id)-\(now)-\(w ?? -1)"
        }
    }

    /// Sends the composed playlist (everything but "Show now").
    var sendsPlaylist: Bool { if case .show = self { false } else { true } }
}

/// Drives the sync sheet: Bluetooth (the fast lane, or the doorbell) → join →
/// connect → upload n of m → playlist → done. The one code path for sending the playlist, whichever
/// button started it (any Send, Undo through `ClipSender`).
///
/// The fast lane (PROTOCOL §3b): with Bluetooth Wake on and no Wi‑Fi session open, the send links
/// over Bluetooth and every small request (status, config, clock, playlist, show) goes there —
/// the clip's screen never leaves its content and no "WiFi:" splash shows. New pictures or texts open
/// the clip's Wi‑Fi mid-send (the doorbell + hotspot path, in the join row), and from then on
/// everything goes over HTTP.
@MainActor @Observable
final class SyncController {
    enum Phase: Int, CaseIterable, Comparable {
        case font, bluetooth, join, connect, upload, playlist, finish
        static func < (a: Phase, b: Phase) -> Bool { a.rawValue < b.rawValue }
    }

    enum StepState: Equatable {
        case pending
        case active(String)
        case done(String)
        /// Didn't happen, and the send goes on (e.g. no answer over Bluetooth: the join is tried anyway).
        case skipped(String)
        case failed(String)
    }

    let request: SyncRequest
    private(set) var steps: [Phase: StepState] = [:] {
        didSet {
            for (p, s) in steps where oldValue[p] != s { phaseClock.observe(p, active: s.isActive, final: s.isFinal) }
        }
    }
    /// How long each row took (shown at its end).
    private(set) var phaseClock = PhaseClock<Phase>()
    /// How this send reached the clip (the sheet's badge); nil until known.
    private(set) var route: SendRoute?
    /// The Bluetooth row is the fast lane's link (not the doorbell's wake).
    private(set) var usesFastLane = false
    /// Opening Wi‑Fi mid-send failed: the join's problem (with the button instructions).
    private var wifiProblem: SendProblem?
    private(set) var uploadFraction: Double = 0
    /// "Sending i of n" while pictures go up (the send-status capsule's count).
    private(set) var uploadCount: (index: Int, total: Int)?
    private(set) var overall: Double = 0
    private(set) var isRunning = false
    private(set) var finished = false
    /// Everything went through: the sheet closes (the session ends in the background).
    private(set) var closeRequested = false
    /// What went wrong, in words a person can act on (nil while things go well).
    private(set) var problem: SendProblem?
    private(set) var report: SyncReport?
    /// The "Waking … over Bluetooth" row is part of this send (Settings ▸ Bluetooth Wake).
    private(set) var wakesOverBluetooth: Bool
    /// The clip's screen keeps playing during the session (else it rests until the session ends).
    private var screenOn = true
    /// When each step started and ended (Debug readout, `send` log line).
    private(set) var timeline = SendTimeline()
    static let log = Logger(subsystem: AppLog.subsystem, category: "send")

    private var endingLine: String { screenOn ? "Ending the session…" : "Turning the screen back on…" }
    private var endFailedLine: String {
        screenOn ? "Its Wi‑Fi turns itself off in a couple of minutes" : "Press the clip’s button once to turn its screen back on"
    }

    init(request: SyncRequest, settings: AppSettings = .shared) {
        self.request = request
        wakesOverBluetooth = settings.bluetoothWake
        reset()
    }

    private func reset() {
        phaseClock.reset()
        route = nil
        wifiProblem = nil
        for p in Phase.allCases { steps[p] = .pending }
        uploadFraction = 0; overall = 0; finished = false; problem = nil; report = nil; closeRequested = false
        uploadCount = nil
    }

    /// The clip's Wi‑Fi is off: show the "press the button" help.
    var needsButtonPress: Bool { problem?.needsButtonPress ?? false }
    var failed: Bool { problem != nil }
    var succeeded: Bool { finished && problem == nil && (report?.succeeded ?? true) }

    /// Rows shown in the sheet (the typeface row only for the Reader).
    var phases: [Phase] {
        Phase.allCases.filter { p in
            switch p {
            case .bluetooth: wakesOverBluetooth
            case .font: if case .reader = request { true } else { false }
            default: true
            }
        }
    }

    private var readerDoc: ReaderDocument? {
        if case .reader(let id, _, _) = request { ReaderStore.shared.document(id) } else { nil }
    }

    private var readsNow: Bool { if case .reader(_, true, _) = request { true } else { false } }

    func title(_ p: Phase, session: ClipSession) -> String {
        switch p {
        case .font: "Prepare the typeface"
        case .bluetooth: usesFastLane ? "Reach \(session.displayName) over Bluetooth" : "Waking \(session.displayName) over Bluetooth"
        case .join: session.useVirtual ? "Join the virtual clip" : "Join “\(HotspotDefaults.ssidPrefix)…” Wi‑Fi"
        case .connect: "Connect to \(session.displayName)"
        case .upload:
            switch request {
            case .playlist: "Send pictures and set the clock"
            case .reader: "Send the text and set the clock"
            case .show: "Send it"
            }
        case .playlist:
            switch request {
            case .playlist: "Update the playlist"
            case .reader: readsNow ? "Start reading" : "Add it to tonight’s rotation"
            case .show: "Show it for a minute"
            }
        case .finish: "Finish"
        }
    }

    private func fail(_ phase: Phase, _ p: SendProblem) {
        problem = p
        steps[phase] = .failed(p.title)
        sendLog("send: failed at \(phase) · \(p.title)")
    }

    func run(session: ClipSession, library: LibraryStore, settings: AppSettings = .shared) async {
        guard !isRunning else { return }
        reset()
        isRunning = true
        sendLog("send: ", peer: request.id, then: " · start (Bluetooth Wake \(settings.bluetoothWake ? "on" : "off"), \(session.isConnected ? "on its Wi‑Fi" : session.nearby != nil ? "heard nearby" : "not heard nearby"))")
        session.beginSending()
        // A previous send may still be ending its session in the background: let it finish first.
        await session.settle()
        timeline.begin()
        defer {
            session.endSending()
            isRunning = false
            timeline.finish()
            logTiming()
        }

        // 0. Reader: the typeface's atlases (rendered once, then cached) and the rotation item.
        if case .reader(_, let now, _) = request {
            let store = ReaderStore.shared
            steps[.font] = .active(store.currentFont == nil ? "Rendering \(ReaderStore.name(store.typeface))…" : "Ready")
            timeline.start(.font)
            guard let doc = readerDoc, let font = await store.prepareCurrentFont() else {
                fail(.font, .other)
                return
            }
            timeline.end(.font)
            if now {
                NowOnClip.shared.set(.reader(text: doc.clipTextID, font: font.id, wpm: store.wpm), title: doc.title)
            } else {
                PlaylistStore.shared.upsertReading(.reader(text: doc.clipTextID, font: font.id, wpm: store.wpm), name: doc.title)
            }
            steps[.font] = .done("\(font.name) · \(store.wpm) words a minute")
        }

        // 1. The fast lane first: link over Bluetooth (no Wi‑Fi session open, Bluetooth Wake on).
        wakesOverBluetooth = settings.bluetoothWake
        session.joiner.bluetoothWake = wakesOverBluetooth
        usesFastLane = false
        if wakesOverBluetooth && !session.isConnected {
            usesFastLane = true
            steps[.bluetooth] = .active("Looking for it nearby…")
            timeline.start(.bluetooth)
            let linked = await session.openFastLane()
            timeline.end(.bluetooth)
            sendLog(linked ? "send: fast lane linked" : "send: no fast lane (\(session.nearby == nil ? "not heard" : "heard, no link")) · ringing the doorbell")
            if linked {
                route = .bluetooth
                steps[.bluetooth] = .done("Linked · small changes go over Bluetooth")
                steps[.join] = .skipped("Only needed for new pictures")
                session.links.wifiOpener = { [weak self] in
                    guard let self else { return }
                    try await self.openWiFiMidSend(session: session)
                }
            } else {
                usesFastLane = false
                steps[.bluetooth] = .pending
            }
        }
        defer { session.links.wifiOpener = nil }
        if !usesFastLane {
            route = .wifi
            guard await wakeAndJoin(session: session) else { return }
        }

        // 2. Connect: status (battery, clock), config and the clip's playlist (for the skip rules).
        steps[.connect] = .active(usesFastLane ? "Reading status over Bluetooth…" : "Reading status…")
        timeline.start(.connect)
        var refreshed = await session.refresh()
        if !refreshed, usesFastLane, wifiProblem == nil {
            // Linked over Bluetooth but the clip didn't answer there: don't give up on a link that
            // half-works, drop it and take the doorbell + Wi‑Fi path.
            sendLog("send: no answer over the fast lane (\(session.problem?.title ?? "–")) · dropping it, waking its Wi‑Fi")
            session.links.wifiOpener = nil
            session.releaseBluetooth()
            usesFastLane = false
            route = .wifi
            guard await wakeAndJoin(session: session) else { return }
            steps[.connect] = .active("Reading status…")
            refreshed = await session.refresh()
        }
        let statusReadAt = Date()
        timeline.end(.connect)
        guard refreshed, let status = session.status else {
            fail(.connect, wifiProblem ?? session.problem ?? .clipNotAnswering)
            return
        }
        screenOn = session.screenStaysOn
        sendLog("send: status read · ", peer: status.playlist.current ?? "nothing", then: " on screen")
        let battery = BatteryReading(status.battery)
        steps[.connect] = .done("Battery \(battery.pct.map { "\($0)%" } ?? "–")\(battery.onUSB ? ", charging" : "") · \(status.storage.free.byteString) free\(usesFastLane ? " · over Bluetooth" : "")")

        let engine = SyncEngine(client: session.client)
        switch request {
        case .playlist, .reader:
            await runPlaylistSync(engine: engine, library: library, session: session,
                                  setTime: SendSkipRules.needsTimeSync(status: status, readAt: statusReadAt, lastSyncedAt: session.lastClockSync))
        case .show(let id):
            await runShow(id: id, engine: engine, library: library, session: session)
        }
        finished = true
    }

    /// The doorbell + hotspot path: wake over Bluetooth and join its Wi‑Fi, overlapped (the join
    /// starts as soon as the clip acknowledges the wake). Without an answer over Bluetooth the join
    /// is still tried (the button may have been pressed). False when the send can't go on.
    private func wakeAndJoin(session: ClipSession) async -> Bool {
        if wakesOverBluetooth {
            steps[.bluetooth] = .active("Looking for it nearby…")
            timeline.start(.wake)
        }
        let joined = await session.joiner.wakeAndJoin(
            onState: { [weak self] s in self?.showDoorbell(s) },
            onWake: { [weak self] outcome in self?.wakeFinished(outcome) },
            onJoinStart: { [weak self] in
                guard let self else { return }
                self.steps[.join] = .active(session.useVirtual ? "Joining…" : "Asking iPhone to join…")
                self.timeline.start(.join)
            })
        if case .blocked? = session.joiner.lastWake {
            fail(.bluetooth, SendProblem(join: session.joiner.failure))
            return false
        }
        guard joined == .joined else {
            sendLog("send: join failed · ", peer: session.joiner.message ?? "\(joined)")
            fail(.join, SendProblem(join: session.joiner.failure))
            return false
        }
        sendLog("send: on the clip’s Wi‑Fi")
        timeline.end(.join)
        session.joinedWiFi()
        if session.joiner.lastWake == .alreadyAwake {
            steps[.join] = .done(session.useVirtual ? "Virtual clip" : "Already on the clip’s Wi‑Fi")
        } else {
            steps[.join] = .done(session.useVirtual ? "Virtual clip" : "On the clip’s Wi‑Fi")
        }
        return true
    }

    /// New pictures (or texts) during a fast-lane send: wake the clip's Wi‑Fi and join it, in the
    /// join row. From here on `SmartClipClient` sends everything over HTTP.
    private func openWiFiMidSend(session: ClipSession) async throws {
        route = .bluetoothThenWiFi
        steps[.join] = .active("New pictures need its Wi‑Fi · waking it…")
        timeline.start(.join)
        let joined = await session.joiner.wakeAndJoin(onJoinStart: { [weak self] in
            self?.steps[.join] = .active(session.useVirtual ? "Joining…" : "Asking iPhone to join…")
        })
        guard joined == .joined else {
            let p = SendProblem(join: session.joiner.failure)
            wifiProblem = p
            steps[.join] = .failed(p.title)
            throw ClipError.unreachable(p.title)
        }
        timeline.end(.join)
        session.joinedWiFi()
        screenOn = session.screenStaysOn
        steps[.join] = .done(session.useVirtual ? "Virtual clip · for the new pictures" : "On the clip’s Wi‑Fi · for the new pictures")
    }

    /// Wi‑Fi was never opened: the whole send went over Bluetooth.
    private var bluetoothOnly: Bool { route == .bluetooth }

    /// One line per send in the log (Release too) and, in Debug, on the console.
    private func logTiming() {
        let line = timeline.summary
        Self.log.notice("send timing: \(line, privacy: .public)")
        #if DEBUG
        print("SEND_TIMING \(line)")
        #endif
    }

    /// The person's wait is over: the sheet closes (`closeRequested`) and the session ends in the
    /// background (errors there are silent: the clip times out anyway).
    private func closeAndEndInBackground(session: ClipSession, refreshTexts: Bool) {
        if bluetoothOnly {
            // No session to end: read the new state over Bluetooth for the Clip tab.
            steps[.join] = .skipped("Not needed: it all went over Bluetooth")
            timeline.finish()
            closeRequested = true
            session.refreshInBackground { seconds in
                Self.log.notice("send refresh over Bluetooth: \(SendTimeline.format(seconds), privacy: .public) after closing")
            }
            return
        }
        timeline.finish()
        closeRequested = true
        timeline.start(.end)
        session.endSessionInBackground(refreshTexts: refreshTexts) { [weak self] seconds in
            guard let self else { return }
            self.timeline.end(.end)
            Self.log.notice("send session end: \(SendTimeline.format(seconds), privacy: .public) after closing")
            #if DEBUG
            print("SEND_END \(SendTimeline.format(seconds))")
            #endif
        }
        timeline.start(.end)
    }

    private func runPlaylistSync(engine: SyncEngine, library: LibraryStore, session: ClipSession, setTime: Bool) async {
        var playlist = ClipDocument.playlist(library: library)
        if case .reader(let id, true, let from?) = request, let doc = ReaderStore.shared.document(id),
           let i = playlist.items.firstIndex(where: { $0.type == .reader && $0.text == doc.clipTextID }) {
            playlist.items[i].fromWord = from   // this send only: later sends resume where the clip is
        }
        let local = ClipDocument.localAssets(for: playlist, library: library)
        let n = Set(playlist.assetIDs).count
        #if DEBUG
        // The exact document this send PUTs (Caches/last-sent-playlist.json), for debugging.
        let enc = ClipJSON.encoder()
        enc.outputFormatting.insert(.prettyPrinted)
        if let json = try? enc.encode(playlist) {
            let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("last-sent-playlist.json")
            try? json.write(to: url, options: .atomic)
            print("SEND_PLAYLIST \(String(decoding: json, as: UTF8.self))")
        }
        #endif
        steps[.upload] = .active("Comparing with the clip…")
        timeline.start(.upload)
        if !playlist.textIDs.isEmpty {
            // Reader texts and fonts first: the clip refuses a reader item whose text or font it lacks.
            steps[.upload] = .active("Sending texts and typefaces…")
            do {
                playlist = try await ReaderStore.shared.prepare(playlist, client: session.client)
            } catch {
                fail(.upload, wifiProblem ?? SendProblem(error: error, step: "upload", batteryWasLow: session.batteryWasLow))
                session.markSessionEnded()
                for p in [Phase.playlist, .finish] { steps[p] = .failed("Skipped") }
                return
            }
        }
        if !playlist.oracleReaderIDs.isEmpty || session.clipPlaylist.map({ !$0.oracleReaderIDs.isEmpty }) == true {
            // The Tarot's sentence reader (§5f.1): its phrase bundle and font first, as for the Reader.
            steps[.upload] = .active("Sending the Tarot’s words…")
            do {
                playlist = try await TarotReaderSend.prepare(playlist, client: session.client, library: library, clipPlaylist: session.clipPlaylist)
            } catch {
                fail(.upload, wifiProblem ?? SendProblem(error: error, step: "upload", batteryWasLow: session.batteryWasLow))
                session.markSessionEnded()
                for p in [Phase.playlist, .finish] { steps[p] = .failed("Skipped") }
                return
            }
        }
        // Skip the no-ops: the clock when it's right and recent, the playlist when the clip already
        // has it (SendSkipRules).
        var options = SyncOptions(deleteOrphans: true, setTime: setTime, endSession: false,
                                  skipUnchangedPlaylist: true, clipPlaylist: session.clipPlaylist)
        // The playlist's pictures stay on the clip while it's off (and Now's), so switching it back on is
        // a playlist PUT over Bluetooth, not a Wi‑Fi upload.
        options.keepIDs = Set(PlaylistStore.shared.entries.flatMap(\.content.assetIDs) + (NowOnClip.shared.item?.content.assetIDs ?? []))
        let report = await engine.sync(local: local, playlist: playlist,
                                       options: options, progress: { [weak self] p in
            Task { @MainActor in self?.apply(p, total: n) }
        })
        self.report = report
        timeline.end(.upload)
        if report.timeSet { session.recordClockSync() }
        overall = 1
        let uploaded = report.uploaded.count
        let unchanged = report.unchanged.count
        let wasLow = session.batteryWasLow
        if let f = report.failures.first(where: { ["upload", "inventory", "time", "delete"].contains($0.step) }) {
            fail(.upload, SendProblem(failure: f, assetName: f.id.flatMap { library.item($0)?.name }, batteryWasLow: wasLow))
        } else {
            let clock = report.timeSet ? " · clock set" : setTime ? "" : " · clock already right"
            steps[.upload] = .done(uploaded == 0 ? "Pictures already there\(clock)" : "\(uploaded) sent\(unchanged > 0 ? ", \(unchanged) already there" : "")\(clock)")
        }
        if report.lostConnection {
            if let wifiProblem {
                problem = wifiProblem
            } else if problem == nil || problem == .other {
                problem = SendProblem(error: ClipError.unreachable(""), batteryWasLow: wasLow)
            }
            session.markSessionEnded()
            for p in [Phase.upload, .playlist, .finish] where steps[p] == .pending || isActive(p) {
                steps[p] = .failed(p == .upload ? problem!.title : "Skipped")
            }
            return
        }
        sendLog("send: \(report.playlistSkipped ? "playlist already on the clip (PUT skipped)" : report.playlistInPlace ? "PUT /playlist done" : "PUT /playlist failed") · \(uploaded) uploaded, \(unchanged) already there")
        if report.playlistInPlace {
            var line = Self.describe(playlist, dropped: report.droppedFromPlaylist.count)
            if report.playlistSkipped { line = "Already on the clip · " + line }
            steps[.playlist] = .done(line)
        } else {
            let f = report.failures.first { $0.step == "playlist" }
            fail(.playlist, f.map { SendProblem(failure: $0, batteryWasLow: wasLow) } ?? .playlistRejected)
        }
        if report.succeeded {
            // The last upload went through: close the sheet, end the session in the background.
            ClipDocument.markSent(library: library, deviceID: session.status?.device.id)
            if let doc = readerDoc {
                steps[.finish] = .done(readsNow ? "Look at your clip: it’s reading “\(doc.title)”" : "“\(doc.title)” plays until it’s finished")
            } else {
                steps[.finish] = .done((playlist.queue ?? []).isEmpty ? "Your clip is showing it now" : "All set — you can walk away")
            }
            closeAndEndInBackground(session: session, refreshTexts: !playlist.textIDs.isEmpty)
            return
        }
        if bluetoothOnly {
            // Something to read in the sheet; no Wi‑Fi session to end.
            steps[.join] = .skipped("Not needed: it all went over Bluetooth")
            await session.refresh()
            steps[.finish] = .done(finishLine(playlist))
            return
        }
        // Something to read in the sheet: read the new state before the clip turns its Wi‑Fi off,
        // then end the session here.
        steps[.finish] = .active(endingLine)
        timeline.start(.end)
        await session.refresh()
        if !playlist.textIDs.isEmpty, let texts = try? await session.client.texts() { ReaderStore.shared.recordClipTexts(texts) }
        do {
            try await session.client.endSession()
            session.markSessionEnded()
            if let doc = readerDoc {
                steps[.finish] = .done(readsNow ? "Look at your clip: it’s reading “\(doc.title)”" : "“\(doc.title)” plays until it’s finished")
            } else {
                steps[.finish] = .done((playlist.queue ?? []).isEmpty ? "Your clip is showing it now" : "All set — you can walk away")
            }
        } catch {
            session.markSessionEnded()
            steps[.finish] = .done(endFailedLine)
        }
        timeline.end(.end)
    }

    /// The finish row's line once the clip has the new playlist.
    private func finishLine(_ playlist: Playlist) -> String {
        if let doc = readerDoc {
            return readsNow ? "Look at your clip: it’s reading “\(doc.title)”" : "“\(doc.title)” plays until it’s finished"
        }
        return (playlist.queue ?? []).isEmpty ? "Your clip is showing it now" : "All set — you can walk away"
    }

    /// "Plays until you send something else", or "3 in rotation (1 timed) · 2 moments · 1 reading".
    static func describe(_ playlist: Playlist, dropped: Int = 0) -> String {
        let n = playlist.items.count - dropped
        if n == 1, dropped == 0, (playlist.queue ?? []).isEmpty { return "Plays until you send something else" }
        let timed = playlist.items.filter { $0.from != nil || $0.until != nil }.count
        let q = playlist.queue?.count ?? 0
        var parts = ["\(n) in rotation\(timed > 0 ? " (\(timed) timed)" : "")"]
        if dropped > 0 { parts[0] += ", \(dropped) left out" }
        if q > 0 { parts.append("\(q) moment\(q == 1 ? "" : "s")") }
        let readings = playlist.items.filter { $0.type == .reader }.count
        if readings > 0 { parts.append(readings == 1 ? "1 reading" : "\(readings) readings") }
        return parts.joined(separator: " · ")
    }

    private func runShow(id: String, engine: SyncEngine, library: LibraryStore, session: ClipSession) async {
        guard let asset = library.localAssets(ids: [id]).first else {
            fail(.upload, .other)
            return
        }
        let name = library.item(id)?.name
        // A strip scrolls: the same scroll as its rotation item (or the library item's), not a still first screen.
        let scroll = ClipDocument.playlist(library: library).showScroll(for: id, fallback: library.item(id).flatMap { $0.isStrip ? $0.scroll : nil })
        steps[.upload] = .active("Sending “\(name ?? "it")”…")
        do {
            try await engine.showNow(asset, scroll: scroll) { [weak self] f in
                Task { @MainActor in self?.uploadFraction = f; self?.overall = 0.3 + 0.5 * f }
            }
            steps[.upload] = .done("On the clip")
            steps[.playlist] = .done(screenOn ? "On the screen now for a minute, then the playlist resumes" : "Plays for a minute, then the playlist resumes")
        } catch {
            fail(isActive(.upload) ? .upload : .playlist, SendProblem(error: error, step: "upload", assetName: name, batteryWasLow: session.batteryWasLow))
            if problem?.needsButtonPress == true || problem == .lowBatteryEndedSession { session.markSessionEnded() }
            return
        }
        overall = 1
        steps[.finish] = .done("Look at your clip")
        closeAndEndInBackground(session: session, refreshTexts: false)
    }

    private func isActive(_ p: Phase) -> Bool { if case .active = steps[p] { return true } else { return false } }

    /// The Bluetooth row while the doorbell rings.
    private func showDoorbell(_ s: DoorbellState) {
        switch s {
        case .idle, .scanning: steps[.bluetooth] = .active("Looking for it nearby…")
        case .found(let name, _): steps[.bluetooth] = .active("Found \(name)")
        case .waking: steps[.bluetooth] = .active("Asking it to turn on its Wi‑Fi…")
        case .accepted:
            // Write acknowledged: the join starts now, while the access point comes up.
            timeline.end(.wake)
            steps[.bluetooth] = .active("Awake · its Wi‑Fi is starting…")
        case .hotspotUp, .failed: break   // the outcome's line follows
        }
    }

    /// The Bluetooth row once the doorbell is done.
    private func wakeFinished(_ outcome: DoorbellOutcome) {
        sendLog("send: doorbell → \(outcome.line)")
        guard wakesOverBluetooth else { return }
        timeline.end(.wake)
        switch outcome {
        case .woke, .alreadyAwake: steps[.bluetooth] = .done(outcome.line)
        case .disabled, .fallBack: steps[.bluetooth] = .skipped(outcome.line)
        case .blocked: break   // run() shows the problem
        }
    }

    private func apply(_ p: SyncProgress, total: Int) {
        guard report == nil else { return }   // late event after the engine returned
        overall = 0.2 + 0.8 * p.overall
        switch p.step {
        case .reading: steps[.upload] = .active("Comparing with the clip…")
        case .settingTime: steps[.upload] = .active("Setting the clock…")
        case .deleting(let i, let n, _): steps[.upload] = .active("Tidying up \(i) of \(n)…")
        case .uploading(let i, let n, _, let f):
            uploadFraction = (Double(i - 1) + f) / Double(max(n, 1))
            if uploadCount?.index != i { sendLog("send: uploading \(i) of \(n)") }
            uploadCount = (i, n)
            steps[.upload] = .active("Sending \(i) of \(n)…")
        case .playlist: steps[.playlist] = .active("Sending the playlist…")
        case .endingSession: steps[.finish] = .active(endingLine)
        case .finished: break
        }
    }
}

extension SyncController.StepState {
    var isActive: Bool { if case .active = self { true } else { false } }
    /// Done, skipped or failed.
    var isFinal: Bool {
        switch self {
        case .pending, .active: false
        case .done, .skipped, .failed: true
        }
    }
}
