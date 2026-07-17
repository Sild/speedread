import XCTest

@MainActor
extension FastReaderUITests {
    func testSpeedControlsDarkLandscapeAccessibilityLayout() throws {
        let device = XCUIDevice.shared
        device.orientation = .landscapeLeft
        defer { device.orientation = .portrait }

        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-testing",
            "-ui-testing-dark",
            "-ui-testing-reduce-motion",
            "-ui-testing-accessibility-text"
        ]
        app.launch()

        let fixtureURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "epub3-cyrillic", withExtension: "epub")
        )
        app.open(fixtureURL)
        let book = app.buttons
            .matching(NSPredicate(format: "label CONTAINS %@", "Путешествие Swift"))
            .firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 8))
        book.tap()
        XCTAssertTrue(app.buttons["reader.mode.speed"].waitForExistence(timeout: 8))
        app.buttons["reader.mode.speed"].tap()
        XCTAssertTrue(app.buttons["speed.playPause"].waitForExistence(timeout: 8))
        assertWPMPlacement(in: app, selectorFrame: selectorFrame(in: app))
        assertSpeedButtonSizes(in: app)
        attachScreenshot(named: "Dark landscape accessibility speed controls")
        try app.performAccessibilityAudit(for: [
            .elementDetection,
            .hitRegion,
            .sufficientElementDescription,
            .textClipped,
            .trait
        ])
    }

    func exerciseSpeedReader(in app: XCUIApplication) {
        let regularSelectorFrame = selectorFrame(in: app)
        app.buttons["reader.mode.speed"].tap()
        XCTAssertTrue(app.buttons["speed.playPause"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["speed.wpm"].exists)
        XCTAssertTrue(app.buttons["speed.wpm.decrease"].exists)
        XCTAssertTrue(app.buttons["speed.wpm.increase"].exists)
        let speedSelectorFrame = selectorFrame(in: app)
        XCTAssertEqual(speedSelectorFrame.midX, regularSelectorFrame.midX, accuracy: 2)
        XCTAssertEqual(speedSelectorFrame.midY, regularSelectorFrame.midY, accuracy: 2)
        assertWPMPlacement(in: app, selectorFrame: speedSelectorFrame)
        assertSpeedButtonSizes(in: app)
        app.buttons["speed.wpm.increase"].tap()
        XCTAssertEqual(app.staticTexts["speed.wpm"].label, "325 WPM")
        app.buttons["speed.wpm.decrease"].tap()
        XCTAssertEqual(app.staticTexts["speed.wpm"].label, "300 WPM")
        app.buttons["speed.settings"].tap()
        let adaptivePauses = app.descendants(matching: .any)
            .matching(identifier: "speed.adaptive")
            .firstMatch
        XCTAssertTrue(adaptivePauses.waitForExistence(timeout: 3))
        adaptivePauses.tap()
        exerciseAutoHide(in: app)
        app.buttons["speed.previous"].tap()
        app.buttons["speed.next"].tap()
        app.buttons["speed.next"].tap()
        app.buttons["speed.next"].tap()
        attachScreenshot(named: "Single-rail speed reader context")
        app.buttons["reader.mode.regular"].tap()
        let navigator = app.otherElements["reader.navigator"]
        XCTAssertTrue(navigator.waitForExistence(timeout: 8))
        XCTAssertEqual(navigator.value as? String, "сохраняет")
        let highlightedParagraph = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS %@", "Скорочтение"))
            .firstMatch
        XCTAssertTrue(highlightedParagraph.waitForExistence(timeout: 8))
        attachScreenshot(named: "Regular reader active speed word highlight")
        app.buttons["reader.mode.speed"].tap()
        XCTAssertTrue(app.buttons["speed.playPause"].waitForExistence(timeout: 8))
        app.buttons["reader.mode.regular"].tap()
        XCTAssertTrue(navigator.waitForExistence(timeout: 8))
        XCTAssertEqual(navigator.value as? String, "сохраняет")
    }

    func assertSpeedButtonSizes(in app: XCUIApplication) {
        XCTAssertGreaterThanOrEqual(app.buttons["speed.previous"].frame.width.rounded(), 60)
        XCTAssertGreaterThanOrEqual(app.buttons["speed.previous"].frame.height.rounded(), 60)
        XCTAssertGreaterThanOrEqual(app.buttons["speed.playPause"].frame.width.rounded(), 68)
        XCTAssertGreaterThanOrEqual(app.buttons["speed.playPause"].frame.height.rounded(), 68)
        XCTAssertGreaterThanOrEqual(app.buttons["speed.next"].frame.width.rounded(), 60)
        XCTAssertGreaterThanOrEqual(app.buttons["speed.next"].frame.height.rounded(), 60)
        XCTAssertGreaterThanOrEqual(app.buttons["speed.wpm.decrease"].frame.width.rounded(), 60)
        XCTAssertGreaterThanOrEqual(app.buttons["speed.wpm.decrease"].frame.height.rounded(), 60)
        XCTAssertGreaterThanOrEqual(app.buttons["speed.wpm.increase"].frame.width.rounded(), 60)
        XCTAssertGreaterThanOrEqual(app.buttons["speed.wpm.increase"].frame.height.rounded(), 60)
    }

    func assertWPMPlacement(in app: XCUIApplication, selectorFrame: CGRect) {
        let progress = app.sliders["reader.progress"]
        let wpm = app.staticTexts["speed.wpm"]
        let decrease = app.buttons["speed.wpm.decrease"]
        let increase = app.buttons["speed.wpm.increase"]

        XCTAssertTrue(progress.exists)
        XCTAssertGreaterThan(wpm.frame.minY, progress.frame.maxY)
        XCTAssertGreaterThan(wpm.frame.minY, selectorFrame.maxY)
        XCTAssertEqual(wpm.frame.midX, selectorFrame.midX, accuracy: 2)
        XCTAssertLessThan(decrease.frame.maxX, wpm.frame.minX)
        XCTAssertGreaterThan(increase.frame.minX, wpm.frame.maxX)
        XCTAssertEqual(decrease.frame.midY, selectorFrame.midY, accuracy: 2)
        XCTAssertEqual(increase.frame.midY, selectorFrame.midY, accuracy: 2)
    }

    func selectorFrame(in app: XCUIApplication) -> CGRect {
        let selector = app.descendants(matching: .any)
            .matching(identifier: "reader.mode.selector")
            .firstMatch
        XCTAssertTrue(selector.exists)
        return selector.frame
    }

    func exerciseAutoHide(in app: XCUIApplication) {
        app.buttons["speed.playPause"].tap()
        XCTAssertFalse(app.buttons["speed.playPause"].exists)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["speed.playPause"].waitForExistence(timeout: 3))
    }
}
