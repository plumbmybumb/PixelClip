import XCTest
@testable import PixelClipKit

/// Records every configurator call ("join <passphrase> remembered|once", "forget").
final class RecordingConfigurator: HotspotConfiguring, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    /// Passphrases that join; any other is reported like a missing network (as iOS does with a wrong one).
    let accepts: Set<String>
    init(accepts: Set<String>) { self.accepts = accepts }
    var calls: [String] { lock.withLock { _calls } }
    func join(ssidPrefix: String, passphrase: String, remember: Bool) async throws {
        lock.withLock { _calls.append("join \(passphrase) \(remember ? "remembered" : "once")") }
        guard accepts.contains(passphrase) else { throw HotspotJoinError.unavailable("not found") }
    }
    func forget(ssidPrefix: String) async { lock.withLock { _calls.append("forget") } }
}

@MainActor
final class HotspotPasswordTests: XCTestCase {
    let factory = HotspotDefaults.password

    // MARK: Choosing the passphrase

    func testPlanEveryBranch() {
        typealias P = HotspotPasswords
        // current set: it, unless the clip says it has the factory passphrase again.
        XCTAssertEqual(P.plan(current: "mine", pending: nil, clipReportsSet: true), .join(["mine"]))
        XCTAssertEqual(P.plan(current: "mine", pending: nil, clipReportsSet: nil), .join(["mine"]))
        XCTAssertEqual(P.plan(current: "mine", pending: nil, clipReportsSet: false), .blocked(.clipWasReset),
                       "never a silent fall back to the published passphrase")
        XCTAssertEqual(P.plan(current: "mine", pending: "next", clipReportsSet: false), .blocked(.clipWasReset))
        XCTAssertEqual(P.plan(current: "mine", pending: "next", clipReportsSet: true), .join(["mine"]))
        // only pending.
        XCTAssertEqual(P.plan(current: nil, pending: "next", clipReportsSet: true), .join(["next"]))
        XCTAssertEqual(P.plan(current: nil, pending: "next", clipReportsSet: false), .join([factory]))
        XCTAssertEqual(P.plan(current: nil, pending: "next", clipReportsSet: nil), .join(["next", factory]))
        // neither.
        XCTAssertEqual(P.plan(current: nil, pending: nil, clipReportsSet: true), .blocked(.passwordUnknown))
        XCTAssertEqual(P.plan(current: nil, pending: nil, clipReportsSet: false), .join([factory]))
        XCTAssertEqual(P.plan(current: nil, pending: nil, clipReportsSet: nil), .join([factory]))
    }

    func testBlockedPlansMapToTheirProblems() {
        XCTAssertEqual(SendProblem(join: .clipWasReset), .clipPasswordReset)
        XCTAssertEqual(SendProblem(join: .passwordUnknown), .clipPasswordUnknown)
        XCTAssertEqual(SendProblem.clipPasswordUnknown.title + ". " + SendProblem.clipPasswordUnknown.message,
                       "This clip has its own Wi‑Fi password. Enter it in Settings, Advanced, or reset it on the clip: press its button five times quickly, then hold.")
        for p in [SendProblem.clipPasswordReset, .clipPasswordUnknown] {
            XCTAssertFalse(p.needsConnectionHelp, "not an out-of-reach problem: the send isn't retried every 10 s")
            XCTAssertFalse(p.message.contains("—"))
            XCTAssertFalse(p.message.contains("!"))
            XCTAssertTrue(p.message.hasSuffix("."))
        }
        XCTAssertFalse(SendProblem.wrongPassword.message.contains(factory), "the factory passphrase is no longer the normal state")
    }

    // MARK: The generator

    func testGeneratorLengthAlphabetAndValidity() {
        let alphabet = Set(HotspotPasswordGenerator.alphabet)
        XCTAssertEqual(alphabet.count, 57)
        for ambiguous in "0O1lI" { XCTAssertFalse(alphabet.contains(ambiguous), "\(ambiguous)") }
        var seen = Set<String>()
        for _ in 0..<2000 {
            let p = HotspotPasswordGenerator.generate()
            XCTAssertEqual(p.count, 24)
            XCTAssertTrue(p.allSatisfy { alphabet.contains($0) }, p)
            XCTAssertTrue(p.unicodeScalars.allSatisfy { $0.isASCII && $0.value >= 0x20 && $0.value <= 0x7E })
            XCTAssertNil(ClipConfig(apPassword: p).validationProblem, "8 to 63 printable ASCII")
            seen.insert(p)
        }
        XCTAssertEqual(seen.count, 2000, "no repeats")
        // Every character turns up (a broken sampler would leave some out).
        let all = (0..<200).map { _ in HotspotPasswordGenerator.generate() }.joined()
        XCTAssertEqual(Set(all), alphabet)
    }

