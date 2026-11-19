import Foundation
import Observation
import PixelClipKit

/// The connection to the clip — real (HTTP over its hotspot, woken over Bluetooth; small requests
/// over the Bluetooth fast lane) or virtual (in-memory emulation with a `VirtualDoorbell` and its
/// `VirtualFastLane`). `client` is a `SmartClipClient`: with no Wi‑Fi session open, fast-lane
/// eligible requests go over Bluetooth, everything else opens the hotspot (README ▸ Fast lane).
@MainActor @Observable
final class ClipSession {
    private(set) var client: any ClipClient
    /// The clip's HTTP client (never the fast lane): the requests that must go over its Wi‑Fi.
    @ObservationIgnored private var http: any ClipClient
    /// Wi‑Fi state, the fast lane and the hotspot path, for `client`'s routing.
    private(set) var links: ClipLinkBroker
    private(set) var joiner: HotspotJoiner
    /// The Bluetooth doorbell: wakes the clip, and tells the Clip tab it's nearby (battery).
    private(set) var doorbell: any DoorbellRinging
    /// Kept for the whole app life so its state survives toggling.
    @ObservationIgnored let virtualClip = VirtualClipClient()

    var useVirtual: Bool {
        didSet {
            guard useVirtual != oldValue else { return }
            UserDefaults.standard.set(useVirtual, forKey: Keys.virtual)
            rebuild()
        }
    }

    /// The real clip's hotspot passphrase, in the Keychain (`HotspotPasswords`): the factory one until the
    /// first join over Wi‑Fi, then the clip's own, set by the app without asking anything.
    let realPasswords = HotspotPasswords(store: KeychainHotspotPasswordStore())
    /// The virtual clip's, in memory (it starts from the factory passphrase at every launch, like the clip).
    let virtualPasswords = HotspotPasswords(store: InMemoryHotspotPasswordStore())
    /// The passphrases of the clip in use.
    var passwords: HotspotPasswords { useVirtual ? virtualPasswords : realPasswords }
    /// Home's one-time notice after the automatic setup (the real clip only).
    private(set) var showsPasswordNotice = UserDefaults.standard.bool(forKey: Keys.passwordNotice)
    /// The firmware update in Settings ▸ Advanced.
    private(set) var firmwareStep: FirmwareStep = .idle
    @ObservationIgnored private var firmwareTask: Task<Void, Never>?
    @ObservationIgnored private var firmwareImage: Data?

    private(set) var status: ClipStatus?
    private(set) var config: ClipConfig?
    /// The playlist document on the clip (read with the status).
    private(set) var clipPlaylist: Playlist?
    private(set) var lastUpdated: Date?
    /// A problem worth an inline banner (with Retry and Connection Help). Never a raw error string.
    var problem: SendProblem?
    /// A settings value the clip would refuse (shown under the setting).
    var notice: String?
    private(set) var isWorking = false
    /// Latest frame of the virtual panel, or the last screenshot from the real clip.
    private(set) var screen: ClipFrames?
    private(set) var screenLevel: Double = 1
    private(set) var screenAwake = true
    /// Virtual clip: what the panel shows right now (`/status` terms) and the moment playing, if any.
    private(set) var screenNow: String?
    private(set) var screenQueueID: String?
    /// Virtual clip: its panel is turned 180° (config `orientation: flipped`).
    private(set) var screenFlipped = false
    /// The virtual clip's `/status.oracle` as of the last screen poll (Home follows a draw with it).
    private(set) var screenOracle: ClipStatus.OracleStatus?
    @ObservationIgnored private var screenKey = ""
    /// Brightness shown by the slider (0…255). Live on the clip while connected when its screen
    /// stays on during sessions; otherwise it shows when the session ends.
    var brightness: Double = 160

    enum Keys {
        static let virtual = "useVirtualClip"
        /// Builds before the Keychain kept the passphrase here (migrated once, then removed).
        static let password = "hotspotPassword"
        /// The automatic setup gave the clip its own passphrase and Home hasn't shown that yet.
        static let passwordNotice = "hotspotPasswordNotice"
        /// `clockSyncedAt.<device id>`: this iPhone's last `POST /time` to that clip.
        static let clockSync = "clockSyncedAt."
        /// A remembered `PixelClip-…` network was installed (Settings ▸ Forget Clip removes it).
        static let remembered = "hotspotRemembered"
    }

    /// The motion sensor as last read (`GET /imu`, Settings ▸ Motion Sensor).
    var imu: IMUReading?
    /// iOS remembers the clip's Wi‑Fi (a persistent hotspot configuration was installed).
    private(set) var networkRemembered = UserDefaults.standard.bool(forKey: Keys.remembered)
    /// A session end running after the send sheet closed.
    @ObservationIgnored private var endingTask: Task<Void, Never>?
    @ObservationIgnored private var brightnessSending = false
    @ObservationIgnored private var brightnessDirty = false
    /// The last request's way to the clip (quick actions show it).
    private(set) var lastRoute: ClipRouteRecord?
    /// Debug (virtual clip): the clip isn't heard over Bluetooth, so sends take the Wi‑Fi path.
    var simulateBluetoothUnavailable = false {
        didSet {
            guard simulateBluetoothUnavailable != oldValue else { return }
            let clip = virtualClip, present = !simulateBluetoothUnavailable
            doorbell.release()
            Task { await clip.setBluetoothPresent(present) }
        }
    }

