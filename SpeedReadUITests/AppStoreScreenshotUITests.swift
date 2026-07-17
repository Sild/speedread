import XCTest

final class AppStoreScreenshotUITests: XCTestCase {
    @MainActor
    func testAppStoreScreenshots() throws {
        let device = XCUIDevice.shared
        let libraryApp = XCUIApplication()
        libraryApp.launchArguments = [
            "-ui-testing",
            "-ui-testing-filter-library",
            "-ui-testing-reduce-motion"
        ]
        libraryApp.launch()

        XCTAssertTrue(libraryApp.scrollViews["library.bookGrid"].waitForExistence(timeout: 8))
        let usesWideLayout = libraryApp.frame.width >= 700
        if usesWideLayout {
            device.orientation = .landscapeLeft
        }
        defer { device.orientation = .portrait }
        attachScreenshot(named: "AppStore-01-Library")
        if usesWideLayout {
            openTagEditor(for: "Alpha Guide", in: libraryApp)
            attachScreenshot(named: "AppStore-02-Tag-Organization")
        }
        libraryApp.terminate()

        let readerApp = XCUIApplication()
        readerApp.launchArguments = ["-ui-testing", "-ui-testing-reduce-motion"]
        readerApp.launch()
        let bundle = Bundle(for: Self.self)
        let fixtureURL = try XCTUnwrap(bundle.url(forResource: "long-chapter", withExtension: "epub"))
        readerApp.open(fixtureURL)
        let book = button(containing: "Путешествие Swift", in: readerApp)
        XCTAssertTrue(book.waitForExistence(timeout: 8))
        book.tap()

        XCTAssertTrue(readerApp.otherElements["reader.navigator"].waitForExistence(timeout: 8))
        XCTAssertTrue(readerApp.buttons["reader.mode.speed"].waitForExistence(timeout: 3))
        let speedMode = restartReaderChrome(in: readerApp)
        if !usesWideLayout {
            attachScreenshot(named: "AppStore-02-Regular-Reader")
        }

        if !speedMode.waitForExistence(timeout: 1) {
            readerApp.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        XCTAssertTrue(speedMode.waitForExistence(timeout: 3))
        speedMode.tap()
        XCTAssertTrue(readerApp.buttons["speed.playPause"].waitForExistence(timeout: 8))
        readerApp.buttons["speed.next"].tap()
        readerApp.buttons["speed.next"].tap()
        readerApp.buttons["speed.next"].tap()
        attachScreenshot(named: "AppStore-03-Speed-Reader")
    }
}

@MainActor
private extension AppStoreScreenshotUITests {
    func button(containing label: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", label)).firstMatch
    }

    func openTagEditor(for title: String, in app: XCUIApplication) {
        let book = button(containing: title, in: app)
        XCTAssertTrue(book.waitForExistence(timeout: 5))
        book.press(forDuration: 1)
        let editTags = app.buttons["Edit Tags"]
        XCTAssertTrue(editTags.waitForExistence(timeout: 3))
        editTags.tap()
        XCTAssertTrue(app.navigationBars["Edit Tags"].waitForExistence(timeout: 3))
    }

    func restartReaderChrome(in app: XCUIApplication) -> XCUIElement {
        let speedMode = app.buttons["reader.mode.speed"]
        if speedMode.exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            XCTAssertTrue(speedMode.waitForNonExistence(timeout: 3))
        }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(speedMode.waitForExistence(timeout: 3))
        return speedMode
    }

    func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
