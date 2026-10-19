//
//  AIGoodbyeFeedbackTests.swift
//  AIGoodbyeUITests
//
//  Send Feedback must always lead somewhere: Mail's compose sheet where Mail
//  is set up, another mail app through mailto:, or - when nothing can take
//  the email - the address to copy.
//

import XCTest

final class AIGoodbyeFeedbackTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-hasAcceptedTerms", "YES", "-hasSeenSetup", "YES"]
        app.launch()
        return app
    }

    /// Mail's sheet, the address alert, or (Simulator) the system taking the
    /// mailto: link - the app leaves the foreground or SpringBoard asks.
    @MainActor
    private func assertFeedbackLeadsSomewhere(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let copy = app.alerts.buttons["Copy Address"]
        let composer = app.navigationBars["AiGoodbye feedback"]
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if copy.exists || composer.exists || app.state != .runningForeground || springboard.alerts.count > 0 {
                if copy.exists {
                    XCTAssertTrue(app.alerts.staticTexts.containing(
                        NSPredicate(format: "label CONTAINS %@", "marketing@dealerofhappiness.com")).firstMatch.exists,
                        "The alert shows the address", file: file, line: line)
                    copy.tap()
                }
                if springboard.alerts.count > 0 {
                    springboard.alerts.buttons.element(boundBy: springboard.alerts.buttons.count - 1).tap()
                }
                return
            }
            usleep(200_000)
        }
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTFail("Send Feedback must open Mail, another mail app, or offer the address", file: file, line: line)
    }

    @MainActor
    func testSendFeedbackFromTheSideMenu() throws {
        let app = launch()
        let menu = app.buttons["Conversations menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.tap()
        let feedback = app.buttons["Send Feedback"].firstMatch
        XCTAssertTrue(feedback.waitForExistence(timeout: 5), "Send Feedback is in the side menu")
        feedback.tap()
        assertFeedbackLeadsSomewhere(app)
    }

    @MainActor
    func testSendFeedbackFromSettings() throws {
        let app = launch()
        let menu = app.buttons["Conversations menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.tap()
        let settings = app.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        // The Settings form's own row, not the side menu's behind the sheet.
        let feedback = app.collectionViews.buttons["Send Feedback"].firstMatch
        XCTAssertTrue(feedback.waitForExistence(timeout: 5), "Send Feedback is in Settings")
        feedback.tap()
        assertFeedbackLeadsSomewhere(app)
    }
}