    // MARK: The store: migration, pending, promotion

    func testMigrationFromUserDefaults() {
        var pw = HotspotPasswords(store: InMemoryHotspotPasswordStore())
        XCTAssertTrue(pw.migrate(legacy: nil))
        XCTAssertTrue(pw.migrate(legacy: factory), "the factory value is the default: nothing to keep")
        XCTAssertNil(pw.current)
        XCTAssertTrue(pw.migrate(legacy: "typed-on-this-phone"))
        XCTAssertEqual(pw.current, "typed-on-this-phone")
        XCTAssertTrue(pw.migrate(legacy: "another"), "once: an existing current wins")
        XCTAssertEqual(pw.current, "typed-on-this-phone")
        // Reloaded from the store.
        let store = InMemoryHotspotPasswordStore([.current: "kept"])
        pw = HotspotPasswords(store: store)
        XCTAssertEqual(pw.current, "kept")
        // The Keychain refuses: used for this launch, the old copy stays.
        let broken = InMemoryHotspotPasswordStore()
        broken.failWrites(to: [.current])
        pw = HotspotPasswords(store: broken)
        XCTAssertFalse(pw.migrate(legacy: "typed"))
        XCTAssertEqual(pw.current, "typed")
    }

    func testSetupWritesPendingThenPromotes() async throws {
        let store = InMemoryHotspotPasswordStore()
        let pw = HotspotPasswords(store: store, generate: { "Abcdefghjkmnpqrstuvwxyz2" })
        var sent: [String] = []
        let r = await pw.setUpIfNeeded(clipReportsSet: false) { p in
            XCTAssertEqual(try store.read(.pending), p, "saved before the clip is told")
            sent.append(p)
        }
        XCTAssertEqual(r, .done)
        XCTAssertEqual(sent, ["Abcdefghjkmnpqrstuvwxyz2"])
        XCTAssertEqual(pw.current, "Abcdefghjkmnpqrstuvwxyz2")
        XCTAssertNil(pw.pending)
        XCTAssertEqual(try store.read(.current), "Abcdefghjkmnpqrstuvwxyz2")
        XCTAssertNil(try store.read(.pending))
        // Done once: never again over a passphrase this iPhone holds.
        let again = await pw.setUpIfNeeded(clipReportsSet: false) { _ in XCTFail("not twice") }
        XCTAssertEqual(again, .notNeeded)
    }

    func testSetupOnlyWhenTheClipSaysFactory() async {
        let pw = HotspotPasswords(store: InMemoryHotspotPasswordStore())
        for flag in [nil, true] as [Bool?] {
            let r = await pw.setUpIfNeeded(clipReportsSet: flag) { _ in XCTFail("older firmware or a clip with its own: nothing automatic") }
            XCTAssertEqual(r, .notNeeded)
        }
        // A password the person typed is never replaced.
        XCTAssertNil(pw.setManually("from-the-other-phone"))
        let r = await pw.setUpIfNeeded(clipReportsSet: false) { _ in XCTFail("typed passwords stay") }
        XCTAssertEqual(r, .notNeeded)
        XCTAssertEqual(pw.current, "from-the-other-phone")
    }

    func testFailedKeychainWriteLeavesTheClipAlone() async throws {
        let clip = VirtualClipClient(options: .instant)
        let store = InMemoryHotspotPasswordStore()
        store.failWrites(to: [.pending])
        let pw = HotspotPasswords(store: store)
        let r = await pw.setUpIfNeeded(clipReportsSet: false) { p in _ = try await clip.putConfig(ClipConfig(apPassword: p)) }
        XCTAssertEqual(r, .storeFailed)
        XCTAssertNil(pw.current)
        XCTAssertNil(pw.pending)
        let log = await clip.requestLog
        XCTAssertFalse(log.contains("PUT /config"), "the clip wasn't changed")
        let cfg = try await clip.config()
        XCTAssertEqual(cfg.apPasswordSet, false)
    }

