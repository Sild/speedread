import XCTest

extension SpeedReadUITests {
    @MainActor
    func testFreeReaderIncludesSpeedAndPaywallShowsEveryOffer() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-free"]
        app.launch()

        try openMonetizationFixtureBook(in: app)
        XCTAssertTrue(app.otherElements["reader.navigator"].waitForExistence(timeout: 8))
        app.buttons["reader.mode.speed"].tap()

        XCTAssertTrue(app.buttons["speed.playPause"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.navigationBars["SpeedRead Pro"].exists)
        app.buttons["reader.back"].tap()
        XCTAssertTrue(app.buttons["library.pro"].waitForExistence(timeout: 3))
        app.buttons["library.pro"].tap()

        XCTAssertTrue(app.navigationBars["SpeedRead Pro"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["pro.purchase.com.sild.speedread.pro.monthly"].isHittable)
        XCTAssertTrue(app.buttons["pro.purchase.com.sild.speedread.pro.annual"].isHittable)
        XCTAssertTrue(app.buttons["pro.purchase.com.sild.speedread.pro.lifetime"].isHittable)
        XCTAssertTrue(app.staticTexts["Best value"].exists)
        XCTAssertTrue(app.staticTexts["Unlimited EPUB and PDF library"].exists)
        XCTAssertTrue(app.staticTexts["Private iCloud library sync"].exists)
        XCTAssertTrue(app.buttons["pro.redeemOfferCode"].isHittable)
        XCTAssertTrue(app.buttons["pro.restore"].isHittable)
        XCTAssertTrue(app.descendants(matching: .any)["pro.support"].isHittable)
        XCTAssertTrue(app.descendants(matching: .any)["pro.privacyPolicy"].isHittable)
        XCTAssertTrue(app.descendants(matching: .any)["pro.termsOfUse"].isHittable)
        try app.performAccessibilityAudit(for: [
            .elementDetection,
            .hitRegion,
            .sufficientElementDescription,
            .textClipped,
            .trait
        ]) { issue in
            // XCTest scans the dimmed library behind an iPad form sheet even though
            // the modal correctly removes those controls from the accessibility tree.
            app.frame.width >= 700
                && issue.auditType == .elementDetection
                && issue.element == nil
        }
        app.buttons["pro.close"].tap()
        XCTAssertTrue(app.scrollViews["library.bookGrid"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testFreeLibraryLimitOffersAndUnlocksPro() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-free", "-ui-testing-filter-library"]
        app.launch()

        let grid = app.scrollViews["library.bookGrid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 8))
        XCTAssertEqual(grid.value as? String, "4")

        try app.open(monetizationFixtureURL(named: "pdf-image-only", extension: "pdf"))
        let alert = app.alerts["Import failed"]
        XCTAssertTrue(alert.waitForExistence(timeout: 8))
        let limitMessage = alert.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "up to 3 books")
        ).firstMatch
        XCTAssertTrue(limitMessage.exists)
        alert.buttons["View Pro"].tap()

        XCTAssertTrue(app.navigationBars["SpeedRead Pro"].waitForExistence(timeout: 3))
        app.buttons["pro.purchase.com.sild.speedread.pro.annual"].tap()
        XCTAssertTrue(app.staticTexts["Pro active"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["pro.manageSubscription"].exists)
        XCTAssertTrue(app.buttons["pro.requestRefund"].isHittable)
        XCTAssertTrue(app.buttons["pro.redeemOfferCode"].isHittable)
        XCTAssertFalse(app.buttons["pro.purchase.com.sild.speedread.pro.lifetime"].exists)
        app.buttons["pro.close"].tap()
        XCTAssertTrue(app.buttons["library.pro"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testLifetimeAccessDoesNotOfferCodeRedemption() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()

        XCTAssertTrue(app.buttons["library.pro"].waitForExistence(timeout: 8))
        app.buttons["library.pro"].tap()

        XCTAssertTrue(app.navigationBars["SpeedRead Pro"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["pro.redeemOfferCode"].exists)
        XCTAssertFalse(app.buttons["pro.requestRefund"].exists)
    }
}

@MainActor
private extension SpeedReadUITests {
    func monetizationFixtureURL(named name: String, extension fileExtension: String) throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: fileExtension))
    }

    func openMonetizationFixtureBook(in app: XCUIApplication) throws {
        try app.open(monetizationFixtureURL(named: "epub3-cyrillic", extension: "epub"))
        let book = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Путешествие Swift")
        ).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 8))
        book.tap()
    }
}