    init() {
        #if targetEnvironment(simulator)
        let defaultVirtual = true
        #else
        let defaultVirtual = false
        #endif
        #if DEBUG
        let v = UserDefaults.standard.object(forKey: Keys.virtual) as? Bool ?? defaultVirtual
        #else
        // Release always talks to the real clip, whatever a development build stored.
        let v = false
        _ = defaultVirtual
        #endif
        useVirtual = v
        let (c, j, d) = Self.make(virtual: v, virtualClip: virtualClip)
        let broker = ClipLinkBroker(doorbell: d, joiner: j)
        links = broker
        http = c
        client = SmartClipClient(http: c, links: broker)
        joiner = j
        doorbell = d
        joiner.bluetoothWake = AppSettings.shared.bluetoothWake
        // The passphrase moves from UserDefaults to the Keychain once (a non-default one becomes the clip's own).
        if realPasswords.migrate(legacy: UserDefaults.standard.string(forKey: Keys.password)) {
            UserDefaults.standard.removeObject(forKey: Keys.password)
        }
        wireLinks()
        // The virtual clip's motion sensor follows this iPhone's tilt when it has one (DeviceTilt).
        let clip = virtualClip
        Task { await clip.setGravitySource { DeviceTilt.shared.clipGravity } }
        // …and its Tarot is drawn by shaking this iPhone (while DeviceTilt runs: Home starts it when the Tarot is Now).
        Task { await clip.setShakeSource { DeviceTilt.shared.shakeMetric } }
        // …and in the demo its button allows a firmware update by itself, a moment after the clip asks.
        Task { await clip.setAutoPressForUpdate(after: .seconds(3)) }
    }

    private static func make(virtual: Bool, virtualClip: VirtualClipClient) -> (any ClipClient, HotspotJoiner, any DoorbellRinging) {
        if virtual {
            let probe: @Sendable () async -> Bool = { (try? await virtualClip.status()) != nil }
            let bell = VirtualDoorbell(clip: virtualClip)
            return (virtualClip, HotspotJoiner(configurator: VirtualHotspotConfigurator(clip: virtualClip),
                                               probeAttempts: 1, doorbell: bell, probe: probe), bell)
        }
        let http = HTTPClipClient()
        let prober = HTTPClipClient(requestTimeout: 1.5)
        let probe: @Sendable () async -> Bool = { (try? await prober.status()) != nil }
        #if os(iOS) && !targetEnvironment(simulator)
        let configurator: any HotspotConfiguring = SystemHotspotConfigurator()
        #else
        let configurator: any HotspotConfiguring = ImmediateHotspotConfigurator()
        #endif
        // CoreBluetooth on the simulator reports "unsupported": the doorbell then falls back to the button.
        let bell = PixelClipDoorbell(radio: CoreBluetoothRadio())
        return (http, HotspotJoiner(configurator: configurator, doorbell: bell, probe: probe), bell)
    }

    private func rebuild() {
        doorbell.release()
        let (c, j, d) = Self.make(virtual: useVirtual, virtualClip: virtualClip)
        let broker = ClipLinkBroker(doorbell: d, joiner: j)
        links = broker
        http = c
        client = SmartClipClient(http: c, links: broker)
        joiner = j
        doorbell = d
        wireLinks()
        joiner.bluetoothWake = AppSettings.shared.bluetoothWake
        status = nil
        config = nil
        clipPlaylist = nil
        problem = nil
        screen = nil
        screenKey = ""
        imu = nil
    }

    private func wireLinks() {
        links.onJoined = { [weak self] in self?.joinedWiFi() }
        // Each connect asks which passphrase to join with (HotspotPasswords.plan), from what the clip last
        // said about its own (`ap_password_set`, read with the config over Bluetooth or Wi‑Fi).
        joiner.passwordPlan = { [weak self] in self?.hotspotPlan ?? .join([HotspotDefaults.password]) }
        joiner.passphrase = passwords.effective
        joiner.rememberedPassphrase = passwords.remembered
        joiner.onRememberedChange = { [weak self] p in self?.passwords.setRemembered(p) }
        links.onRoute = { [weak self] r in
            self?.lastRoute = r
            let (kind, id) = AppLog.routeParts(r.route)
            sendLog(kind, peer: id, then: " over \(r.transport == .bluetooth ? "Bluetooth" : "Wi‑Fi")\(r.fellBack ? " (Bluetooth failed first)" : "") · \(String(format: "%.2f", r.seconds)) s")
        }
        doorbell.onLog = { line in
            // The two lines that carry the name a peripheral advertises ("heard PixelClip-1A2B (−58 dBm)").
            for verb in ["bluetooth: heard ", "bluetooth: found "] where line.hasPrefix(verb) {
                sendLog(verb, peer: String(line.dropFirst(verb.count)))
                return
            }
            sendLog(line)
        }
    }