    func testLostAnswerRecoversWithPendingOnTheNextConnection() async throws {
        let clip = VirtualClipClient(options: .instant)
        let store = InMemoryHotspotPasswordStore()
        let pw = HotspotPasswords(store: store)
        // The clip takes the passphrase but its answer is lost.
        let r = await pw.setUpIfNeeded(clipReportsSet: false) { p in
            _ = try await clip.putConfig(ClipConfig(apPassword: p))
            throw ClipError.unreachable("the answer was lost")
        }
        XCTAssertEqual(r, .clipFailed)
        XCTAssertNil(pw.current)
        let pending = try XCTUnwrap(pw.pending)
        try await clip.endSession()   // the setup's session ends: the next one uses the new passphrase

        // Next connection: the clip says it has its own (read over Bluetooth): pending, then promoted after the join.
        let flag = try await clip.config().apPasswordSet
        XCTAssertEqual(flag, true)
        XCTAssertEqual(pw.plan(clipReportsSet: flag), .join([pending]))
        let script = ProbeScript([false, true])
        let joiner = HotspotJoiner(configurator: VirtualHotspotConfigurator(clip: clip), probeAttempts: 2,
                                   probeInterval: .milliseconds(1), probe: { script.next() })
        joiner.passwordPlan = { pw.plan(clipReportsSet: flag) }
        let state = await joiner.connect()
        XCTAssertEqual(state, .joined)
        XCTAssertEqual(joiner.lastJoinPassphrase, pending)
        XCTAssertTrue(pw.didJoin(with: joiner.lastJoinPassphrase))
        XCTAssertEqual(pw.current, pending)
        XCTAssertNil(pw.pending)
    }

    func testLostAnswerWithBluetoothOffTriesPendingThenFactory() async throws {
        // The PUT never reached the clip (still factory); the flag is unknown: pending first, then the factory one.
        let clip = VirtualClipClient(options: .instant)
        let pw = HotspotPasswords(store: InMemoryHotspotPasswordStore([.pending: "Pendingpasswordxyz23456"]))
        let script = ProbeScript([false, true])
        let joiner = HotspotJoiner(configurator: VirtualHotspotConfigurator(clip: clip), probeAttempts: 2,
                                   probeInterval: .milliseconds(1), probe: { script.next() })
        joiner.passwordPlan = { pw.plan(clipReportsSet: nil) }
        let state = await joiner.connect()
        XCTAssertEqual(state, .joined)
        XCTAssertEqual(joiner.lastJoinPassphrase, factory)
        XCTAssertFalse(pw.didJoin(with: joiner.lastJoinPassphrase), "joined with the factory one: nothing to promote")
        XCTAssertEqual(pw.pending, "Pendingpasswordxyz23456")
        // On the clip's Wi‑Fi its config says factory: the setup runs again with the same pending passphrase.
        var sent: String?
        let r = await pw.setUpIfNeeded(clipReportsSet: false) { sent = $0 }
        XCTAssertEqual(r, .done)
        XCTAssertEqual(sent, "Pendingpasswordxyz23456")
        XCTAssertEqual(pw.current, "Pendingpasswordxyz23456")
    }

    func testPromotionThatFailsStaysPending() async {
        let store = InMemoryHotspotPasswordStore()
        let pw = HotspotPasswords(store: store, generate: { "Newpasswordabcdefghjkmn2" })
        store.failWrites(to: [.current])
        let r = await pw.setUpIfNeeded(clipReportsSet: false) { _ in }
        XCTAssertEqual(r, .done)
        XCTAssertNil(pw.current)
        XCTAssertEqual(pw.pending, "Newpasswordabcdefghjkmn2", "still tried at the next join")
        XCTAssertEqual(pw.plan(clipReportsSet: true), .join(["Newpasswordabcdefghjkmn2"]))
    }

