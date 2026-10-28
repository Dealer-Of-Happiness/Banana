//
//  AIGoodbyeLargeTextLayoutTests.swift
//  AIGoodbyeUITests
//
//  An iPhone SE with Larger Text, as a tester uses it: the chat title bar
//  must not sit on top of an answer's text, and a Recent Chats row must be
//  a comfortable tap target. Run on a small iPhone at a large text size;
//  the screenshots are kept for review.
//

import XCTest

final class AIGoodbyeLargeTextLayoutTests: XCTestCase {

    /// The sample conversations' ids (DemoContent.swift, debug builds only).
    private let lisbonChat = "D0000000-0000-4000-8000-000000000004"
    /// "Conversations menu" in German.
    private let menuButton = "Unterhaltungsmenü"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func launch(chat: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["AIG_DEMO"] = "1"
        app.launchEnvironment["AIG_FORCE_NO_AI"] = "1"
        app.launchArguments += [
            "-hasAcceptedTerms", "YES",
            "-hasSeenSetup", "YES",
            "-selectedModelId", "qwen3.5-0.8b-8bit",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXXXL",
            // In German, as tested: its long words are what wrap first.
            "-AppleLanguages", "(de)",
            "-AppleLocale", "de_DE",
        ]
        if let chat { app.launchArguments += ["-lastConversationId", chat] }
        app.launch()
        XCTAssertTrue(app.buttons[menuButton].waitForExistence(timeout: 10))
        return app
    }

    /// The last lines of a long answer, opened at the bottom: the first
    /// visible lines are the ones that used to show through the title bar.
    @MainActor
    func testLongAnswerUnderTitleBar() {
        let app = launch(chat: lisbonChat)
        sleep(1)
        add(snap(app, "long-answer-bottom"))
        app.swipeDown(velocity: .slow)
        sleep(1)
        add(snap(app, "long-answer-scrolled"))
    }

    /// The first question to a model that is not downloaded yet: the chip
    /// must say it is downloading (not "Lade", which reads as "loading"),
    /// and nothing may sit on top of the question or the composer.
    /// AIG_SIM_TEST_DOWNLOAD makes the Simulator fetch the model for real.
    @MainActor
    func testFirstQuestionWhileTheModelDownloads() throws {
        let app = XCUIApplication()
        app.launchEnvironment["AIG_SIM_TEST_DOWNLOAD"] = "1"
        app.launchEnvironment["AIG_FORCE_NO_AI"] = "1"
        app.launchArguments += [
            "-hasAcceptedTerms", "YES",
            "-hasSeenSetup", "YES",
            "-selectedModelId", "qwen3.5-0.8b-8bit",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXXXL",
            "-AppleLanguages", "(de)",
            "-AppleLocale", "de_DE",
        ]
        app.launch()
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("Wie spät ist es?")
        app.buttons["Nachricht senden"].tap()
        let download = app.buttons.matching(NSPredicate(format: "label IN {'Herunterladen', 'Laden'}")).firstMatch
        if download.waitForExistence(timeout: 5) {
            add(snap(app, "consent"))
            download.tap()
        }
        let chip = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'wird heruntergeladen'")).firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 20), "no 'wird heruntergeladen' chip")
        sleep(4)
        add(snap(app, "downloading"))
        // Keyboard down, as when the user just watches.
        app.swipeDown(velocity: .slow)
        sleep(2)
        add(snap(app, "downloading-keyboard-down"))
    }

    /// Recent Chats rows: tall enough to hit reliably with a thumb.
    @MainActor
    func testRecentChatRowsAreComfortableTargets() {
        let app = launch()
        app.buttons[menuButton].tap()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Lisbon'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "no Lisbon row in Recent Chats")
        add(snap(app, "recent-chats"))
        XCTAssertGreaterThanOrEqual(row.frame.height, 60, "a Recent Chats row is only \(row.frame.height) pt tall")
    }

    /// The translator at an accessibility text size, as the tester uses it:
    /// each language's name stays on one line. The menus used to break
    /// them in the middle of the word ("Deuts" / "ch", "Englis" / "h").
    @MainActor
    func testTranslateLanguageNamesStayWhole() {
        let app = XCUIApplication()
        app.launchEnvironment["AIG_DEMO"] = "1"
        app.launchEnvironment["AIG_FORCE_NO_AI"] = "1"
        app.launchEnvironment["AIG_ROUTE"] = "translate"
        app.launchArguments += [
            "-hasAcceptedTerms", "YES",
            "-hasSeenSetup", "YES",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityM",
            "-AppleLanguages", "(de)",
            "-AppleLocale", "de_DE",
        ]
        app.launch()
        let mine = app.buttons["Du"]
        let theirs = app.buttons["Gegenüber"]
        XCTAssertTrue(mine.waitForExistence(timeout: 15), "no language menu for your side")
        XCTAssertTrue(theirs.exists, "no language menu for the other side")
        add(snap(app, "translate-languages"))
        // One line at this size is under 50 pt; a name broken over two
        // lines made the menu about 70 pt tall.
        XCTAssertLessThan(mine.frame.height, 60, "your language's name wraps (\(mine.frame.height) pt)")
        XCTAssertLessThan(theirs.frame.height, 60, "their language's name wraps (\(theirs.frame.height) pt)")
        XCTAssertTrue(app.buttons["Freihändiges Gespräch"].isHittable, "hands-free button not reachable")
    }
}

private extension XCTestCase {
    @MainActor
    func snap(_ app: XCUIApplication, _ name: String) -> XCTAttachment {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        return attachment
    }
}