    var state: HotspotState { joiner.state }
    var isConnected: Bool { joiner.state == .joined }
    /// Waking over Bluetooth or joining the Wi‑Fi.
    var isConnecting: Bool { joiner.state == .waking || joiner.state == .joining }
    /// The clip's screen keeps playing during a session (PROTOCOL §3), so brightness, Next and Show
    /// Now apply live. False only when the clip reports the panel-off mode.
    var screenStaysOn: Bool { config?.screenStaysOn ?? true }
    /// The clip's name as it says it (tidied: it is the clip's text, not the app's).
    var displayName: String { AppLog.tidy(config?.name ?? status?.device.name ?? "PixelClip") }
    var ssid: String { status?.ssid ?? "\(HotspotDefaults.ssidPrefix)…" }

    // MARK: Connection

    /// Wake the clip over Bluetooth (Settings ▸ Bluetooth Wake), join the hotspot (if needed), then
    /// read status and config. Without an answer over Bluetooth the join is still tried (the button
    /// may have been pressed); its failure carries the button instructions.
    @discardableResult
    func connect() async -> Bool {
        await settle()
        problem = nil
        joiner.bluetoothWake = AppSettings.shared.bluetoothWake
        let s = await joiner.connect()
        guard s == .joined else {
            problem = SendProblem(join: joiner.failure)
            return false
        }
        joinedWiFi()
        return await refresh()
    }

    /// On the clip's Wi‑Fi: don't hold Bluetooth during the session.
    func joinedWiFi() {
        doorbell.release()
        if passwords.didJoin(with: joiner.lastJoinPassphrase) { sendLog("hotspot: joined with the new Wi‑Fi password · kept") }
        if let p = joiner.lastJoinPassphrase, p == passwords.current { setUpSessionOpenSince = nil }
        if joiner.lastJoinRemembered == true, !networkRemembered {
            networkRemembered = true
            UserDefaults.standard.set(true, forKey: Keys.remembered)
        }
    }

    // MARK: Faster sends

    /// Ends the session after the send sheet has closed: reads the new state (the Clip tab's "now
    /// playing"), then `POST /session/end`. Errors are silent: the clip times out anyway.
    /// `done` gets the seconds it took.
    func endSessionInBackground(refreshTexts: Bool, done: @escaping @MainActor (Double) -> Void) {
        let start = Date()
        endingTask = Task { [weak self] in
            guard let self else { return }
            await self.refresh()
            if refreshTexts, let texts = try? await self.client.texts() { ReaderStore.shared.recordClipTexts(texts) }
            if (try? await self.client.endSession()) != nil { self.setUpSessionOpenSince = nil }
            self.markSessionEnded()
            await self.updateVirtualScreen()
            self.endingTask = nil
            done(Date().timeIntervalSince(start))
        }
    }

    /// Wait for a background session end (a new send or connect mustn't race it).
    func settle() async {
        await endingTask?.value
    }

    /// This iPhone's last `POST /time` to the connected clip.
    var lastClockSync: Date? {
        guard let id = status?.device.id else { return nil }
        return UserDefaults.standard.object(forKey: Keys.clockSync + id) as? Date
    }

    func recordClockSync(at date: Date = Date()) {
        guard let id = status?.device.id else { return }
        UserDefaults.standard.set(date, forKey: Keys.clockSync + id)
    }

    /// The clip was erased: what it was last read to hold goes at once (the session's end reads it again).
    func clipWasErased(_ report: EraseReport) {
        clipPlaylist = .empty
        status?.storage = report.storage
        status?.playlist = ClipStatus.PlaylistState(count: 0, index: -1, current: nil)
        status?.queue?.pending = 0
        status?.queue?.nextAt = nil
        status?.oracle = nil
    }

    /// Settings ▸ Forget Clip: remove the remembered Wi‑Fi (iOS asks to join again next time) and the
    /// clock record (the next send sets the clock).
    func forgetClip() async {
        await endingTask?.value
        await joiner.forgetNetwork()
        networkRemembered = false
        UserDefaults.standard.set(false, forKey: Keys.remembered)
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix(Keys.clockSync) {
            UserDefaults.standard.removeObject(forKey: key)
        }
        status = nil
        imu = nil
    }

    // MARK: Hotspot password