    func testManualEntryAndSetUpAgain() {
        let pw = HotspotPasswords(store: InMemoryHotspotPasswordStore([.pending: "half-done-setup"]))
        XCTAssertNotNil(pw.setManually("short"), "8 to 63 printable ASCII")
        XCTAssertNotNil(pw.setManually("naïve-password"))
        XCTAssertNil(pw.setManually("the other phone's one"))
        XCTAssertEqual(pw.current, "the other phone's one")
        XCTAssertNil(pw.pending)
        XCTAssertNil(pw.setManually(factory))
        XCTAssertNil(pw.current, "the factory value is the default")
        XCTAssertNil(pw.setManually("again-a-password"))
        pw.clear()
        XCTAssertNil(pw.current)
        XCTAssertEqual(pw.plan(clipReportsSet: false), .join([factory]), "set up again: the factory one, then a new setup")
    }

    // MARK: The joiner

    func testBlockedPlanNeitherRingsNorJoins() async {
        let config = RecordingConfigurator(accepts: [factory])
        let script = ProbeScript([true])
        let j = HotspotJoiner(configurator: config, probeAttempts: 1, probeInterval: .milliseconds(1), probe: { script.next() })
        j.passwordPlan = { .blocked(.clipWasReset) }
        let s = await j.connect()
        guard case .unreachable = s else { return XCTFail("\(s)") }
        XCTAssertEqual(j.failure, .clipWasReset)
        XCTAssertEqual(config.calls, [])
        XCTAssertEqual(script.calls, 0)
        j.passwordPlan = { .blocked(.passwordUnknown) }
        await j.connect()
        XCTAssertEqual(j.failure, .passwordUnknown)
    }

    func testChangedPassphraseReplacesTheRememberedNetwork() async {
        let config = RecordingConfigurator(accepts: ["new-passphrase"])
        let script = ProbeScript([false, true, false, true])
        let j = HotspotJoiner(configurator: config, probeAttempts: 1, probeInterval: .milliseconds(1), probe: { script.next() })
        var changes: [String?] = []
        j.rememberedPassphrase = factory
        j.onRememberedChange = { changes.append($0) }
        j.passwordPlan = { .join(["new-passphrase"]) }
        var s = await j.connect()
        XCTAssertEqual(s, .joined)
        XCTAssertEqual(config.calls, ["forget", "join new-passphrase remembered"], "removed, then installed with the new one")
        XCTAssertEqual(changes, ["new-passphrase"])
        j.markDisconnected()
        s = await j.connect()
        XCTAssertEqual(s, .joined)
        XCTAssertEqual(config.calls.suffix(1), ["join new-passphrase remembered"], "the same one again: no forget")
        XCTAssertEqual(changes, ["new-passphrase"])
        await j.forgetNetwork()
        XCTAssertEqual(changes, ["new-passphrase", nil])
    }

    func testUnknownRememberedPassphraseIsTakenToMatch() async {
        // Installed by an older version (not recorded): no replacement, then recorded.
        let config = RecordingConfigurator(accepts: [factory])
        let script = ProbeScript([false, true])
        let j = HotspotJoiner(configurator: config, probeAttempts: 1, probeInterval: .milliseconds(1), probe: { script.next() })
        var recorded: String?
        j.onRememberedChange = { recorded = $0 }
        await j.connect()
        XCTAssertEqual(config.calls, ["join \(factory) remembered"])
        XCTAssertEqual(recorded, factory)
    }

    // MARK: The config flag

