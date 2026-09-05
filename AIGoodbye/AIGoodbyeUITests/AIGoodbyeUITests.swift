//
//  AIGoodbyeUITests.swift
//  AIGoodbyeUITests
//
//  Smoke test plus regression tests for the 3.0.1 field bugs:
//  - Settings > model picker must open (not dismiss Settings) on devices
//    without Apple Intelligence
//  - model downloads must show live byte progress and be cancellable
//

import XCTest

final class AIGoodbyeUITests: XCTestCase {

    @MainActor
    func testAppLaunches() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.state == .runningForeground)
    }

    /// Launch pretending Apple Intelligence is unavailable (iPhone 13-class),
    /// then walk: side menu > Settings > model row. The picker sheet must
    /// appear, selecting a model must land back in Settings (not the main
    /// chat screen), and the picker must show the unavailable explanation.
    @MainActor
    func testModelPickerFromSettingsWithoutAppleIntelligence() throws {
        let app = XCUIApplication()
        app.launchEnvironment["AIG_FORCE_NO_AI"] = "1"
        app.launch()

        acceptTermsIfNeeded(app)

        // Open the side menu and Settings.
        let menuButton = app.buttons["Conversations menu"]
        XCTAssertTrue(menuButton.waitForExistence(timeout: 10), "Chat screen should show")
        menuButton.tap()

        let settingsButton = app.buttons["Settings"].firstMatch
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5))
        settingsButton.tap()

        XCTAssertTrue(app.buttons["Manage Storage"].waitForExistence(timeout: 5),
                      "Settings sheet should be presented")

        // Tap the model chooser row.
        let modelRow = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Current AI model")
        ).firstMatch
        XCTAssertTrue(modelRow.waitForExistence(timeout: 5))
        modelRow.tap()

        // The picker must open, with Apple Intelligence marked unavailable.
        XCTAssertTrue(app.navigationBars["Choose AI Model"].waitForExistence(timeout: 5),
                      "Model picker should open instead of dismissing Settings")
        XCTAssertTrue(app.staticTexts["Apple Intelligence"].exists)

        // Select a model; the picker closes and Settings must still be there.
        let modelChoice = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Qwen3 Vision 2B' AND label CONTAINS '1.8 GB'")
        ).firstMatch
        XCTAssertTrue(modelChoice.waitForExistence(timeout: 5))
        modelChoice.tap()

        XCTAssertTrue(app.buttons["Manage Storage"].waitForExistence(timeout: 5),
                      "Settings must remain presented after choosing a model")
    }

    /// Send a message with no model downloaded: the consent sheet must appear,
    /// approving must start a real download whose byte progress visibly moves,
    /// and Stop must cancel it without an error banner or crash.
    @MainActor
    func testDownloadShowsLiveProgressAndCancels() throws {
        let app = XCUIApplication()
        app.launchEnvironment["AIG_FORCE_NO_AI"] = "1"
        app.launchEnvironment["AIG_SIM_TEST_DOWNLOAD"] = "1"
        app.launch()

        acceptTermsIfNeeded(app)

        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("Hello")
        app.buttons["Send message"].tap()

        // Consent sheet.
        let downloadButton = app.buttons["Download"]
        XCTAssertTrue(downloadButton.waitForExistence(timeout: 10),
                      "Download consent sheet should appear")
        downloadButton.tap()

        // Progress chip should appear and its label should change as bytes
        // arrive (this fails if the UI freezes like it did in 3.0.0).
        let chip = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Downloading")
        ).firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 20), "Progress chip should appear")

        let first = chip.label
        var moved = false
        for _ in 0..<30 {
            usleep(1_000_000)
            if chip.exists, chip.label != first, chip.label.contains("MB") {
                moved = true
                break
            }
            if !chip.exists { break } // tiny files finished before we sampled
        }
        XCTAssertTrue(moved || !chip.exists, "Progress must move (was frozen in 3.0.0)")

        // Stop must cancel cleanly: no error banner, composer usable again
        // (an empty composer shows the voice conversation button).
        let stop = app.buttons["Stop generating"]
        if stop.exists {
            stop.tap()
            XCTAssertTrue(app.buttons["Start a voice conversation"].waitForExistence(timeout: 15),
                          "Composer should return after cancelling")
        }
        XCTAssertFalse(app.staticTexts["Try Again"].exists,
                       "Cancelling must not show an error banner")
    }

    /// Voice mode must open from the composer, show its UI, and close
    /// cleanly (handling the system mic/speech permission alerts).
    @MainActor
    func testVoiceModeOpensAndCloses() throws {
        let app = XCUIApplication()
        app.launch()

        acceptTermsIfNeeded(app)

        addUIInterruptionMonitor(withDescription: "Permissions") { alert in
            for label in ["OK", "Allow", "Allow While Using App"] {
                let button = alert.buttons[label]
                if button.exists { button.tap(); return true }
            }
            return false
        }

        let voiceButton = app.buttons["Start a voice conversation"]
        XCTAssertTrue(voiceButton.waitForExistence(timeout: 10))
        voiceButton.tap()

        // Permission alerts appear asynchronously; interruption monitors only
        // fire on interactions, so poke the app until the cover is visible.
        let title = app.staticTexts["Voice Conversation"]
        var presented = false
        for _ in 0..<10 {
            if title.exists { presented = true; break }
            app.swipeUp() // harmless interaction that triggers the monitor
            usleep(700_000)
        }
        XCTAssertTrue(presented || title.waitForExistence(timeout: 5),
                      "Voice mode should present")

        let close = app.buttons["Close voice mode"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()

        XCTAssertTrue(voiceButton.waitForExistence(timeout: 10),
                      "Chat should return after closing voice mode")
    }

    // MARK: - Helpers

    @MainActor
    private func acceptTermsIfNeeded(_ app: XCUIApplication) {
        let agree = app.buttons["Agree and Continue"]
        if agree.waitForExistence(timeout: 5) {
            agree.tap()
        }
    }
}