    /// What the next join uses (see `HotspotPasswords.plan`), from the config last read. Right after the
    /// automatic setup the clip's Wi‑Fi session that took the new passphrase still runs with the factory one
    /// (a new passphrase applies from the next session): until that session is known to have ended (the app
    /// ended it, a join with the new one went through, or its idle timeout has passed), the factory one is
    /// tried first.
    var hotspotPlan: HotspotPasswordPlan {
        let plan = passwords.plan(clipReportsSet: config?.apPasswordSet)
        if case .join(let list) = plan, let current = passwords.current, list == [current], let since = setUpSessionOpenSince {
            let limit = config?.wifiAlwaysOn == true ? .infinity : TimeInterval((config?.uploadTimeoutS ?? 120) + 30)
            if Date().timeIntervalSince(since) < limit { return .join([HotspotDefaults.password, current]) }
        }
        return plan
    }

    /// The setup's own Wi‑Fi session (still on the factory passphrase) may be running since then.
    @ObservationIgnored private var setUpSessionOpenSince: Date?

    /// The app ended the clip's Wi‑Fi session (the next one uses the clip's newest passphrase).
    func clipEndedSession() {
        setUpSessionOpenSince = nil
        markSessionEnded()
    }

    /// The clip says its passphrase is the factory one again while this iPhone holds its own.
    var clipPasswordWasReset: Bool { hotspotPlan == .blocked(.clipWasReset) }

    /// The automatic first setup (on the clip's Wi‑Fi, after reading its config): a clip that still has the
    /// factory passphrase, while this iPhone uses it too, gets a random one of its own, saved here first and
    /// sent over HTTP (never the fast lane). It applies from the clip's next Wi‑Fi session. Nothing to do
    /// for firmware that doesn't report `ap_password_set`, nor over a passphrase the person entered.
    private func setUpHotspotPasswordIfNeeded() async {
        guard isConnected, config?.apPasswordSet == false, passwords.current == nil, !passwords.isSettingUp else { return }
        let http = http
        var answer: ClipConfig?
        let result = await passwords.setUpIfNeeded(clipReportsSet: false) { password in
            answer = try await http.putConfig(ClipConfig(apPassword: password))
        }
        switch result {
        case .done:
            var cfg = answer ?? config ?? ClipConfig()
            cfg.apPasswordSet = true
            config = cfg
            setUpSessionOpenSince = Date()
            sendLog("hotspot: the clip has its own Wi‑Fi password now (from its next Wi‑Fi session), saved on this iPhone")
            if !useVirtual {
                showsPasswordNotice = true
                UserDefaults.standard.set(true, forKey: Keys.passwordNotice)
            }
        case .storeFailed:
            sendLog("hotspot: this iPhone couldn’t save a new Wi‑Fi password · the clip keeps its factory one")
        case .clipFailed:
            sendLog("hotspot: the clip didn’t confirm its new Wi‑Fi password · tried again at the next connection")
        case .notNeeded:
            break
        }
    }

    /// "Set up again" (the clip's passphrase was reset on the clip): forget this iPhone's copy; the next join
    /// uses the factory passphrase and the setup runs again.
    func setUpHotspotPasswordAgain() {
        passwords.clear()
        sendLog("hotspot: set up again · joining with the factory Wi‑Fi password, then a new one")
    }

    /// Settings ▸ Advanced: a passphrase typed by the person (one another iPhone set). Why it can't be
    /// used, or nil when saved.
    func setHotspotPasswordManually(_ text: String) -> String? {
        let problem = passwords.setManually(text)
        if problem == nil { sendLog("hotspot: Wi‑Fi password \(passwords.current == nil ? "back to the factory one" : "entered in Settings")") }
        return problem
    }

    func dismissPasswordNotice() {
        showsPasswordNotice = false
        UserDefaults.standard.set(false, forKey: Keys.passwordNotice)
    }

    // MARK: Motion sensor

    /// `GET /imu` (connected only).
    @discardableResult
    func readIMU() async throws -> IMUReading {
        let r = try await client.imu()
        imu = r
        return r
    }

    /// Settings ▸ Motion Sensor ▸ Reset Calibration: back to the compiled map.
    func resetIMUCalibration() async -> Bool {
        do {
            _ = try await client.calibrateIMU(.reset)
            imu = try? await client.imu()
            return true
        } catch {
            handle(error)
            return false
        }
    }

    @discardableResult
    func refresh() async -> Bool {
        do {
            let st = try await client.status()
            try st.checkProtocol()
            status = st
            let cfg = try await client.config()
            config = cfg
            await setUpHotspotPasswordIfNeeded()
            clipPlaylist = try? await client.playlist()
            brightness = Double(cfg.brightness ?? 160)
            lastUpdated = Date()
            problem = nil
            AppSettings.shared.lastFirmware = st.device.fw
            await reconcileBluetoothWake(cfg)
            return true
        } catch {
            handle(error)
            return false
        }
    }

    /// Ends the clip's session: `0x02` over Bluetooth when the link is still up (e.g. a session the
    /// button started), else `POST /session/end`. The clip turns Wi‑Fi off (and, in panel-off mode,
    /// its screen back on).
    func endSession() async {
        if await doorbell.endSession() {
            problem = nil
            setUpSessionOpenSince = nil
        } else {
            await perform { try await $0.endSession() }
            if problem == nil { setUpSessionOpenSince = nil }
        }
        joiner.markDisconnected()
        await updateVirtualScreen()
    }

