//
//  AIGoodbyeEndToEndTests.swift
//  AIGoodbyeUITests
//
//  End-to-end journeys through the app the way a person uses it: send and
//  get an answer, stop one, regenerate, clear, switch models, personalize,
//  remember, search, file into folders, export, record, translate, change
//  the language, lock. Everything asserts an outcome, not just that a
//  screen opened.
//
//  Runs against the Simulator's echo engine (AIG_FORCE_NO_AI=1), so the
//  model-dependent parts exercise the full pipeline - consent, session,
//  streaming, persistence - with a canned answer.
//

import XCTest

final class AIGoodbyeEndToEndTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Helpers

    @MainActor
    private func launch(fresh: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["AIG_FORCE_NO_AI"] = "1"
        app.launchEnvironment["AIG_SIM_SLOW_ECHO"] = "1"
        app.launch()
        addUIInterruptionMonitor(withDescription: "Permissions") { alert in
            for label in ["OK", "Allow", "Allow While Using App", "Don't Allow"] {
                let button = alert.buttons[label]
                if button.exists { button.tap(); return true }
            }
            return false
        }
        acceptTermsIfNeeded(app)
        XCTAssertTrue(app.buttons["Conversations menu"].waitForExistence(timeout: 10))
        // Every test starts in a chat of its own: the app restores the last
        // conversation, and a document attached by an earlier test changes
        // how the echo engine quotes the prompt.
        startNewChat(app)
        return app
    }

    @MainActor
    private func startNewChat(_ app: XCUIApplication) {
        openList(app)
        app.buttons["New Chat"].firstMatch.tap()
        sleep(1)
        closeListIfDrawer(app)
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor
    private func acceptTermsIfNeeded(_ app: XCUIApplication) {
        let agree = app.buttons["Agree and Continue"]
        if agree.waitForExistence(timeout: 4) { agree.tap() }
        if app.navigationBars["Set Up"].waitForExistence(timeout: 4) {
            for label in ["Not now", "Done"] where app.buttons[label].firstMatch.exists {
                app.buttons[label].firstMatch.tap()
                break
            }
            _ = app.navigationBars["Set Up"].waitForNonExistence(timeout: 5)
        }
    }

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

    /// Open the conversation list. "Hittable" is not enough to know the
    /// drawer is open: XCUITest reports the parked drawer's buttons as
    /// hittable at negative x. Check the frame.
    @MainActor
    private func listIsOpen(_ app: XCUIApplication) -> Bool {
        let newChat = app.buttons["New Chat"].firstMatch
        return newChat.exists && newChat.frame.minX >= 0
    }

    @MainActor
    private func openList(_ app: XCUIApplication) {
        if listIsOpen(app) { return }
        app.buttons["Conversations menu"].firstMatch.tap()
        let newChat = app.buttons["New Chat"].firstMatch
        XCTAssertTrue(newChat.waitForExistence(timeout: 5))
        sleep(1)
        XCTAssertTrue(listIsOpen(app), "The list should be open")
    }

    @MainActor
    private func closeListIfDrawer(_ app: XCUIApplication) {
        let close = app.buttons["Close menu"].firstMatch
        if close.exists && close.isHittable {
            close.tap()
            sleep(1)
        }
    }

    /// The chat row in the list that mentions `text`. The same text also
    /// sits in the chat behind the drawer (off-screen to the right), so
    /// only a hittable match counts.
    @MainActor
    private func listRow(_ app: XCUIApplication, containing text: String) -> XCUIElement? {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        let candidates = app.buttons.matching(predicate).allElementsBoundByIndex
            + app.staticTexts.matching(predicate).allElementsBoundByIndex
        return candidates.first { $0.exists && $0.isHittable && $0.frame.minX >= 0 && $0.frame.minX < 120 }
    }

    @MainActor
    private func goBack(_ app: XCUIApplication, from title: String) {
        let bar = app.navigationBars[title].firstMatch
        let back = bar.buttons.element(boundBy: 0)
        if bar.exists, back.exists {
            back.tap()
        } else {
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
    }

    /// A row in a Form/List: a NavigationLink made from a Label is not a
    /// button to XCUITest, so look for the text too.
    @MainActor
    private func row(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        func find() -> XCUIElement? {
            let button = app.buttons[name].firstMatch
            if button.exists { return button }
            let cell = app.cells.containing(.staticText, identifier: name).firstMatch
            if cell.exists { return cell }
            let text = app.staticTexts[name].firstMatch
            return text.exists ? text : nil
        }
        // Rows further down a Form only exist once scrolled into view.
        // Settings grew Speech and Siri sections, so allow a longer scroll.
        for _ in 0..<8 {
            if let found = find(), found.isHittable { return found }
            app.swipeUp()
            usleep(400_000)
        }
        return find() ?? app.staticTexts[name].firstMatch
    }

    @MainActor
    private func openSettings(_ app: XCUIApplication) {
        openList(app)
        let settings = app.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        XCTAssertTrue(app.buttons["Manage Storage"].waitForExistence(timeout: 5), "Settings should open")
    }

    @MainActor
    private func closeSettings(_ app: XCUIApplication) {
        let done = app.buttons["Done"].firstMatch
        if done.waitForExistence(timeout: 3) { done.tap() }
        _ = app.buttons["Manage Storage"].waitForNonExistence(timeout: 5)
        closeListIfDrawer(app)
    }

    /// Type and send, approving the one-time download consent the first
    /// time (the Simulator never downloads; the echo engine answers).
    @MainActor
    private func send(_ app: XCUIApplication, _ text: String) {
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(text)
        let sendButton = app.buttons["Send message"]
        XCTAssertTrue(sendButton.waitForExistence(timeout: 3))
        sendButton.tap()
        let download = app.buttons["Download"]
        if download.waitForExistence(timeout: 3) {
            download.tap()
        }
    }

    /// Send, wait for the generation to start and finish, and check that
    /// the answer to THIS prompt is on screen (the echo quotes it). Counting
    /// bubbles does not work: the transcript is lazy, so older ones leave
    /// the hierarchy as new ones arrive.
    @MainActor
    private func sendAndWait(_ app: XCUIApplication, _ text: String, timeout: TimeInterval = 40, expectQuote: Bool = true) {
        send(app, text)
        let stop = app.buttons["Stop generating"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10), "Generation should start")
        XCTAssertTrue(stop.waitForNonExistence(timeout: timeout), "Generation should finish")
        // With a document attached the prompt starts with the retrieved
        // passages, so the echo quotes those instead of the question.
        guard expectQuote else { return }
        let quoted = String(text.prefix(40))
        let answer = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", "Assistant said:", quoted)).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 5), "The answer should quote the question")
    }

    @MainActor
    private func waitForAnswer(_ app: XCUIApplication, timeout: TimeInterval = 40) {
        let reply = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Simulator test mode")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: timeout), "An answer should stream in")
        XCTAssertTrue(app.buttons["Stop generating"].waitForNonExistence(timeout: timeout), "Generation should finish")
    }

    // MARK: - Chat

    @MainActor
    func testSendAnswerStopRegenerateClearAndRelaunch() throws {
        let app = launch()

        sendAndWait(app, "What is the capital of France?")

        // The question and the answer are both on screen.
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "capital of France")).firstMatch.exists)

        // Stop mid-answer: the partial answer stays, nothing else appears.
        send(app, "Tell me a long story please")
        let stop = app.buttons["Stop generating"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10), "Stop should appear while streaming")
        stop.tap()
        XCTAssertTrue(stop.waitForNonExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["No answer was produced. Tap Try Again, or rephrase the question."].exists,
                       "A deliberate Stop must not show the no-answer banner")

        // Regenerate from the overflow menu.
        // iOS 27's system overflow menu, or the app's own menu on iOS 26.
        let options = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@ OR label == %@", "More", "Chat options", "Chat Options")).firstMatch
        XCTAssertTrue(options.waitForExistence(timeout: 5), "Overflow menu should exist")
        options.tap()
        let regenerate = app.buttons["Regenerate"].firstMatch
        XCTAssertTrue(regenerate.waitForExistence(timeout: 5))
        regenerate.tap()
        waitForAnswer(app)

        // Persisted across a relaunch, and opened at the newest message.
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["Conversations menu"].waitForExistence(timeout: 10))
        let reply = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Simulator test mode")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 10), "The conversation should be restored")
        XCTAssertTrue(app.textFields.firstMatch.isHittable, "Composer stays reachable after restore")

        // Clear chat: the transcript empties.
        options.tap()
        let clear = app.buttons["Clear Chat"].firstMatch
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        clear.tap()
        let confirm = app.alerts.buttons["Clear Chat"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        // Bubbles, not any text: the parked drawer still lists the chat
        // with its last reply as the preview.
        let bubble = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Assistant said:")).firstMatch
        XCTAssertTrue(bubble.waitForNonExistence(timeout: 10), "Messages should be gone")
        XCTAssertTrue(app.staticTexts["Start a Conversation"].waitForExistence(timeout: 5), "Empty state returns")
    }

    @MainActor
    func testModelPickerSelectsAndShowsInSubtitle() throws {
        let app = launch()
        let choose = app.buttons["Choose Model"].firstMatch
        XCTAssertTrue(choose.waitForExistence(timeout: 5))
        choose.tap()
        XCTAssertTrue(app.navigationBars["Choose AI Model"].waitForExistence(timeout: 5))
        // Pick the smallest model.
        let smol = app.staticTexts["Smol Vision 500M"].firstMatch
        XCTAssertTrue(smol.waitForExistence(timeout: 5))
        smol.tap()
        let done = app.buttons["Done"].firstMatch
        if done.exists { done.tap() }
        _ = app.navigationBars["Choose AI Model"].waitForNonExistence(timeout: 5)
        XCTAssertTrue(app.staticTexts["Smol Vision 500M"].firstMatch.waitForExistence(timeout: 5),
                      "The selected model is named in the chat's subtitle")
    }

    // MARK: - Personalization

    @MainActor
    func testMemoryCaptureShowsUpInSettings() throws {
        let app = launch()
        send(app, "Remember that I like green tea")
        let notice = app.staticTexts["Saved to memory: I like green tea"]
        XCTAssertTrue(notice.waitForExistence(timeout: 10), "The memory notice should confirm the fact")
        XCTAssertTrue(app.buttons["Stop generating"].waitForNonExistence(timeout: 40))

        openSettings(app)
        row(app, "Memory").tap()
        XCTAssertTrue(app.navigationBars["Memory"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["I like green tea"].waitForExistence(timeout: 5), "The fact is listed")

        // Forget it again.
        let fact = app.staticTexts["I like green tea"].firstMatch
        let start = fact.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
        let end = fact.coordinate(withNormalizedOffset: CGVector(dx: -2.0, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: end)
        let delete = app.buttons["Delete"].firstMatch
        if delete.waitForExistence(timeout: 3) { delete.tap() }
        XCTAssertTrue(app.staticTexts["I like green tea"].waitForNonExistence(timeout: 5), "The fact is forgotten")
        XCTAssertTrue(app.navigationBars["Memory"].exists, "Still on the Memory screen")
    }

    @MainActor
    func testPersonaCreateSelectDelete() throws {
        let app = launch()
        openSettings(app)
        row(app, "Personas").tap()
        XCTAssertTrue(app.navigationBars["Personas"].waitForExistence(timeout: 5))
        app.buttons["Create Persona"].firstMatch.tap()

        let name = app.textFields["Name"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Pirate")
        app.buttons["Save"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Pirate"].waitForExistence(timeout: 5), "The new persona is listed")

        // Select it.
        app.staticTexts["Pirate"].firstMatch.tap()
        sleep(1)

        // Delete it; built-ins cannot be deleted, custom ones can. A full
        // drag rather than `swipeLeft()`, which is too short for a List
        // row that is itself a button.
        let pirateRow = app.buttons["Pirate"].firstMatch
        XCTAssertTrue(pirateRow.waitForExistence(timeout: 5))
        // Start on the name, not on the trailing pencil button.
        let start = pirateRow.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5))
        let end = pirateRow.coordinate(withNormalizedOffset: CGVector(dx: -0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: end)
        let delete = app.buttons["Delete"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 3))
        delete.tap()
        XCTAssertTrue(app.buttons["Pirate"].firstMatch.waitForNonExistence(timeout: 5))
    }

    // MARK: - Organizing

    @MainActor
    func testSearchFindsConversationText() throws {
        let app = launch()
        sendAndWait(app, "The zebra crossing was painted purple")

        openList(app)
        app.buttons["Search chats"].firstMatch.tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("zebra")
        let hit = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "zebra")).firstMatch
        XCTAssertTrue(hit.waitForExistence(timeout: 10), "Search should find the message")
        field.typeText(" unicorn")
        XCTAssertTrue(app.staticTexts["No Results for \"zebra unicorn\""].waitForExistence(timeout: 10)
                      || app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "No Results")).firstMatch.waitForExistence(timeout: 5),
                      "A miss shows the no-results state")
    }

    @MainActor
    func testFolderCreateMoveOpenDelete() throws {
        let app = launch()
        sendAndWait(app, "A note to file away")

        openList(app)
        app.buttons["New Folder"].firstMatch.tap()
        let nameField = app.textFields["Folder name"].firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.typeText("Work")
        app.buttons["Create"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Work"].firstMatch.waitForExistence(timeout: 5), "Folder appears")

        // Move the chat into it via its context menu.
        openList(app)
        guard let row = listRow(app, containing: "A note to file") else {
            let dump = XCTAttachment(string: app.debugDescription)
            dump.name = "hierarchy-no-row"
            dump.lifetime = .keepAlways
            add(dump)
            return XCTFail("The chat should be listed in the drawer")
        }
        row.press(forDuration: 1.0)
        let move = app.buttons["Move to Folder"].firstMatch
        XCTAssertTrue(move.waitForExistence(timeout: 5))
        move.tap()
        let workChoice = app.buttons["Work"].firstMatch.exists ? app.buttons["Work"].firstMatch : app.staticTexts["Work"].firstMatch
        XCTAssertTrue(workChoice.waitForExistence(timeout: 5))
        workChoice.tap()
        sleep(1)

        // Open the folder and find the chat inside.
        let folderRow = app.staticTexts["Work"].firstMatch
        XCTAssertTrue(folderRow.waitForExistence(timeout: 5))
        folderRow.tap()
        XCTAssertTrue(app.navigationBars["Work"].waitForExistence(timeout: 5), "Folder contents open")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "A note to file")).firstMatch.waitForExistence(timeout: 5))
        app.navigationBars["Work"].buttons["Done"].firstMatch.tap()
        _ = app.navigationBars["Work"].waitForNonExistence(timeout: 5)

        // Delete the folder, keeping the chat: it must be back in Recent.
        folderRow.press(forDuration: 1.0)
        let deleteFolder = app.buttons["Delete"].firstMatch
        XCTAssertTrue(deleteFolder.waitForExistence(timeout: 5))
        deleteFolder.tap()
        let keep = app.buttons["Delete Folder, Keep Chats"].firstMatch
        XCTAssertTrue(keep.waitForExistence(timeout: 5), "Folder deletion asks what to do with the chats")
        keep.tap()
        XCTAssertTrue(app.staticTexts["Work"].firstMatch.waitForNonExistence(timeout: 5))
        sleep(1)
        XCTAssertNotNil(listRow(app, containing: "A note to file"), "The chat survived the folder")
    }

    /// Once the composer had shown the keyboard, an alert's buttons ignored
    /// taps on iOS 27 (Return still worked): New Folder's Create did nothing.
    /// Name prompts are sheets now; this keeps it that way.
    @MainActor
    func testNewFolderWorksAfterTheKeyboardWasUp() throws {
        let app = launch()
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        sleep(1)
        openList(app)
        app.buttons["New Folder"].firstMatch.tap()
        let name = app.textFields["Folder name"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.typeText("Receipts")
        app.buttons["Create"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Receipts"].firstMatch.waitForExistence(timeout: 5), "Create works after the keyboard was up")
    }

    @MainActor
    func testExportMarkdownOpensShareSheet() throws {
        let app = launch()
        sendAndWait(app, "Export me")
        openList(app)
        openList(app)
        guard let row = listRow(app, containing: "Export me") else {
            return XCTFail("The chat should be listed in the drawer")
        }
        row.press(forDuration: 1.0)
        let export = app.buttons["Export as Markdown"].firstMatch
        XCTAssertTrue(export.waitForExistence(timeout: 5))
        export.tap()
        // The share sheet is a system UI; its Close/Cancel control or any
        // sharing row proves it came up.
        let shareSheet = app.otherElements["ActivityListView"].firstMatch
        let appeared = shareSheet.waitForExistence(timeout: 10)
            || app.buttons["Close"].firstMatch.waitForExistence(timeout: 3)
        XCTAssertTrue(appeared, "A share sheet should appear")
    }

    // MARK: - Speech and tools

    @MainActor
    func testTranslateOpensAndCloses() throws {
        let app = launch()
        app.buttons["Tools and attachments"].firstMatch.tap()
        let translate = app.buttons["Translate"].firstMatch
        XCTAssertTrue(translate.waitForExistence(timeout: 5))
        translate.tap()
        XCTAssertTrue(app.staticTexts["Translate"].firstMatch.waitForExistence(timeout: 5))
        allowPermissionAlerts()
        XCTAssertTrue(app.buttons["Hands-free conversation"].firstMatch.waitForExistence(timeout: 5))
        let close = app.buttons["Close translate"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor
    func testRecorderRecordsAndSaves() throws {
        let app = launch()
        openList(app)
        app.buttons["Recordings"].firstMatch.tap()
        let newRecording = app.buttons["New recording"].firstMatch
        XCTAssertTrue(newRecording.waitForExistence(timeout: 5))
        newRecording.tap()

        let start = app.buttons["Start recording"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        allowPermissionAlerts()
        let stop = app.buttons["Stop and save"].firstMatch
        XCTAssertTrue(stop.waitForExistence(timeout: 20), "Recording should start")
        sleep(4)
        stop.tap()

        // Either the result screen (with a summary offer) or a notice that
        // nothing was heard: both must leave a usable screen.
        let skip = app.buttons["Skip summary"].firstMatch
        let close = app.buttons["Close recorder"].firstMatch
        let outcome = skip.waitForExistence(timeout: 20) || close.waitForExistence(timeout: 5)
        XCTAssertTrue(outcome, "Stopping should land on the result screen")
        if skip.exists { skip.tap() }
        if close.waitForExistence(timeout: 5) { close.tap() }
        _ = close.waitForNonExistence(timeout: 5)
    }

    // MARK: - Settings

    @MainActor
    func testEverySettingsScreenOpens() throws {
        let app = launch()
        openSettings(app)

        for (button, title) in [("Manage Storage", "Manage Storage"), ("Personas", "Personas"), ("Memory", "Memory"),
                                ("Knowledge Library", "Knowledge Library"), ("Privacy Center", "Privacy Center"),
                                ("About & Legal", "About & Legal")] {
            let link = row(app, button)
            XCTAssertTrue(link.waitForExistence(timeout: 5), "\(button) row exists")
            link.tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5), "\(title) should open")
            goBack(app, from: title)
            XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5), "Back in Settings after \(title)")
        }

        // Privacy Policy is a link, not a push.
        XCTAssertTrue(app.buttons["Privacy Policy"].firstMatch.exists || app.links["Privacy Policy"].firstMatch.exists,
                      "A Privacy Policy link is in Settings")
    }

    @MainActor
    func testLanguageSwitchKeepsSettingsOpenAndAutomaticReverts() throws {
        let app = launch()
        openSettings(app)

        let languageRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "App Language")).firstMatch
        XCTAssertTrue(languageRow.waitForExistence(timeout: 5), "The language row exists")
        languageRow.tap()
        let german = app.buttons["Deutsch"].firstMatch
        XCTAssertTrue(german.waitForExistence(timeout: 5))
        german.tap()

        // Settings is still open (it used to be thrown away) and in German.
        XCTAssertTrue(app.navigationBars["Einstellungen"].waitForExistence(timeout: 10), "Settings stays open, now in German")

        // Back to Automatic: English again without a relaunch.
        let sprache = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "App-Sprache")).firstMatch
        XCTAssertTrue(sprache.waitForExistence(timeout: 5))
        sprache.tap()
        let automatic = app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", "Automatisch")).firstMatch
        XCTAssertTrue(automatic.waitForExistence(timeout: 5))
        automatic.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10), "Automatic takes effect immediately")
    }

    // MARK: - App lock

    /// With Face ID enrolled in the Simulator (notifyutil
    /// com.apple.BiometricKit.enrollmentChanged), turning the lock on, then
    /// backgrounding from INSIDE Settings must bring the lock screen up
    /// over the open sheet - the case the old root cover could never handle.
    /// Opt-in: AIG_TEST_LOCK=1; it leaves the lock enabled, so run it last
    /// and uninstall the app afterwards.
    @MainActor
    func testLockCoversAnOpenSheet() throws {
        guard ProcessInfo.processInfo.environment["AIG_TEST_LOCK"] == "1" else {
            throw XCTSkip("AIG_TEST_LOCK not set")
        }
        let app = launch()
        openSettings(app)
        let toggle = app.switches.matching(NSPredicate(format: "label BEGINSWITH %@", "Lock with")).firstMatch
        for _ in 0..<4 where !toggle.exists {
            app.swipeUp()
            usleep(400_000)
        }
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "The lock toggle needs biometrics enrolled in the Simulator")
        app.swipeUp()
        sleep(1)
        let onPredicate = NSPredicate(format: "value == %@", "1")
        // The row's label does not toggle; the switch control inside does.
        let knob = toggle.switches.firstMatch
        if knob.exists { knob.tap() } else { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap() }
        if !toggle.waitFor(onPredicate, timeout: 5) {
            let dump = XCTAttachment(string: "toggle: \(toggle.debugDescription)\n\n" + app.debugDescription)
            dump.name = "lock-toggle-dump"
            dump.lifetime = .keepAlways
            add(dump)
            XCTFail("Lock should be on")
        }

        // Leave with Settings still open, come back.
        XCUIDevice.shared.press(.home)
        sleep(2)
        app.activate()

        // The system Face ID prompt comes first; cancel it so the lock
        // screen itself is what covers the app.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let prompt = springboard.alerts.firstMatch
        if prompt.waitForExistence(timeout: 5) {
            let cancel = prompt.buttons["Cancel"]
            if cancel.exists { cancel.tap() }
        }

        XCTAssertTrue(app.staticTexts["Your conversations are locked"].waitForExistence(timeout: 10),
                      "The lock screen must appear over the open Settings sheet")
        XCTAssertTrue(app.buttons["Unlock"].firstMatch.exists)
        XCTAssertFalse(app.buttons["Manage Storage"].firstMatch.isHittable, "Settings must not be reachable while locked")
    }

    // MARK: - Share extension handoff

    /// The share extension writes a file plus `pending.json` into the App
    /// Group inbox and opens `aigoodbye://shared`. This does the same by
    /// hand (the inbox path comes from the shell that starts the test) and
    /// checks the document reaches the composer and a question about it is
    /// answered. The file is Windows-1251, which the importer used to reject.
    @MainActor
    func testSharedFileReachesTheComposer() throws {
        guard let inbox = ProcessInfo.processInfo.environment["AIG_GROUP_INBOX"] else {
            throw XCTSkip("AIG_GROUP_INBOX not set")
        }
        let app = launch()

        let text = "Привет. The warranty lasts 24 months and covers the roof module.\n"
        let data = try XCTUnwrap(text.data(using: .windowsCP1251))
        let inboxURL = URL(fileURLWithPath: inbox)
        try FileManager.default.createDirectory(at: inboxURL, withIntermediateDirectories: true)
        try data.write(to: inboxURL.appendingPathComponent("E2E-warranty.txt"))
        let pending: [String: Any] = [
            "kind": "file", "fileName": "E2E-warranty.txt", "displayName": "warranty.txt",
            "createdAt": Date().timeIntervalSinceReferenceDate
        ]
        let json = try JSONSerialization.data(withJSONObject: pending)
        try json.write(to: inboxURL.appendingPathComponent("pending.json"))

        XCUIDevice.shared.system.open(URL(string: "aigoodbye://shared")!)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let openAlert = springboard.alerts.firstMatch
        if openAlert.waitForExistence(timeout: 5) {
            openAlert.buttons["Open"].tap()
        }

        XCTAssertTrue(app.staticTexts["warranty.txt"].waitForExistence(timeout: 15),
                      "The shared document should be attached to the composer")

        sendAndWait(app, "What does the warranty cover?", expectQuote: false)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "warranty cover")).firstMatch.exists)
    }
}


private extension XCUIElement {
    /// Poll until the predicate holds, like `waitForExistence` but for any
    /// attribute (used for a switch's value).
    func waitFor(_ predicate: NSPredicate, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
