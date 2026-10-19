//
//  AIGoodbyeAccessibilityAudit.swift
//  AIGoodbyeUITests
//
//  Walks the app's common tasks and runs Xcode's accessibility audit
//  (contrast, Dynamic Type, clipped text, labels, hit regions, traits) on
//  every screen, so the App Store Accessibility Nutrition Labels can be
//  answered from evidence rather than hope. Issues are printed as
//  "A11Y|screen|type|description|element" lines and every screen is
//  attached as a screenshot. Opt-in with AIG_A11Y_AUDIT=1; run it again
//  with AIG_CONTENT_SIZE=UICTContentSizeCategoryAccessibilityXXXL and with
//  the simulator in dark mode / Increase Contrast.
//

import XCTest

final class AIGoodbyeAccessibilityAudit: XCTestCase {

    private var screensAudited = 0
    private var issuesFound = 0
    private var report: [String] = []

    override func setUpWithError() throws {
        continueAfterFailure = true
        guard ProcessInfo.processInfo.environment["AIG_A11Y_AUDIT"] == "1" else {
            throw XCTSkip("accessibility audit is opt-in")
        }
    }

    @MainActor
    func testAuditCommonTasks() throws {
        let app = XCUIApplication()
        if ProcessInfo.processInfo.environment["AIG_FORCE_NO_AI"] == "1" {
            app.launchEnvironment["AIG_FORCE_NO_AI"] = "1"
        }
        if let size = ProcessInfo.processInfo.environment["AIG_CONTENT_SIZE"], !size.isEmpty {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", size]
        }
        app.launch()

        addUIInterruptionMonitor(withDescription: "Permissions") { alert in
            for label in ["OK", "Allow", "Allow While Using App", "Don't Allow"] {
                let button = alert.buttons[label]
                if button.exists { button.tap(); return true }
            }
            return false
        }

        // First launch experience.
        let agree = app.buttons["Agree and Continue"]
        if agree.waitForExistence(timeout: 5) {
            audit(app, "00-terms")
            agree.tap()
        }
        if app.navigationBars["Set Up"].waitForExistence(timeout: 5) {
            audit(app, "01-setup")
            for label in ["Not now", "Done"] where app.buttons[label].firstMatch.exists {
                app.buttons[label].firstMatch.tap()
                break
            }
            _ = app.navigationBars["Set Up"].waitForNonExistence(timeout: 5)
        }

        fresh(app)
        audit(app, "10-chat-empty")

        openList(app)
        audit(app, "11-conversations")

        // Settings and its main pages, each from a fresh launch.
        if openSettings(app) {
            audit(app, "12-settings")
        }
        for page in ["Manage Storage", "Personas", "Memory", "Knowledge Library", "Privacy Center", "About & Legal"] {
            fresh(app)
            openList(app)
            guard openSettings(app) else { continue }
            let link = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", page)).firstMatch
            for _ in 0..<6 where !(link.exists && link.isHittable) {
                app.swipeUp()
            }
            guard link.exists && link.isHittable else {
                report.append("A11Y-SKIP|settings-\(page)")
                continue
            }
            link.tap()
            sleep(1)
            audit(app, "13-settings-\(page.lowercased().replacingOccurrences(of: " ", with: "-"))")
        }

        // Recordings and the recorder.
        fresh(app)
        openList(app)
        let recordings = app.buttons["Recordings"].firstMatch
        if recordings.exists && recordings.isHittable {
            recordings.tap()
            sleep(1)
            audit(app, "20-recordings")
            let newRecording = app.buttons["New recording"].firstMatch
            if newRecording.waitForExistence(timeout: 3) {
                newRecording.tap()
                sleep(2)
                allowSystemAlert()
                audit(app, "21-recorder")
            }
        }

        // Voice mode.
        fresh(app)
        let voiceButton = app.buttons["Start a voice conversation"]
        if voiceButton.waitForExistence(timeout: 5) {
            voiceButton.tap()
            sleep(2)
            allowSystemAlert()
            sleep(3)
            audit(app, "30-voice")
        }

        // Tools menu: translate and Describe Surroundings.
        for (tool, name) in [("Translate", "31-translate"), ("Describe Surroundings", "32-describe-surroundings")] {
            fresh(app)
            let tools = app.buttons["Tools and attachments"].firstMatch
            if tools.waitForExistence(timeout: 5) {
                tools.tap()
                sleep(1)
                if name == "31-translate" { audit(app, "33-tools-menu") }
                let item = app.buttons[tool].firstMatch
                if item.waitForExistence(timeout: 3) {
                    item.tap()
                    sleep(2)
                    allowSystemAlert()
                    sleep(2)
                    audit(app, name)
                }
            }
        }

        // Model picker.
        fresh(app)
        var chooseModel = app.buttons["Choose Model"].firstMatch
        if !(chooseModel.exists && chooseModel.isHittable) {
            let options = app.buttons["Chat options"].firstMatch
            if options.exists && options.isHittable {
                options.tap()
                sleep(1)
                audit(app, "40-chat-options")
                chooseModel = app.buttons["Choose Model"].firstMatch
            }
        }
        if chooseModel.waitForExistence(timeout: 3) && chooseModel.isHittable {
            chooseModel.tap()
            sleep(1)
            audit(app, "41-model-picker")
        }

        // Chat: send a message and read the answer (or the download
        // consent sheet when there is no model to answer with).
        fresh(app)
        let field = app.textFields.firstMatch
        if field.waitForExistence(timeout: 5) {
            field.tap()
            field.typeText("Give me three tips for a calm morning.")
            if app.buttons["Send message"].waitForExistence(timeout: 3) {
                app.buttons["Send message"].tap()
                if app.buttons["Download"].waitForExistence(timeout: 5) {
                    sleep(1)
                    audit(app, "50-download-consent")
                } else {
                    // Wait for the answer to finish streaming.
                    let stop = app.buttons["Stop generating"].firstMatch
                    for _ in 0..<60 where stop.exists { sleep(1) }
                    sleep(2)
                    if app.keyboards.firstMatch.exists {
                        app.swipeDown()
                        sleep(1)
                    }
                    audit(app, "51-chat-with-answer")
                }
            }
        }

        report.append("A11Y-SUMMARY|screens=\(screensAudited)|issues=\(issuesFound)")
        let text = XCTAttachment(string: report.joined(separator: "\n"))
        text.name = "a11y-report"
        text.lifetime = .keepAlways
        add(text)
        if let dir = ProcessInfo.processInfo.environment["AIG_REPORT_DIR"], !dir.isEmpty {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? report.joined(separator: "\n").write(toFile: dir + "/a11y-report.txt", atomically: true, encoding: .utf8)
        }
    }