    // MARK: Bluetooth (nearby, wake preference)

    /// The clip as last heard over Bluetooth (nil when not seen on the last look).
    var nearby: DoorbellNearby? { doorbell.nearby }

    /// "Nearby · 64 %" for the Clip tab while not on the clip's Wi‑Fi.
    var nearbyLine: String? {
        guard !isConnected, let n = nearby else { return nil }
        guard let pct = n.status?.percent else { return "Nearby" }
        return "Nearby · \(pct) %"
    }

    /// The clip's Wi‑Fi is on (its status says so) but this iPhone isn't on it.
    var nearbySessionActive: Bool { !isConnected && nearby?.linked == true && nearby?.status?.sessionActive == true }

    /// A short Bluetooth look for the Clip tab (on appear, then every 30 s while it's visible).
    /// Never prompts for permission (the first Connect does), never while connecting or connected.
    func peekNearby() async {
        guard AppSettings.shared.bluetoothWake, !isConnected, !isConnecting, doorbell.canScanSilently else {
            sendLog("look skipped: \(!AppSettings.shared.bluetoothWake ? "Bluetooth Wake is off in Settings" : isConnected ? "on the clip’s Wi‑Fi" : isConnecting ? "connecting" : "Bluetooth isn’t allowed yet")")
            return
        }
        await doorbell.peek()
        lastLookAt = Date()
        if let n = nearby {
            sendLog("look: near · ", peer: n.name, then: "\(n.linked ? " · linked" : "")\(n.status.map { " · \($0.percent)%" } ?? "")")
        } else {
            sendLog("look: not near")
        }
    }

    /// Stop scanning and drop the Bluetooth link (Clip tab hidden, app in the background). A wake in
    /// progress is left alone.
    func releaseBluetooth() {
        guard joiner.state != .waking else { return }
        doorbell.release()
    }

    /// Settings ▸ Bluetooth Wake. Connected (Wi‑Fi or the fast lane): written to the clip's
    /// `ble_wake`. Otherwise kept on this iPhone (the app skips the doorbell) and sent at the next connect.
    func setBluetoothWake(_ on: Bool) async {
        let settings = AppSettings.shared
        if !isConnected, config != nil, fastLaneReady {
            // Over the fast lane, before the phone stops using Bluetooth. Turning it off switches the
            // clip's radio off mid-request: its answer is lost, which is the expected outcome.
            notice = nil
            do {
                config = try await client.putConfig(ClipConfig(bleWake: on))
                settings.bluetoothWakePending = false
            } catch let e as ClipError where !on && e.isUnreachable {
                config?.bleWake = false
                settings.bluetoothWakePending = false
            } catch {
                settings.bluetoothWakePending = true
            }
            settings.bluetoothWake = on
            joiner.bluetoothWake = on
            if !on { doorbell.release() }
            return
        }
        settings.bluetoothWake = on
        joiner.bluetoothWake = on
        if !on { doorbell.release() }
        if isConnected, config != nil {
            settings.bluetoothWakePending = false
            await updateConfig(ClipConfig(bleWake: on))
        } else {
            settings.bluetoothWakePending = true
        }
    }

    // MARK: Fast lane (PROTOCOL §3b)

    /// Not on the clip's Wi‑Fi, but linked over Bluetooth with the fast lane: settings, quick actions
    /// and small sends go over Bluetooth, with no hotspot.
    var fastLaneReady: Bool {
        AppSettings.shared.bluetoothWake && !isConnected && doorbell.fastLaneLinked
    }

    /// Links over Bluetooth for the fast lane (scanning for the nearby clip if needed). True when it's up.
    func openFastLane() async -> Bool {
        guard AppSettings.shared.bluetoothWake, !isConnected else { return false }
        return await links.fastLane() != nil
    }

    /// Home: the clip's `/status` over a fast-lane link that is already up (what it plays right now),
    /// never opening Wi‑Fi and never during a send.
    func refreshStatusIfLinked() async {
        guard fastLaneReady, !isSending, let lane = await links.fastLane() else { return }
        if let st = try? await lane.status() {
            status = st
            lastUpdated = Date()
        }
    }

    /// Status, config and playlist over the fast lane (Settings and the Clip tab while not on Wi‑Fi).
    @discardableResult
    func refreshOverBluetooth() async -> Bool {
        guard !isConnected, await openFastLane() else { return false }
        return await refresh()
    }

    /// The Clip tab's Next.
    func quickNext() async -> Bool {
        await perform { try await $0.next() }
        if problem == nil { await afterQuickAction() }
        return problem == nil
    }

    enum QuickShow: Equatable { case shown, needsUpload(String), nothing, failed }

