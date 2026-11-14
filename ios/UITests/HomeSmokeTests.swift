import XCTest

/// PixelClip's smoke walk: Home → Send (the photo picker, cancelled) → Write → Playlist → Settings →
/// back to Home, checking each screen shows up and the app stays up.
final class HomeSmokeTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testHomeToEveryVerbAndBack() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-PixelClipDemo"]
        app.launch()

        let send = app.buttons["tileSend"]
        XCTAssertTrue(send.waitForExistence(timeout: 20), "Home is up")

        // Send: the system photo picker opens; cancel it.
        send.tap()
        let cancel = app.buttons["Cancel"]
        if cancel.waitForExistence(timeout: 10) {
            cancel.tap()
        } else {
            app.swipeDown(velocity: .fast)
        }
        XCTAssertTrue(app.buttons["tileWrite"].waitForExistence(timeout: 10), "back on Home after cancelling the picker")
        XCTAssertEqual(app.state, .runningForeground)

        // Write.
        app.buttons["tileWrite"].tap()
        let message = app.descendants(matching: .any)["writeMessage"]
        XCTAssertTrue(message.waitForExistence(timeout: 10), "Write's text box")
        XCTAssertTrue(app.buttons["sendToClip"].exists, "Write's Send button")
        back(app)

        // Playlist.
        XCTAssertTrue(app.buttons["tilePlaylist"].waitForExistence(timeout: 10))
        app.buttons["tilePlaylist"].tap()
        XCTAssertTrue(app.buttons["addSomething"].waitForExistence(timeout: 10), "Playlist's Add something")
        back(app)

        // Settings.
        XCTAssertTrue(app.buttons["settingsButton"].waitForExistence(timeout: 10))
        app.buttons["settingsButton"].tap()
        XCTAssertTrue(app.buttons["advancedRow"].waitForExistence(timeout: 10), "Settings ▸ Advanced")
        back(app)

        XCTAssertTrue(send.waitForExistence(timeout: 10), "back on Home")
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// §5b.1 Write ▸ Bounce around: the switch, the 12-word cap ("12 of 12 words"), Send → Now shows the words; then
    /// the same to the playlist ("Added to the playlist"). The switch is turned back off at the end.
    @MainActor
    func testWriteBouncingWordsToNowAndToThePlaylist() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-PixelClipDemo"]
        app.launch()
        XCTAssertTrue(app.buttons["tileWrite"].waitForExistence(timeout: 20), "Home is up")
        app.buttons["tileWrite"].tap()
        let toggle = app.switches["writeBounce"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "the Bounce around switch")
        setSwitch(toggle, on: true)
        let message = app.descendants(matching: .any)["writeMessage"]
        message.tap()
        message.typeText(" un deux trois quatre cinq six sept huit neuf dix")
        let count = app.staticTexts["writeWordCount"]
        XCTAssertTrue(count.waitForExistence(timeout: 5), "the word count near the limit")
        XCTAssertEqual(count.label, "12 of 12 words", "typing stops at 12 words")
        if app.buttons["Done"].exists { app.buttons["Done"].tap() }
        app.buttons["sendToClip"].tap()
        let now = app.staticTexts["nowLine"]
        XCTAssertTrue(now.waitForExistence(timeout: 20), "back on Home")
        // (The typed words land wherever the cursor was; the name is the text's start, which has "deux" in it either way.)
        let sent = NSPredicate(format: "label CONTAINS %@", "deux")
        expectation(for: sent, evaluatedWith: now)
        waitForExpectations(timeout: 20)

        // The same words to the playlist instead.
        app.buttons["tileWrite"].tap()
        XCTAssertTrue(app.buttons["addToPlaylistInstead"].waitForExistence(timeout: 10))
        app.buttons["addToPlaylistInstead"].tap()
        XCTAssertTrue(app.staticTexts["Added to the playlist"].waitForExistence(timeout: 20), "the capsule says so")

        // Leave the switch off for the other tests.
        app.buttons["tileWrite"].tap()
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        setSwitch(toggle, on: false)
        XCTAssertEqual(app.state, .runningForeground)
    }

    private func setSwitch(_ s: XCUIElement, on: Bool) {
        if (s.value as? String == "1") != on {
            s.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        }
        XCTAssertEqual(s.value as? String, on ? "1" : "0")
    }

    /// An Extra sends in the background: "Sent" with Undo, then Undo puts back what was there.
    @MainActor
    func testSendFromAnExtraThenUndo() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-PixelClipDemo"]
        app.launch()
        let scenes = app.buttons["extra.scenes"]
        XCTAssertTrue(scenes.waitForExistence(timeout: 20), "Home is up")
        // Snow first, then Fire, so Fire is a change whatever the clip showed before (Undo needs something to put back).
        for scene in ["snow", "fire"] {
            XCTAssertTrue(scenes.waitForExistence(timeout: 20))
            scenes.tap()
            XCTAssertTrue(app.buttons["scene.\(scene)"].waitForExistence(timeout: 10), "the Scenes sheet")
            app.buttons["scene.\(scene)"].tap()
            app.buttons["sendToClip"].tap()
            XCTAssertTrue(app.staticTexts["Sent"].waitForExistence(timeout: 30), "\(scene) sent")
        }
        let undo = app.buttons["sendStatusUndo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 20), "Undo in the send-status capsule")
        XCTAssertTrue(app.staticTexts["Sent"].exists, "the capsule says Sent")
        undo.tap()
        XCTAssertTrue(app.buttons["homeUndo"].waitForNonExistence(timeout: 20), "nothing left to undo")
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// The navigation bar's back button.
    @MainActor private func back(_ app: XCUIApplication) {
        let button = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()
    }
}
