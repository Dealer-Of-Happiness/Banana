//
//  AIGoodbyeScreenshotTour.swift
//  AIGoodbyeUITests
//
//  Walks the app's screens and attaches a screenshot of each, in portrait
//  and landscape, so layouts can be reviewed for every window size the app
//  now runs in - a phone on its side, an iPad, the two displays of an
//  iPhone Duo. Run on a device of the size you want to look at:
//
//      xcodebuild test -only-testing:AIGoodbyeUITests/AIGoodbyeScreenshotTour \
//          -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)'
//
//  then `xcrun xcresulttool export attachments` on the result bundle.
//  Opt-in with AIG_SCREENSHOT_TOUR=1, so the regular suite stays fast.
//

import XCTest

final class AIGoodbyeScreenshotTour: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = true
        guard ProcessInfo.processInfo.environment["AIG_SCREENSHOT_TOUR"] == "1" else {
            throw XCTSkip("screenshot tour is opt-in")
        }
    }

    @MainActor
    func testTour() throws {
        let app = XCUIApplication()
        app.launchEnvironment["AIG_FORCE_NO_AI"] = "1"
        app.launch()

        addUIInterruptionMonitor(withDescription: "Permissions") { alert in
            for label in ["OK", "Allow", "Allow While Using App", "Don't Allow"] {
                let button = alert.buttons[label]
                if button.exists { button.tap(); return true }
            }
            return false
        }

        // First run: terms, then the setup sheet.
        let agree = app.buttons["Agree and Continue"]
        if agree.waitForExistence(timeout: 5) {
            snap(app, "00-terms-portrait")
            XCUIDevice.shared.orientation = .landscapeLeft
            sleep(1)
            snap(app, "00-terms-landscape")
            XCUIDevice.shared.orientation = .portrait
            sleep(1)
            agree.tap()
        }
        if app.navigationBars["Set Up"].waitForExistence(timeout: 5) {
            snap(app, "01-setup-portrait")
            XCUIDevice.shared.orientation = .landscapeLeft
            sleep(1)
            snap(app, "01-setup-landscape")
            XCUIDevice.shared.orientation = .portrait
            sleep(1)
            for label in ["Not now", "Done"] where app.buttons[label].firstMatch.exists {
                app.buttons[label].firstMatch.tap()
                break
            }
            _ = app.navigationBars["Set Up"].waitForNonExistence(timeout: 5)
        }

        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            sleep(1)
            let tag = orientation == .portrait ? "portrait" : "landscape"
            tour(app, tag: tag)
        }
        XCUIDevice.shared.orientation = .portrait
    }

    /// Each screen starts from a fresh launch, so no step depends on the
    /// one before it having left the drawer, a sheet or a cover in a known
    /// state - which is exactly what made the first version of this tour
    /// flaky.
    @MainActor
    private func fresh(_ app: XCUIApplication) {
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["Conversations menu"].waitForExistence(timeout: 10))
        sleep(1)
    }

    @MainActor
    private func openList(_ app: XCUIApplication) {
        let newChat = app.buttons["New Chat"].firstMatch
        if newChat.exists && newChat.isHittable { return }
        app.buttons["Conversations menu"].firstMatch.tap()
        _ = newChat.waitForExistence(timeout: 3)
        sleep(1)
    }

    @MainActor
    private func tour(_ app: XCUIApplication, tag: String) {
        fresh(app)
        snap(app, "10-chat-empty-\(tag)")

        // Conversation list: drawer or sidebar, whichever this width uses.
        openList(app)
        snap(app, "11-chat-list-\(tag)")

        // Settings and the model list.
        let settings = app.buttons["Settings"].firstMatch
        if settings.exists && settings.isHittable {
            settings.tap()
            if app.buttons["Manage Storage"].waitForExistence(timeout: 5) {
                snap(app, "12-settings-\(tag)")
                app.buttons["Manage Storage"].tap()
                sleep(1)
                snap(app, "13-models-\(tag)")
            }
        }

        // Recordings and the recorder.
        fresh(app)
        openList(app)
        let recordings = app.buttons["Recordings"].firstMatch
        if recordings.exists && recordings.isHittable {
            recordings.tap()
            sleep(1)
            snap(app, "14-recordings-\(tag)")
            let newRecording = app.buttons["New recording"].firstMatch
            if newRecording.waitForExistence(timeout: 3) {
                newRecording.tap()
                sleep(1)
                snap(app, "15-recorder-\(tag)")
            }
        }

        // Voice mode.
        fresh(app)
        let voiceButton = app.buttons["Start a voice conversation"]
        if voiceButton.waitForExistence(timeout: 5) {
            voiceButton.tap()
            let close = app.buttons["Close voice mode"]
            for _ in 0..<8 where !close.exists {
                app.swipeUp()
                usleep(600_000)
            }
            sleep(2)
            snap(app, "16-voice-\(tag)")
        }

        // Translate, via the tools menu.
        fresh(app)
        let tools = app.buttons["Tools and attachments"].firstMatch
        if tools.waitForExistence(timeout: 5) {
            tools.tap()
            let translate = app.buttons["Translate"].firstMatch
            if translate.waitForExistence(timeout: 3) {
                translate.tap()
                sleep(2)
                snap(app, "17-translate-\(tag)")
            }
        }

        // Model picker from the toolbar (or the chat options menu).
        fresh(app)
        var chooseModel = app.buttons["Choose Model"].firstMatch
        if !(chooseModel.exists && chooseModel.isHittable) {
            let options = app.buttons["Chat options"].firstMatch
            if options.exists && options.isHittable {
                options.tap()
                chooseModel = app.buttons["Choose Model"].firstMatch
            }
        }
        if chooseModel.waitForExistence(timeout: 3) && chooseModel.isHittable {
            chooseModel.tap()
            sleep(1)
            snap(app, "18-model-picker-\(tag)")
        }

        // The consent sheet: send a message with no model installed.
        fresh(app)
        let field = app.textFields.firstMatch
        if field.waitForExistence(timeout: 5) {
            field.tap()
            field.typeText("Hello")
            if app.buttons["Send message"].waitForExistence(timeout: 3) {
                app.buttons["Send message"].tap()
                if app.buttons["Download"].waitForExistence(timeout: 5) {
                    sleep(1)
                    snap(app, "19-consent-\(tag)")
                }
            }
        }
    }

    @MainActor
    private func snap(_ app: XCUIApplication, _ name: String) {
        // The app's own windows, not `XCUIScreen.main`: on an iPhone Duo
        // the main screen is the outer display, which is dark while the
        // device is open, so a screen capture there is a black rectangle.
        let shot = app.windows.firstMatch.exists
            ? app.windows.firstMatch.screenshot()
            : app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