    /// The Clip tab's Show Now: what PixelClip plays now (`NowOnClip`) on screen at once — a picture
    /// already on the clip. A picture the clip lacks needs the send sheet (Wi‑Fi).
    func quickShowNow() async -> QuickShow {
        guard let content = NowOnClip.shared.item?.content else { return .nothing }
        let result: QuickShow
        switch content {
        case .asset(let id):
            do {
                try await client.show(id: id, durationMs: nil)
                problem = nil
                result = .shown
            } catch ClipError.http(404, _) {
                result = .needsUpload(id)
            } catch {
                handle(error)
                result = .failed
            }
        default:
            return .nothing
        }
        if result == .shown { await afterQuickAction() }
        return result
    }

    enum Ask: Equatable { case asked, notShowing, failed }

    /// Home's Draw (an oracle is Now): `POST /oracle/draw`, over Bluetooth when no Wi‑Fi session is
    /// open (never retried over Wi‑Fi: a second draw would draw again). `notShowing` (409): the clip
    /// isn't showing the oracle (not sent yet, or a one-off is playing).
    func oracleDraw() async -> Ask { await oracleAction { try await $0.oracleDraw(cards: nil) } }

    /// The oracle on the clip as best known: the virtual clip's live state, else the last `/status`.
    var oracleNow: ClipStatus.OracleStatus? { useVirtual ? (screenOracle ?? status?.oracle) : status?.oracle }

    /// Home's Back: `POST /oracle/back` (the clip's double-tap, §5f.3), like Turn.
    func oracleBack() async -> Ask { await oracleAction { try await $0.oracleBack() } }

    /// Home's Turn: `POST /oracle/turn` (like a short press of the clip's button).
    func oracleTurn() async -> Ask { await oracleAction { try await $0.oracleTurn() } }

    private func oracleAction(_ op: (any ClipClient) async throws -> Void) async -> Ask {
        do {
            try await op(client)
            problem = nil
        } catch ClipError.http(409, _) {
            return .notShowing
        } catch {
            handle(error)
            return .failed
        }
        // The new state (what's on screen) for Home's Turn button.
        if let s = try? await client.status() { status = s }
        await afterQuickAction()
        return .asked
    }

    /// The Clip tab's brightness slider: live while dragging, stored on release (`PUT /config`).
    func quickBrightness(commit: Bool) async {
        if commit {
            let v = Int(brightness.rounded())
            await perform { client in
                let cfg = try await client.putConfig(ClipConfig(brightness: v))
                await MainActor.run { self.config = cfg }
            }
            return
        }
        // While dragging: one `POST /brightness` at a time, always the latest value.
        guard !brightnessSending else { brightnessDirty = true; return }
        brightnessSending = true
        defer { brightnessSending = false }
        repeat {
            brightnessDirty = false
            try? await client.setBrightness(Int(brightness.rounded()))
        } while brightnessDirty
    }

    /// The Clip tab's End Session while not on the clip's Wi‑Fi: `POST /session/end` over the fast lane.
    func quickEndSession() async {
        await perform { try await $0.endSession() }
        if problem == nil { setUpSessionOpenSince = nil }
        joiner.markDisconnected()
        await afterQuickAction()
    }

    /// Fresh status for the Nearby card and the virtual screen.
    private func afterQuickAction() async {
        await doorbell.peek()
        await updateVirtualScreen()
    }

    /// After a send that went entirely over Bluetooth: read the new state (no session to end).
    func refreshInBackground(done: @escaping @MainActor (Double) -> Void) {
        let start = Date()
        endingTask = Task { [weak self] in
            guard let self else { return }
            await self.refresh()
            await self.doorbell.peek()
            await self.updateVirtualScreen()
            self.endingTask = nil
            done(Date().timeIntervalSince(start))
        }
    }

    /// After reading the config: send a change made while away, else follow the clip.
    private func reconcileBluetoothWake(_ cfg: ClipConfig) async {
        let settings = AppSettings.shared
        if settings.bluetoothWakePending {
            settings.bluetoothWakePending = false
            if cfg.bleWake != settings.bluetoothWake, let c = try? await client.putConfig(ClipConfig(bleWake: settings.bluetoothWake)) {
                config = c
            }
        } else if let clipValue = cfg.bleWake, clipValue != settings.bluetoothWake {
            settings.bluetoothWake = clipValue
            joiner.bluetoothWake = clipValue
        }
    }

    /// Settings ▸ Screen Stays On While Connected (`display_during_upload`).
    func setScreenStaysOn(_ on: Bool) async {
        await updateConfig(ClipConfig(displayDuringUpload: on))
    }

    /// Settings ▸ Always Reachable (`wifi_always_on`).
    func setAlwaysReachable(_ on: Bool) async {
        await updateConfig(ClipConfig(wifiAlwaysOn: on))
    }

