//
//  AIGoodbyeChinaNetworkTests.swift
//  AIGoodbyeUITests
//
//  A first run on a network that blocks Hugging Face the way mainland
//  China does: the name resolves, but connections to it never answer.
//  AIG_HF_HOST points the Hugging Face requests at a blackhole address
//  (debug builds only), so the app must notice and fall back to ModelScope
//  on its own. Screenshots every few seconds show what a user there sees.
//
//  Opt-in: TEST_RUNNER_AIG_CHINA_TEST=1. Needs the network.
//

import XCTest

final class AIGoodbyeChinaNetworkTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = true
        guard ProcessInfo.processInfo.environment["AIG_CHINA_TEST"] == "1" else {
            throw XCTSkip("China network test is opt-in")
        }
    }

    @MainActor
    func testFirstRunDownloadWithHuggingFaceBlackholed() throws {
        let app = XCUIApplication()
        app.launchEnvironment["AIG_SIM_TEST_DOWNLOAD"] = "1"
        let env = ProcessInfo.processInfo.environment
        // Blackholed unless told otherwise ("none": the real Hugging Face).
        let hfHost = env["AIG_HF_HOST"] ?? "10.255.255.1"
        if hfHost != "none" { app.launchEnvironment["AIG_HF_HOST"] = hfHost }
        for key in ["AIG_REGION_CN", "AIG_MS_BREAK_PRIMARY"] {
            if let value = env[key] { app.launchEnvironment[key] = value }
        }
        app.launchEnvironment["AIG_MEMORY_LIMIT_GB"] = ProcessInfo.processInfo.environment["AIG_MEMORY_LIMIT_GB"] ?? "4.3"
        app.launchArguments += ["-hasAcceptedTerms", "YES"]
        if let language = ProcessInfo.processInfo.environment["AIG_SHOT_LANGUAGE"] {
            app.launchArguments += ["-AppleLanguages", "(\(language))", "-AppleLocale", language]
        }
        app.launch()

        // The setup sheet offers the recommended download.
        let download = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Download '")).firstMatch
        XCTAssertTrue(download.waitForExistence(timeout: 15), "no download button on the setup sheet")
        snap(app, "00-setup")
        download.tap()

        // Watch for three minutes: Hugging Face times out, then ModelScope
        // should start moving bytes.
        let seconds = Int(ProcessInfo.processInfo.environment["AIG_WATCH_SECONDS"] ?? "180") ?? 180
        var elapsed = 0
        while elapsed < seconds {
            sleep(10)
            elapsed += 10
            snap(app, String(format: "t%03d", elapsed))
            // Anything that reads like a failure, verbatim, for the log.
            // One snapshot of the whole tree: querying elements one by one
            // races the progress text, which changes every moment.
            let texts = app.debugDescription.components(separatedBy: "\n")
            let notable = texts.filter {
                $0.localizedCaseInsensitiveContains("download")
                    || $0.localizedCaseInsensitiveContains("couldn")
                    || $0.localizedCaseInsensitiveContains("stall")
                    || $0.localizedCaseInsensitiveContains("error")
                    || $0.localizedCaseInsensitiveContains("connection")
            }
            let note = XCTAttachment(string: "t=\(elapsed)s\n" + notable.joined(separator: "\n"))
            note.name = String(format: "t%03d-text", elapsed)
            note.lifetime = .keepAlways
            add(note)
        }
    }

    @MainActor
    private func snap(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
