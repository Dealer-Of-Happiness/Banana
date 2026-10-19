//
//  AIGoodbyeFeedbackTests.swift
//  AIGoodbyeUITests
//
//  Send Feedback must always lead somewhere: Mail's compose sheet where Mail
//  is set up, another mail app through mailto:, or - as on the Simulator,
//  which has no mail app - the address to copy.
//

import XCTest

final class AIGoodbyeFeedbackTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSendFeedbackFromSettingsAlwaysLeadsSomewhere() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-hasAcceptedTerms", "YES", "-hasSeenSetup", "YES"]
        app.launch()

        let menu = app.buttons["Conversations menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.tap()
        XCTAssertTrue(app.buttons["Send Feedback"].waitForExistence(timeout: 5), "Send Feedback is in the side menu")

        let settings = app.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()

        let feedback = app.buttons["Send Feedback"].firstMatch
        XCTAssertTrue(feedback.waitForExistence(timeout: 5), "Send Feedback is in Settings")
        feedback.tap()

        // No mail app on the Simulator: the address to copy instead.
        let copy = app.alerts.buttons["Copy Address"]
        let composer = app.navigationBars.matching(identifier: "AiGoodbye feedback").firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 5) || composer.exists,
                      "Send Feedback must open Mail or offer the address")
        if copy.exists {
            XCTAssertTrue(app.alerts.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "marketing@dealerofhappiness.com")).firstMatch.exists,
                          "The alert shows the address")
            copy.tap()
        }
    }
}
