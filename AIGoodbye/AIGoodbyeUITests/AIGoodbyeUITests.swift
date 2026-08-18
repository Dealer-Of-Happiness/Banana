//
//  AIGoodbyeUITests.swift
//  AIGoodbyeUITests
//
//  Smoke test: the app must launch without crashing.
//

import XCTest

final class AIGoodbyeUITests: XCTestCase {

    @MainActor
    func testAppLaunches() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.state == .runningForeground)
    }
}
