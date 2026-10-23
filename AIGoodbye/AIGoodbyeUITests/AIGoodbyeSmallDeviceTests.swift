//
//  AIGoodbyeSmallDeviceTests.swift
//  AIGoodbyeUITests
//
//  What a 4 GB iPhone sees (an iPhone SE, say): the 8-bit Qwen3.5 0.8B
//  recommended, the 4-bit Lite one beside it, the larger models marked too
//  large, and an honest note where a chat with a small model begins.
//  AIG_MEMORY_LIMIT_GB (debug builds only) stands in for the memory iOS
//  gives the app on such a phone.
//

import XCTest

final class AIGoodbyeSmallDeviceTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func launch(selected modelId: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["AIG_MEMORY_LIMIT_GB"] = "2.5"
        app.launchEnvironment["AIG_FORCE_NO_AI"] = "1"
        app.launchArguments += [
            "-hasAcceptedTerms", "YES",
            "-hasSeenSetup", "YES",
            "-selectedModelId", modelId,
        ]
        app.launch()
        XCTAssertTrue(app.buttons["Conversations menu"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    func testSmallModelChatSaysFactsCanBeWrong() {
        let app = launch(selected: "qwen3.5-0.8b-8bit")
        let note = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'often get facts wrong'")).firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 5), "no note about facts on the empty chat")
        XCTAssertTrue(note.label.contains("Qwen3.5 Vision 0.8B"))
        add(snap(app, "small-chat-note"))
    }

    @MainActor
    func testLargerModelChatHasNoNote() {
        let app = launch(selected: "qwen3-vl-2b")
        let note = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'often get facts wrong'")).firstMatch
        XCTAssertFalse(note.waitForExistence(timeout: 3))
    }

    @MainActor
    func testPickerRecommendsTheAccurateSmallModel() {
        let app = launch(selected: "qwen3.5-0.8b-8bit")
        var chooseModel = app.buttons["Choose Model"].firstMatch
        if !(chooseModel.exists && chooseModel.isHittable) {
            let options = app.buttons["Chat options"].firstMatch
            XCTAssertTrue(options.waitForExistence(timeout: 5))
            options.tap()
            chooseModel = app.buttons["Choose Model"].firstMatch
        }
        XCTAssertTrue(chooseModel.waitForExistence(timeout: 5))
        chooseModel.tap()

        // The row's accessibility label carries the name and "Recommended".
        let recommended = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'Qwen3.5 Vision 0.8B,' AND label CONTAINS 'Recommended'")).firstMatch
        XCTAssertTrue(recommended.waitForExistence(timeout: 5), "the 8-bit 0.8B is not the recommended model")
        let lite = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'Qwen3.5 Vision 0.8B Lite'")).firstMatch
        XCTAssertTrue(lite.exists, "the Lite version is missing")
        add(snap(app, "small-picker"))
    }

    @MainActor
    private func snap(_ app: XCUIApplication, _ name: String) -> XCTAttachment {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        return attachment
    }
}
