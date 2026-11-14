import XCTest
@testable import PixelClipKit

/// Counts probes and answers from a script.
final class ProbeScript: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [Bool]
    private(set) var calls = 0
    init(_ answers: [Bool]) { self.answers = answers }
    func next() -> Bool {
        lock.lock(); defer { lock.unlock() }
        calls += 1
        return answers.isEmpty ? false : answers.removeFirst()
    }
}

@MainActor
final class HotspotJoinerTests: XCTestCase {

    func joiner(_ script: ProbeScript, error: HotspotJoinError? = nil) -> HotspotJoiner {
        HotspotJoiner(configurator: ImmediateHotspotConfigurator(error: error), probeAttempts: 3,
                      probeInterval: .milliseconds(1), probe: { script.next() })
    }

    func testJoinThenReachable() async {
        let script = ProbeScript([false, false, true])   // not on it yet, DHCP pending, then up
        let j = joiner(script)
        XCTAssertEqual(j.state, .notJoined)
        let s = await j.connect()
        XCTAssertEqual(s, .joined)
        XCTAssertEqual(script.calls, 3)
    }

    func testAlreadyOnNetworkSkipsJoin() async {
        let j = joiner(ProbeScript([true]), error: .unavailable("should not be called"))
        let s = await j.connect()
        XCTAssertEqual(s, .joined)
    }

    func testJoinedButClipSilentIsUnreachable() async {
        let j = joiner(ProbeScript([]))
        let s = await j.connect()
        guard case .unreachable = s else { return XCTFail("\(s)") }
    }

    func testUserDeniedReturnsToNotJoined() async {
        let j = joiner(ProbeScript([]), error: .userDenied)
        let s = await j.connect()
        XCTAssertEqual(s, .notJoined)
        XCTAssertNotNil(j.message)
    }

    func testNetworkMissingIsUnreachable() async {
        let j = joiner(ProbeScript([]), error: .unavailable("not found"))
        guard case .unreachable = await j.connect() else { return XCTFail() }
        j.markDisconnected()
        XCTAssertEqual(j.state, .notJoined)
    }

    func testRefreshDetectsLoss() async {
        let j = joiner(ProbeScript([true, false]))
        _ = await j.connect()
        let s = await j.refresh()
        guard case .unreachable = s else { return XCTFail("\(s)") }
    }

    func testDefaults() {
        XCTAssertEqual(HotspotDefaults.ssidPrefix, "PixelClip-")
        XCTAssertEqual(HotspotDefaults.password, "pixelclip-2026")
    }
}
