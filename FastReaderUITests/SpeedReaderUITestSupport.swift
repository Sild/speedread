import XCTest

@MainActor
extension FastReaderUITests {
    func exerciseSpeedReader(in app: XCUIApplication) {
        let regularSelectorFrame = selectorFrame(in: app)
        app.buttons["reader.mode.speed"].tap()
        XCTAssertTrue(app.buttons["speed.playPause"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["speed.wpm"].exists)
        XCTAssertTrue(app.buttons["speed.wpm.decrease"].exists)
        XCTAssertTrue(app.buttons["speed.wpm.increase"].exists)
        let speedSelectorFrame = selectorFrame(in: app)
        XCTAssertEqual(speedSelectorFrame.midX, regularSelectorFrame.midX, accuracy: 2)
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
        XCTAssertGreaterThanOrEqual(app.buttons["speed.previous"].frame.width, 60)
        XCTAssertGreaterThanOrEqual(app.buttons["speed.previous"].frame.height, 60)
        XCTAssertGreaterThanOrEqual(app.buttons["speed.playPause"].frame.width, 68)
        XCTAssertGreaterThanOrEqual(app.buttons["speed.playPause"].frame.height, 68)
        XCTAssertGreaterThanOrEqual(app.buttons["speed.next"].frame.width, 60)
        XCTAssertGreaterThanOrEqual(app.buttons["speed.next"].frame.height, 60)
        XCTAssertGreaterThanOrEqual(app.buttons["speed.wpm.decrease"].frame.width, 52)
        XCTAssertGreaterThanOrEqual(app.buttons["speed.wpm.decrease"].frame.height, 52)
        XCTAssertGreaterThanOrEqual(app.buttons["speed.wpm.increase"].frame.width, 52)
        XCTAssertGreaterThanOrEqual(app.buttons["speed.wpm.increase"].frame.height, 52)
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
