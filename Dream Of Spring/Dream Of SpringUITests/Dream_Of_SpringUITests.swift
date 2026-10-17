//
//  Dream_Of_SpringUITests.swift
//  Dream Of SpringUITests
//
//  Created by David Powers on 5/9/26.
//

import XCTest

final class Dream_Of_SpringUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testNestedMenuStaysOpen() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--disable-sleep-enforcement", "-batteryProtectionEnabled", "YES"]
        app.launch()
        defer { app.terminate() }

        let statusItem = app.menuBars.menuBarItems["Dream Of Spring"]
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
        statusItem.click()
        let battery = app.menuItems["Battery Protection"]
        XCTAssertTrue(battery.waitForExistence(timeout: 3))
        battery.hover()
        let reserve = app.menuItems["Reserve target"]
        XCTAssertTrue(reserve.waitForExistence(timeout: 3))
        reserve.hover()
        let choice = app.menuItems["25%"]
        XCTAssertTrue(choice.waitForExistence(timeout: 3))
        choice.hover()

        // Stay beyond the reported half-second dismissal, checking that the
        // nested item remains visible and available for pointer interaction.
        let disappears = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in !choice.exists || !choice.isHittable }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [disappears], timeout: 2), .timedOut)
        app.typeKey(.escape, modifierFlags: [])
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            let app = XCUIApplication()
            app.launchArguments = ["--disable-sleep-enforcement"]
            app.launch()
        }
    }
}
