//
//  AIGoodbyeStoreShots.swift
//  AIGoodbyeUITests
//
//  Captures the raw screens behind the App Store screenshots, with the
//  sample content from DemoContent (AIG_DEMO=1) instead of placeholder
//  data. Each shot is its own launch so nothing depends on the step before.
//  Opt-in with AIG_STORE_SHOTS=1; run on the device whose screenshots you
//  need (an iPhone Duo in the open pose for the inner display) and export
//  the attachments from the result bundle at full size.
//

import XCTest

final class AIGoodbyeStoreShots: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = true
        guard ProcessInfo.processInfo.environment["AIG_STORE_SHOTS"] == "1" else {
            throw XCTSkip("store shots are opt-in")
        }
    }

    private let sunday = "D0000000-0000-4000-8000-000000000001"
    private let japanese = "D0000000-0000-4000-8000-000000000002"
    private let lease = "D0000000-0000-4000-8000-000000000003"

    @MainActor
    func testStoreShots() throws {
        // 1. The hero: sidebar beside a rich chat.
        var app = launch(conversation: sunday)
        showStart(app)
        snap(app, "01-sunday")

        // 2. Any language in, same language out.
        app = launch(conversation: japanese)
        showStart(app)
        snap(app, "02-japanese")

        // 3. A finished voice turn.
        app = launch(conversation: sunday, extraEnvironment: ["AIG_DEMO_VOICE": "1"])
        let voiceButton = app.buttons["Start a voice conversation"]
        if voiceButton.waitForExistence(timeout: 5) {
            voiceButton.tap()
            _ = app.buttons["Close voice mode"].waitForExistence(timeout: 5)
            sleep(2)
            snap(app, "03-voice")
        }

        // 4. A recording with its on-device summary.
        app = launch(conversation: sunday)
        // A Label inside a NavigationLink: a static text, not a button.
        let recordings = app.staticTexts["Recordings"].firstMatch
        if recordings.waitForExistence(timeout: 5) {
            recordings.tap()
            let row = app.staticTexts["Product sync - Thursday"].firstMatch
            if row.waitForExistence(timeout: 5) {
                row.tap()
                _ = app.staticTexts["Summary"].firstMatch.waitForExistence(timeout: 5)
                sleep(1)
                snap(app, "04-recording")
            }
        }

        // 5. A document question.
        app = launch(conversation: lease)
        showStart(app)
        snap(app, "05-lease")

        // 6. The model picker.
        app = launch(conversation: sunday)
        let chooseModel = app.buttons["Choose Model"].firstMatch
        if chooseModel.waitForExistence(timeout: 5) {
            chooseModel.tap()
            sleep(2)
            snap(app, "06-models")
        }
    }

    /// Just the model picker, for refreshing that one store screenshot when
    /// the catalog changes without re-shooting the rest.
    @MainActor
    func testModelPickerShot() throws {
        // The Simulator has the Mac's memory; shoot the picker as a 12 GB
        // iPhone sees it (about 6.3 GB for the app) unless told otherwise.
        let limit = ProcessInfo.processInfo.environment["AIG_MEMORY_LIMIT_GB"] ?? "6.3"
        let app = launch(conversation: sunday, extraEnvironment: ["AIG_MEMORY_LIMIT_GB": limit])
        var chooseModel = app.buttons["Choose Model"].firstMatch
        // On a phone it lives in the chat options menu.
        if !(chooseModel.exists && chooseModel.isHittable) {
            let options = app.buttons["Chat options"].firstMatch
            if options.waitForExistence(timeout: 5) {
                options.tap()
                sleep(1)
                chooseModel = app.buttons["Choose Model"].firstMatch
            }
        }
        XCTAssertTrue(chooseModel.waitForExistence(timeout: 5))
        chooseModel.tap()
        sleep(2)
        snap(app, "06-models")
        // The rest of the list, to check which models are offered.
        for page in 1...3 {
            app.swipeUp()
            sleep(1)
            snap(app, "06-models-more-\(page)")
        }
    }

    @MainActor
    private func launch(conversation: String, extraEnvironment: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["AIG_DEMO"] = "1"
        app.launchEnvironment["AIG_DEMO_TOP"] = "1"
        for (key, value) in extraEnvironment { app.launchEnvironment[key] = value }
        app.launchArguments += [
            "-hasAcceptedTerms", "YES",
            "-hasSeenSetup", "YES",
            "-showSidebar", "YES",
            "-lastConversationId", conversation,
        ]
        app.launch()
        XCTAssertTrue(app.buttons["Conversations menu"].waitForExistence(timeout: 10))
        sleep(2)
        return app
    }

    /// Chats open at the newest message; the shot wants the question at the
    /// top. Swiping is unreliable on the iPhone Duo runner (its coordinate
    /// space is a quarter turn from the inner display), so the app is asked
    /// to open at the top instead - see AIG_DEMO_TOP in ChatView.
    @MainActor
    private func showStart(_ app: XCUIApplication) {
        sleep(1)
    }

    @MainActor
    private func snap(_ app: XCUIApplication, _ name: String) {
        // The app's own window, not XCUIScreen.main: on an iPhone Duo the
        // main screen is the dark outer display while the phone is open.
        let shot = app.windows.firstMatch.exists
            ? app.windows.firstMatch.screenshot()
            : app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