    /// Settings ▸ Orientation (`orientation`, PROTOCOL §4): applies at once on the clip, then the
    /// status is read again so the Clip tab shows whether the screen is flipped now.
    func setOrientation(_ mode: ClipOrientationMode) async {
        await updateConfig(ClipConfig(orientation: mode))
        guard problem == nil else { return }
        if let st = try? await client.status() { status = st }
        await updateVirtualScreen()
    }

    /// The clip's screen is turned 180° right now: the virtual panel as it is, else the last status.
    var isScreenFlipped: Bool { useVirtual ? screenFlipped : status?.isFlipped == true }

    func markSessionEnded() {
        joiner.markDisconnected()
    }

    // MARK: Controls

    /// Live brightness (`POST /brightness`): visible at once when the screen stays on during
    /// sessions, else when the session ends.
    func previewBrightness() async {
        guard isConnected || fastLaneReady else { return }
        await quickBrightness(commit: false)
    }

    /// Persist on release (`PUT /config`).
    func commitBrightness() async {
        guard isConnected || fastLaneReady else { return }
        let v = Int(brightness.rounded())
        await perform { client in
            let cfg = try await client.putConfig(ClipConfig(brightness: v))
            await MainActor.run { self.config = cfg }
        }
    }

    func rename(_ name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != config?.name else { return }
        await updateConfig(ClipConfig(name: String(trimmed.utf8.prefix(64)) ?? trimmed))
    }

    func setUploadTimeout(_ seconds: Int) async {
        await updateConfig(ClipConfig(uploadTimeoutS: min(max(seconds, 30), 1800)))
    }

    /// The level at which the clip shows "Battery low" and puts itself to sleep (firmware default 8 %).
    func setLowBatteryPct(_ pct: Int) async {
        await updateConfig(ClipConfig(lowBatteryPct: pct))
    }

    private func updateConfig(_ patch: ClipConfig) async {
        notice = nil
        if let problem = patch.validationProblem { notice = problem; return }
        await perform { client in
            let cfg = try await client.putConfig(patch)
            await MainActor.run { self.config = cfg }
        }
    }

    func next() async { await perform { try await $0.next() } }
    func previous() async { await perform { try await $0.previous() } }

    func screenshot() async -> ClipFrames? {
        var result: ClipFrames?
        await perform { client in
            let frame = try await client.screenshot()
            result = ClipFrames(single: ClipRenderer.makeCGImage(frame))
        }
        if let result, !useVirtual { screen = result }
        return result
    }

    enum FirmwareStep: Equatable {
        case idle
        /// Waking the clip and asking it for the button press.
        case asking
        /// "Press the button on your clip", with the seconds left.
        case waitingForPress(Int)
        case uploading(Double)
        case installed
        /// The window ran out (or the upload asked for the press again and didn't get it).
        case notPressed
        case failed
    }

    /// Settings ▸ Advanced ▸ Update firmware: ask the clip, wait for its button, then upload
    /// (`FirmwareUpdater`; older firmware takes the upload at once).
    func startFirmwareUpdate(_ data: Data) {
        guard firmwareTask == nil else { return }
        firmwareImage = data
        firmwareStep = .asking
        sendLog("firmware: asking the clip for a press of its button")
        firmwareTask = Task { [weak self] in
            guard let self else { return }
            defer { self.firmwareTask = nil }
            let updater = FirmwareUpdater(client: self.client)
            self.isWorking = true
            defer { self.isWorking = false }
            do {
                try await updater.run(data) { [weak self] event in
                    guard let self, self.firmwareTask != nil else { return }
                    switch event {
                    case .waitingForPress(let s): self.firmwareStep = .waitingForPress(s)
                    case .uploading(let p): if self.firmwareStep != .installed { self.firmwareStep = .uploading(p) }
                    }
                }
                self.firmwareStep = .installed
                self.firmwareImage = nil
                self.problem = nil
                self.joiner.markDisconnected()   // the clip reboots
                sendLog("firmware: sent · the clip restarts")
            } catch FirmwareUpdater.Failure.notPressed {
                self.firmwareStep = .notPressed
                sendLog("firmware: the clip’s button wasn’t pressed in time")
            } catch let e as ClipError where e.isPressButton {
                self.firmwareStep = .notPressed
                sendLog("firmware: the clip still wants its button pressed")
            } catch is CancellationError {
                self.firmwareStep = .idle
                self.firmwareImage = nil
                sendLog("firmware: cancelled")
            } catch {
                self.handle(error)
                self.firmwareStep = .failed
                self.firmwareImage = nil
            }
        }
    }

    /// The waiting screen's Cancel (the clip stops asking by itself when its window ends).
    func cancelFirmwareUpdate() {
        firmwareTask?.cancel()
        firmwareTask = nil
        firmwareStep = .idle
        firmwareImage = nil
    }

    /// "Try again" after the window ran out: the same image.
    func retryFirmwareUpdate() {
        guard let data = firmwareImage else { firmwareStep = .idle; return }
        startFirmwareUpdate(data)
    }