    func testConfigFlagDecodesAndIsNeverSent() throws {
        let dec = ClipJSON.decoder()
        let on = try dec.decode(ClipConfig.self, from: Data(#"{"name":"A","ap_password_set":true}"#.utf8))
        XCTAssertEqual(on.apPasswordSet, true)
        let off = try dec.decode(ClipConfig.self, from: Data(#"{"name":"A","ap_password_set":false}"#.utf8))
        XCTAssertEqual(off.apPasswordSet, false)
        let old = try dec.decode(ClipConfig.self, from: Data(#"{"name":"A","brightness":10}"#.utf8))
        XCTAssertNil(old.apPasswordSet, "older firmware: unknown")
        // A patch never carries it.
        var patch = ClipConfig(brightness: 20)
        patch.apPasswordSet = true
        let json = String(decoding: try ClipJSON.encoder().encode(patch), as: UTF8.self)
        XCTAssertEqual(json, #"{"brightness":20}"#)
        // The clip's own answer does (the virtual clip's fast lane).
        let answer = String(decoding: try ClipJSON.answerEncoder().encode(patch), as: UTF8.self)
        XCTAssertTrue(answer.contains(#""ap_password_set":true"#))
        // A merge keeps the clip's value.
        XCTAssertEqual(on.merging(ClipConfig(brightness: 5)).apPasswordSet, true)
        XCTAssertEqual(on.merging(patch).brightness, 20)
    }

    // MARK: The virtual clip

    func testVirtualClipReportsAndUpdatesTheFlag() async throws {
        let clip = VirtualClipClient(options: .instant)
        var cfg = try await clip.config()
        XCTAssertEqual(cfg.apPasswordSet, false)
        XCTAssertNil(cfg.apPassword)
        // Over Bluetooth: refused, use Wi‑Fi.
        let body = try ClipJSON.encoder().encode(ClipConfig(apPassword: "Bluetoothpassword234567"))
        let overBLE = await VirtualFastLane.respond(to: FastLaneRequest("PUT", "/config", body: body), clip: clip)
        XCTAssertEqual(overBLE.status, 413)
        XCTAssertTrue(String(decoding: overBLE.body, as: UTF8.self).contains("use_wifi"))
        cfg = try await clip.config()
        XCTAssertEqual(cfg.apPasswordSet, false)
        // The fast lane's GET /config carries the flag.
        let read = await VirtualFastLane.respond(to: FastLaneRequest("GET", "/config", body: Data()), clip: clip)
        XCTAssertEqual(try ClipJSON.decoder().decode(ClipConfig.self, from: read.body).apPasswordSet, false)

        // Over Wi‑Fi (a session is open): taken, applies from the next session.
        cfg = try await clip.putConfig(ClipConfig(apPassword: "Wifipasswordabcdefghjk23"))
        XCTAssertEqual(cfg.apPasswordSet, true)
        XCTAssertNil(cfg.apPassword)
        var ok = await clip.acceptsJoin(passphrase: factory)
        XCTAssertTrue(ok, "this session keeps the factory passphrase")
        try await clip.endSession()
        ok = await clip.acceptsJoin(passphrase: "Wifipasswordabcdefghjk23")
        XCTAssertTrue(ok)
        ok = await clip.acceptsJoin(passphrase: factory)
        XCTAssertFalse(ok)

        // Reset on the clip: factory again.
        await clip.resetPasswordOnClip()
        cfg = try await clip.config()
        XCTAssertEqual(cfg.apPasswordSet, false)

        // Older firmware: no flag.
        let old = VirtualClipClient(options: .init(latency: .zero, bytesPerSecond: 0, legacyFirmware: true))
        let oldCfg = try await old.config()
        XCTAssertNil(oldCfg.apPasswordSet)
    }

    func testNewPassphraseNeverTakesTheFastLane() async throws {
        let clip = VirtualClipClient(options: .instant)
        let lane = VirtualFastLane(clip: clip, timing: .instant)
        lane.setConnected(true)
        let http = CountingClipClient(clip)
        let links = FakeLinks(lane: FastLaneClipClient(transport: BLETransport(link: lane)))
        let smart = SmartClipClient(http: http, links: links)
        _ = try await smart.putConfig(ClipConfig(apPassword: "Wifionlypasswordabcdefg2"))
        let calls = await http.calls
        XCTAssertEqual(calls, ["PUT /config"])
        XCTAssertEqual(links.laneAsks, 0, "not even asked for the fast lane")
        XCTAssertEqual(links.wifiOpens, 1)
        let laneLog = await clip.fastLaneLog
        XCTAssertEqual(laneLog, [])
        // Other config changes still use the fast lane while Wi‑Fi is closed.
        links.wifiOpen = false
        _ = try await smart.putConfig(ClipConfig(brightness: 50))
        XCTAssertEqual(links.records.last?.transport, .bluetooth)
        // The fast-lane client itself refuses to carry one.
        let link = ScriptedLink()
        do {
            _ = try await FastLaneClipClient(transport: BLETransport(link: link)).putConfig(ClipConfig(apPassword: "Neveroverbluetooth23456"))
            XCTFail("expected needsWiFi")
        } catch let e as FastLaneError { XCTAssertEqual(e, .needsWiFi) }
        XCTAssertEqual(link.requests.count, 0)
    }
}
