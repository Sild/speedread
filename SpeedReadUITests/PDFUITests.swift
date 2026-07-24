import XCTest

final class PDFUITests: XCTestCase {
    @MainActor
    func testImportNativePDFAndPrepareLocalOCRSpeedMode() throws {
        let device = XCUIDevice.shared
        defer { device.orientation = .portrait }

        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-testing",
            "-ui-testing-free",
            "-ui-testing-dark",
            "-ui-testing-reduce-motion",
            "-ui-testing-accessibility-text"
        ]
        app.launch()

        let bundle = Bundle(for: Self.self)
        let fixtureURL = try XCTUnwrap(
            bundle.url(forResource: "pdf-long-scanned", withExtension: "pdf")
        )
        app.open(fixtureURL)

        let importedTitle = NSPredicate(format: "label CONTAINS %@", "pdf-long-scanned")
        let book = app.buttons.matching(importedTitle).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 8))
        book.tap()

        XCTAssertTrue(app.otherElements["reader.navigator"].waitForExistence(timeout: 8))
        scrubRegularReaderProgress(in: app)

        let appearanceButton = try requireReaderControl("reader.appearance", in: app)
        appearanceButton.tap()
        let scrollSwitch = app.switches["reader.appearance.scroll"]
        XCTAssertTrue(scrollSwitch.waitForExistence(timeout: 3))
        XCTAssertEqual(scrollSwitch.value as? String, "1")
        XCTAssertFalse(app.pickers["reader.appearance.font"].exists)
        app.buttons["reader.appearance.close"].tap()
        let speedButton = try requireReaderControl("reader.mode.speed", in: app)
        speedButton.tap()
        _ = app.progressIndicators["speed.loading"].waitForExistence(timeout: 1)
        XCTAssertTrue(app.buttons["speed.playPause"].waitForExistence(timeout: 12))

        let measurementOptions = XCTMeasureOptions()
        measurementOptions.iterationCount = 1
        measure(metrics: [XCTMemoryMetric(application: app)], options: measurementOptions) {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 1))
        }

        device.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["speed.playPause"].waitForExistence(timeout: 3))
        app.buttons["reader.mode.regular"].tap()
        XCTAssertTrue(app.otherElements["reader.navigator"].waitForExistence(timeout: 8))
    }

    @MainActor
    private func scrubRegularReaderProgress(in app: XCUIApplication) {
        let progressSlider = app.sliders["reader.progress"]
        XCTAssertTrue(progressSlider.waitForExistence(timeout: 3))
        let percentage = app.staticTexts["reader.progress.percentage"]
        let initialProgress = percentage.label
        progressSlider.adjust(toNormalizedSliderPosition: 0.65)
        let progressChanged = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label != %@", initialProgress),
            object: percentage
        )
        wait(for: [progressChanged], timeout: 8)

        progressSlider.adjust(toNormalizedSliderPosition: 1)
        let reachedEnd = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "100%"),
            object: percentage
        )
        wait(for: [reachedEnd], timeout: 8)

        progressSlider.adjust(toNormalizedSliderPosition: 0.65)
        let returnedFromEnd = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label != %@", "100%"),
            object: percentage
        )
        wait(for: [returnedFromEnd], timeout: 8)
    }
}

@MainActor
extension SpeedReadUITests {
    func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