    /// Back to the button (after Installed, a failure, or Not pressed).
    func resetFirmwareStep() {
        guard firmwareTask == nil else { return }
        firmwareStep = .idle
        firmwareImage = nil
    }

    private func perform(_ body: (any ClipClient) async throws -> Void) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await body(client)
            problem = nil
        } catch {
            handle(error)
        }
    }

    private func handle(_ error: any Error) {
        let p = SendProblem(error: error, batteryWasLow: batteryWasLow)
        sendLog("clip error: ", peer: error.localizedDescription, then: " → \(p.title)")
        if p == .clipNotAnswering || p == .lowBatteryEndedSession { joiner.markDisconnected() }
        problem = p
    }

    /// The last status was close to the clip's 3.5 V Wi‑Fi cutoff (and not on USB): a dropped
    /// connection then most likely means the clip ended the session to protect its battery.
    var batteryWasLow: Bool {
        guard let b = status?.battery else { return false }
        return BatteryReading(b).level == .critical
    }

    /// The clip's battery as last read.
    var battery: BatteryReading? { status?.battery.map(BatteryReading.init) }

    // MARK: Virtual screen

    /// Poll the virtual panel (called from a TimelineView-driven task while visible).
    func updateVirtualScreen() async {
        guard useVirtual else { return }
        let d = await virtualClip.display()
        if screenLevel != d.level { screenLevel = d.level }
        if screenAwake != d.isAwake { screenAwake = d.isAwake }
        if screenNow != d.nowShowing { screenNow = d.nowShowing }
        if screenQueueID != d.queueID { screenQueueID = d.queueID }
        if screenFlipped != d.flipped { screenFlipped = d.flipped }
        if screenOracle != d.oracle { screenOracle = d.oracle }
        guard d.key != screenKey else { return }
        screenKey = d.key
        let frame = d.frame
        let image = await Task.detached(priority: .userInitiated) { ClipRenderer.makeCGImage(frame) }.value
        screen = ClipFrames(single: image)
    }

    func resetVirtualClip() async {
        await virtualClip.reset()
        screenKey = ""
        status = nil
        config = nil
        clipPlaylist = nil
        virtualPasswords.clear()
        virtualPasswords.setRemembered(nil)
        joiner.markDisconnected()
        await updateVirtualScreen()
    }

    /// Debug: the virtual clip's button pressed five times and held (its passphrase back to the factory one).
    func resetVirtualClipPassword() async {
        await virtualClip.resetPasswordOnClip()
        sendLog("debug: the virtual clip’s Wi‑Fi password was reset on the clip")
    }

    // MARK: Status line

    /// A send is running (any `SyncController`, sheet or quiet).
    var isSending: Bool { sendingCount > 0 }
    private(set) var sendingCount = 0
    /// When Bluetooth last looked for the clip (`peekNearby`); nil: not yet this launch.
    private(set) var lastLookAt: Date?

    func beginSending() { sendingCount += 1 }
    func endSending() { sendingCount = max(0, sendingCount - 1) }

    /// The clip is within reach: on its Wi‑Fi, or heard over Bluetooth on the last look (green dot).
    var isNearby: Bool { isConnected || nearby != nil }

    /// The battery as last heard: the status read, else the Bluetooth status.
    var currentBattery: BatteryReading? {
        if let b = battery, b.pct != nil { return b }
        return nearby?.status.map { BatteryReading($0.battery) }
    }

    /// Home's status line, in plain words: "sending…", "nearby · 82%", "looking for the clip…",
    /// "can't find the clip, is it on?". The header puts the clip's name before it.
    var statusLine: String {
        if isSending || isConnecting { return "sending…" }
        if isNearby {
            guard let pct = currentBattery?.pct else { return "nearby" }
            return "nearby · \(pct)%"
        }
        if lastLookAt == nil && AppSettings.shared.bluetoothWake && doorbell.canScanSilently { return "looking for the clip…" }
        return "can’t find the clip, is it on?"
    }

    /// Settings ▸ Clip ▸ Battery: "82% · about 4 h left", "64% · charging", nil when never heard.
    var batteryLine: String? {
        guard let b = currentBattery, let pct = b.pct else { return nil }
        if b.onUSB { return "\(pct)% · charging" }
        return b.wearLeftText.map { "\(pct)% · \($0) left" } ?? "\(pct)%"
    }

    // MARK: Formatting

    var stateLine: String {
        switch joiner.state {
        case .notJoined:
            if let line = nearbyLine { useVirtual ? "Virtual clip · \(line.prefix(1).lowercased() + line.dropFirst())" : line }
            else { useVirtual ? "Virtual clip · not connected" : "Not connected" }
        case .waking: "Waking over Bluetooth…"
        case .joining: "Joining \(HotspotDefaults.ssidPrefix)…"
        case .joined: useVirtual ? "Connected · virtual" : "Connected · \(ssid)"
        case .unreachable: "Can’t reach the clip"
        }
    }
}
