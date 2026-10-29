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

        // Open the conversation list (a drawer on a phone, a sidebar that
        // may already be showing on a wide window) and Settings.
        let menuButton = app.buttons["Conversations menu"]
        XCTAssertTrue(menuButton.waitForExistence(timeout: 10), "Chat screen should show")
        let settingsButton = app.buttons["Settings"].firstMatch
        if !(settingsButton.exists && settingsButton.isHittable) {
            menuButton.tap()
        }
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
        // The chip as VoiceOver reads it: one element whose label carries
        // the model's name and the figures (its texts are separate lines).
        let chip = app.otherElements.matching(
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
        XCTAssertTrue(moved || !chip.exists,
                      "Progress must move (was frozen in 3.0.0); chip reads \"\(chip.exists ? chip.label : "")\"")

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
        allowPermissionAlerts()

        let close = app.buttons["Close voice mode"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()

        XCTAssertTrue(voiceButton.waitForExistence(timeout: 10),
                      "Chat should return after closing voice mode")
    }

    /// The app now rotates on iPhone (it has to: an iPhone Duo is held and
    /// stood up in every orientation). Every control a user needs must stay
    /// on screen in a short, wide window: the chat's composer and menu, and
    /// voice mode's only button, which the old stacked layout pushed off the
    /// bottom of a landscape phone.
    @MainActor
    func testLandscapeKeepsControlsOnScreen() throws {
        let app = XCUIApplication()
        app.launchEnvironment["AIG_FORCE_NO_AI"] = "1"
        app.launch()
        acceptTermsIfNeeded(app)

        addUIInterruptionMonitor(withDescription: "Permissions") { alert in
            for label in ["OK", "Allow", "Allow While Using App"] {
                let button = alert.buttons[label]
                if button.exists { button.tap(); return true }
            }
            return false
        }

        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }

        let menuButton = app.buttons["Conversations menu"]
        XCTAssertTrue(menuButton.waitForExistence(timeout: 10), "Chat toolbar should show in landscape")
        XCTAssertTrue(menuButton.isHittable, "Menu button must be tappable in landscape")

        let voiceButton = app.buttons["Start a voice conversation"]
        XCTAssertTrue(voiceButton.waitForExistence(timeout: 5))
        XCTAssertTrue(voiceButton.isHittable, "Composer must be on screen in landscape")

        // The list still opens in a landscape window: a drawer on a phone,
        // a sidebar on a wide one (where it may already be showing).
        let settings = app.buttons["Settings"].firstMatch
        if !(settings.exists && settings.isHittable) {
            menuButton.tap()
        }
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "List should open in landscape")
        // A landscape phone is too short for a pinned header and Settings
        // row plus a usable chat list, so the whole menu scrolls as one
        // (see SideMenuView.scrollsAsOne): Settings is at its end.
        // Up to ten swipes: earlier tests in the same run leave many chats.
        // Something in the menu to swipe on: a button by name, or a chat row
        // (their labels are "title, preview, time").
        func menuHandle(_ names: [String]) -> XCUIElement? {
            names.map { app.buttons[$0].firstMatch }.first { $0.exists && $0.isHittable }
                ?? app.buttons.matching(NSPredicate(format: "label CONTAINS ','")).allElementsBoundByIndex
                    .first { $0.isHittable }
        }
        for _ in 0..<10 where !settings.isHittable {
            guard let handle = menuHandle(["New Chat", "New Folder", "Recordings", "Send Feedback"]) else { break }
            handle.swipeUp()
            usleep(500_000)
        }
        XCTAssertTrue(settings.isHittable, "Settings must be reachable in landscape")
        let closeMenu = app.buttons["Close menu"].firstMatch
        for _ in 0..<10 where closeMenu.exists && !closeMenu.isHittable {
            guard let handle = menuHandle(["Settings", "Send Feedback"]) else { break }
            handle.swipeDown()
            usleep(500_000)
        }
        if closeMenu.exists && closeMenu.isHittable {
            closeMenu.tap()
        }

        // Voice mode: its one control must be reachable.
        XCTAssertTrue(voiceButton.waitForExistence(timeout: 5))
        voiceButton.tap()
        let talk = app.buttons["Tap to talk"]
        var presented = false
        for _ in 0..<10 {
            if talk.exists { presented = true; break }
            app.swipeUp()
            usleep(700_000)
        }
        XCTAssertTrue(presented || talk.waitForExistence(timeout: 5), "Voice mode should present in landscape")
        allowPermissionAlerts()
        XCTAssertTrue(talk.isHittable, "Tap to talk must be on screen in landscape")

        let close = app.buttons["Close voice mode"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        XCTAssertTrue(close.isHittable, "Close must be on screen in landscape")
        close.tap()
        XCTAssertTrue(voiceButton.waitForExistence(timeout: 10))
    }

    // MARK: - Helpers

    /// System permission alerts (microphone, speech) belong to SpringBoard,
    /// not the app, and an interruption monitor only fires on interactions -
    /// `isHittable` is not one. Dismiss them explicitly before asserting.
    @MainActor
    private func allowPermissionAlerts() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<3 {
            let alert = springboard.alerts.firstMatch
            guard alert.waitForExistence(timeout: 2) else { return }
            for label in ["Allow While Using App", "Allow", "OK"] {
                let button = alert.buttons[label]
                if button.exists { button.tap(); break }
            }
            usleep(500_000)
        }
    }

    @MainActor
    private func acceptTermsIfNeeded(_ app: XCUIApplication) {
        let agree = app.buttons["Agree and Continue"]
        if agree.waitForExistence(timeout: 5) {
            agree.tap()
        }
        dismissSetupIfNeeded(app)
    }

    /// The first-run setup sheet covers the whole screen on a fresh install,
    /// so every test that touches the chat has to get past it first.
    ///
    /// `hasSeenSetup` is `@AppStorage`, so this only fires for whichever test
    /// happens to run first against a fresh container - which is exactly the
    /// kind of order dependence that makes a suite flaky, so it is checked
    /// unconditionally rather than in one place.
    @MainActor
    private func dismissSetupIfNeeded(_ app: XCUIApplication) {
        guard app.navigationBars["Set Up"].waitForExistence(timeout: 5) else { return }
        for label in ["Not now", "Done"] {
            let button = app.buttons[label].firstMatch
            if button.exists {
                button.tap()
                break
            }
        }
        // The sheet dismissal is animated; the next tap must not land on it.
        XCTAssertTrue(
            app.navigationBars["Set Up"].waitForNonExistence(timeout: 5),
            "Setup sheet should close"
        )
    }
}