    @MainActor
    private func openSettings(_ app: XCUIApplication) -> Bool {
        let settings = app.buttons["Settings"].firstMatch
        guard settings.exists && settings.isHittable else { return false }
        settings.tap()
        return app.buttons["Manage Storage"].waitForExistence(timeout: 5)
    }

    // MARK: - Helpers

    /// Permission prompts belong to SpringBoard, and the audit refuses to
    /// run while one is in front.
    @MainActor
    private func allowSystemAlert() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<3 {
            let allow = springboard.buttons.matching(NSPredicate(format: "label IN %@", ["Allow", "OK", "Allow While Using App"])).firstMatch
            guard allow.waitForExistence(timeout: 2) else { return }
            allow.tap()
            sleep(1)
        }
    }

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
    private func audit(_ app: XCUIApplication, _ screen: String) {
        screensAudited += 1
        let shot = app.windows.firstMatch.exists ? app.windows.firstMatch.screenshot() : app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = screen
        attachment.lifetime = .keepAlways
        add(attachment)
        // Also straight to disk when asked: a result bundle is only written
        // if xcodebuild exits cleanly, which it often doesn't after UI tests.
        if let dir = ProcessInfo.processInfo.environment["AIG_REPORT_DIR"], !dir.isEmpty {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(screen).png"))
        }
        do {
            try app.performAccessibilityAudit(for: .all) { issue in
                self.issuesFound += 1
                let element = issue.element
                let label = element.map { "\($0.elementType.rawValue)|\($0.label)|\($0.identifier)|\(NSCoder.string(for: $0.frame))" } ?? "-"
                self.report.append("A11Y|\(screen)|\(Self.name(issue.auditType))|\(issue.compactDescription)|\(label)")
                return true
            }
            report.append("A11Y-OK|\(screen)")
        } catch {
            report.append("A11Y-ERROR|\(screen)|\(error)")
        }
    }

    private static func name(_ type: XCUIAccessibilityAuditType) -> String {
        let names: [(XCUIAccessibilityAuditType, String)] = [
            (.contrast, "contrast"), (.elementDetection, "elementDetection"),
            (.hitRegion, "hitRegion"), (.sufficientElementDescription, "description"),
            (.dynamicType, "dynamicType"), (.textClipped, "textClipped"),
            (.trait, "trait"),
        ]
        let hits = names.filter { type.contains($0.0) }.map(\.1)
        return hits.isEmpty ? "other(\(type.rawValue))" : hits.joined(separator: "+")
    }
}
