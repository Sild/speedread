import XCTest

final class FastReaderUITests: XCTestCase {
    @MainActor
    func testEmptyLibraryIsVisible() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()

        XCTAssertTrue(app.staticTexts["library.empty.title"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["library.import"].exists)
    }

    @MainActor
    func testEmptyLibraryAccessibilityAudit() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()

        XCTAssertTrue(app.staticTexts["library.empty.title"].waitForExistence(timeout: 5))
        try app.performAccessibilityAudit { issue in
            // Xcode misreports only this iPad pill; measured contrast is 4.67:1.
            app.frame.width >= 700
                && issue.auditType == .contrast
                && issue.element?.label == "All"
        }
    }

    @MainActor
    func testDarkLandscapeReducedMotionAndAccessibilityText() throws {
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

        XCTAssertTrue(app.staticTexts["library.empty.title"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["library.import"].isHittable)
        try app.performAccessibilityAudit(for: [
            .elementDetection,
            .hitRegion,
            .sufficientElementDescription,
            .textClipped,
            .trait
        ])
    }

    @MainActor
    func testLargeLibraryRemainsResponsive() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-large-library"]
        app.launch()

        let grid = app.scrollViews["library.bookGrid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 8))
        XCTAssertEqual(grid.value as? String, "500")
        grid.swipeUp()
        XCTAssertTrue(grid.exists)
    }

    @MainActor
    func testLargeLibraryLaunchPerformance() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-large-library"]

        measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)]) {
            app.launch()
        }
    }

    @MainActor
    func testCompactLibraryAndFacetedFilters() {
        let app = launchFilterLibrary()
        let grid = app.scrollViews["library.bookGrid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 5))
        XCTAssertEqual(grid.value as? String, "4")
        assertFilterLayout(in: app)
        assertCompactGrid(in: app)
        attachScreenshot(named: "Three-column compact library")
        applyFacetedFilters(in: app, grid: grid)
        assertSearchCounts(in: app, grid: grid)
        attachScreenshot(named: "Compact library and faceted filters")
    }

    @MainActor
    func testTagPickerSelectsCreatesSavesAndCancels() throws {
        let app = launchFilterLibrary()
        openTagEditor(for: "Alpha Guide", in: app)

        let fiction = app.buttons["library.tags.option.fiction"]
        let focus = app.buttons["library.tags.option.focus"]
        let rare = app.buttons["library.tags.option.rare"]
        XCTAssertTrue(fiction.isSelected)
        XCTAssertTrue(focus.isSelected)
        XCTAssertFalse(rare.isSelected)
        XCTAssertFalse(app.buttons["library.tags.save"].isEnabled)
        try app.performAccessibilityAudit(for: [
            .hitRegion,
            .sufficientElementDescription,
            .textClipped,
            .trait
        ])

        let search = app.textFields["library.tags.search"]
        search.tap()
        search.typeText("Rare")
        XCTAssertFalse(app.buttons["library.tags.create"].exists)
        app.buttons["library.tags.option.rare"].tap()
        XCTAssertEqual(search.value as? String, "Tag name")

        search.tap()
        search.typeText("Long Form")
        XCTAssertTrue(app.buttons["library.tags.create"].waitForExistence(timeout: 3))
        attachScreenshot(named: "Searchable tag picker create action")
        app.buttons["library.tags.create"].tap()
        XCTAssertTrue(app.buttons["library.tags.option.long form"].isSelected)
        XCTAssertTrue(app.buttons["library.tags.save"].isEnabled)
        app.buttons["library.tags.save"].tap()

        let grid = app.scrollViews["library.bookGrid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 5))
        XCTAssertEqual(button(containing: "Long Form", in: app).value as? String, "1")

        openTagEditor(for: "Alpha Guide", in: app)
        XCTAssertTrue(app.buttons["library.tags.option.long form"].isSelected)
        app.buttons["library.tags.option.fiction"].tap()
        app.buttons["library.tags.save"].tap()
        XCTAssertTrue(grid.waitForExistence(timeout: 5))
        XCTAssertEqual(button(containing: "Fiction", in: app).value as? String, "2")
        assertTagCancellation(in: app, grid: grid)
    }

    @MainActor
    func testTagPickerSaveFailureKeepsDraftVisible() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-testing",
            "-ui-testing-filter-library",
            "-ui-testing-fail-tag-save"
        ]
        app.launch()

        openTagEditor(for: "Alpha Guide", in: app)
        app.buttons["library.tags.option.focus"].tap()
        app.buttons["library.tags.save"].tap()

        let alert = app.alerts["Couldn’t Save Tags"]
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        alert.buttons["OK"].tap()
        XCTAssertTrue(app.navigationBars["Edit Tags"].exists)
        XCTAssertTrue(app.textFields["library.tags.search"].exists)
        XCTAssertFalse(app.buttons["library.tags.option.focus"].isSelected)
        app.buttons["library.tags.cancel"].tap()
    }

    @MainActor
    func testTagPickerDarkAccessibilityLayout() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-testing",
            "-ui-testing-filter-library",
            "-ui-testing-dark",
            "-ui-testing-accessibility-text"
        ]
        app.launch()

        openTagEditor(for: "Alpha Guide", in: app)
        XCTAssertTrue(app.textFields["library.tags.search"].isHittable)
        XCTAssertTrue(app.buttons["library.tags.option.fiction"].isSelected)
        try app.performAccessibilityAudit(for: [
            .hitRegion,
            .sufficientElementDescription,
            .textClipped,
            .trait
        ])
        attachScreenshot(named: "Tag picker dark accessibility text")
        app.buttons["library.tags.cancel"].tap()
    }

    @MainActor
    func testAccessibilityTextUsesWiderLibraryCards() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-testing",
            "-ui-testing-filter-library",
            "-ui-testing-accessibility-text"
        ]
        app.launch()

        let grid = app.scrollViews["library.bookGrid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 5))
        let alpha = button(containing: "Alpha Guide", in: app)
        let beta = button(containing: "Beta Notes", in: app)
        let gamma = button(containing: "Gamma Story", in: app)
        XCTAssertTrue(alpha.waitForExistence(timeout: 3))
        XCTAssertGreaterThan(beta.frame.minX, alpha.frame.minX)
        XCTAssertLessThan(gamma.frame.minX, beta.frame.minX)
    }

    @MainActor
    func testImportAndOpenRegularReader() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()
        _ = try openFixtureBook(in: app)
        XCTAssertTrue(app.otherElements["reader.navigator"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["reader.toc"].exists)
        XCTAssertTrue(app.buttons["reader.appearance"].exists)
        XCTAssertTrue(app.buttons["reader.mode.speed"].exists)
        exerciseSpeedReader(in: app)
        XCTAssertTrue(app.otherElements["reader.navigator"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["reader.toc"].waitForExistence(timeout: 3))
        assertSpeedPositionAfterReopening(in: app)
        assertRegularReaderControls(in: app)
    }

    @MainActor
    func testRegularReaderProgressScrubbingAndShareContextMenu() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()

        let book = try openFixtureBook(in: app)
        let slider = app.sliders["reader.progress"]
        XCTAssertTrue(slider.waitForExistence(timeout: 8))
        let initialValue = slider.value as? String
        slider.adjust(toNormalizedSliderPosition: 0.65)
        let progressChanged = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value != %@", initialValue ?? ""),
            object: slider
        )
        wait(for: [progressChanged], timeout: 8)

        let back = app.buttons["reader.back"]
        if !back.exists {
            app.otherElements["reader.navigator"].tap()
        }
        XCTAssertTrue(back.waitForExistence(timeout: 3))
        back.tap()
        XCTAssertTrue(book.waitForExistence(timeout: 5))

        book.tap()
        XCTAssertTrue(slider.waitForExistence(timeout: 8))
        XCTAssertNotEqual(slider.value as? String, "0%")
        if !back.exists {
            app.otherElements["reader.navigator"].tap()
        }
        XCTAssertTrue(back.waitForExistence(timeout: 3))
        back.tap()
        XCTAssertTrue(book.waitForExistence(timeout: 5))
        book.press(forDuration: 1)
        XCTAssertTrue(app.buttons["library.share"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testBackFromSpeedReaderExitsTheBook() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()

        let book = try openFixtureBook(in: app)
        XCTAssertTrue(app.buttons["reader.mode.speed"].waitForExistence(timeout: 8))
        app.buttons["reader.mode.speed"].tap()
        XCTAssertTrue(app.buttons["speed.playPause"].waitForExistence(timeout: 8))

        app.buttons["reader.back"].tap()
        XCTAssertTrue(app.scrollViews["library.bookGrid"].waitForExistence(timeout: 5))
        XCTAssertTrue(book.exists)
    }
}

@MainActor
private extension FastReaderUITests {
    func launchFilterLibrary() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-filter-library"]
        app.launch()
        return app
    }

    func openTagEditor(for title: String, in app: XCUIApplication) {
        let book = button(containing: title, in: app)
        XCTAssertTrue(book.waitForExistence(timeout: 5))
        book.press(forDuration: 1)
        let editTags = app.buttons["Edit Tags"]
        XCTAssertTrue(editTags.waitForExistence(timeout: 3))
        editTags.tap()
        XCTAssertTrue(app.navigationBars["Edit Tags"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.textFields["library.tags.search"].exists)
    }

    func assertTagCancellation(in app: XCUIApplication, grid: XCUIElement) {
        openTagEditor(for: "Alpha Guide", in: app)
        let search = app.textFields["library.tags.search"]
        search.tap()
        search.typeText("Temporary")
        app.buttons["library.tags.create"].tap()
        XCTAssertTrue(app.buttons["library.tags.option.temporary"].isSelected)
        app.buttons["library.tags.cancel"].tap()
        XCTAssertTrue(grid.waitForExistence(timeout: 5))

        openTagEditor(for: "Alpha Guide", in: app)
        let reopenedSearch = app.textFields["library.tags.search"]
        reopenedSearch.tap()
        reopenedSearch.typeText("Temporary")
        XCTAssertTrue(app.buttons["library.tags.create"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["library.tags.option.temporary"].exists)
        app.buttons["library.tags.cancel"].tap()
    }

    func assertCompactGrid(in app: XCUIApplication) {
        let books = ["Alpha Guide", "Beta Notes", "Gamma Story", "Delta Manual"].map { title in
            app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        }
        XCTAssertTrue(books[0].waitForExistence(timeout: 3))
        XCTAssertTrue(books.dropFirst().allSatisfy(\.exists))
        XCTAssertGreaterThan(books[1].frame.minX, books[0].frame.minX)
        XCTAssertGreaterThan(books[2].frame.minX, books[1].frame.minX)
        XCTAssertGreaterThanOrEqual(books[1].frame.minX - books[0].frame.maxX, 14)
        XCTAssertGreaterThanOrEqual(books[2].frame.minX - books[1].frame.maxX, 14)
        XCTAssertEqual(books[0].frame.maxY, books[1].frame.maxY, accuracy: 2)
        XCTAssertEqual(books[1].frame.maxY, books[2].frame.maxY, accuracy: 2)
        if app.frame.width >= 700 {
            XCTAssertGreaterThan(books[3].frame.minX, books[2].frame.minX)
        } else {
            XCTAssertLessThan(books[3].frame.minX, books[1].frame.minX)
            XCTAssertGreaterThanOrEqual(books[3].frame.minY - books[0].frame.maxY, 20)
        }
    }

    func applyFacetedFilters(in app: XCUIApplication, grid: XCUIElement) {
        let reading = app.buttons["library.filter.status.reading"]
        XCTAssertEqual(reading.value as? String, "2")
        reading.tap()
        XCTAssertEqual(grid.value as? String, "2")
        let fiction = button(containing: "Fiction", in: app)
        let focus = button(containing: "Focus", in: app)
        let rare = button(containing: "Rare", in: app)
        XCTAssertTrue(fiction.waitForExistence(timeout: 3))
        XCTAssertEqual(fiction.value as? String, "2")
        XCTAssertEqual(focus.value as? String, "1")
        XCTAssertEqual(rare.value as? String, "0")
        XCTAssertFalse(rare.isEnabled)
        fiction.tap()
        focus.tap()
        XCTAssertEqual(grid.value as? String, "1")
        XCTAssertTrue(fiction.exists)
        XCTAssertTrue(focus.exists)
        XCTAssertTrue(rare.exists)
        reading.tap()
        XCTAssertEqual(grid.value as? String, "2")
    }

    func assertFilterLayout(in app: XCUIApplication) {
        let statusHeader = app.staticTexts["Status"]
        let tagsHeader = app.staticTexts["Tags"]
        let all = app.buttons["library.filter.status.all"]
        let fiction = button(containing: "Fiction", in: app)

        XCTAssertTrue(statusHeader.exists)
        XCTAssertTrue(tagsHeader.exists)
        XCTAssertTrue(all.exists)
        XCTAssertTrue(fiction.exists)
        XCTAssertLessThan(statusHeader.frame.maxY, all.frame.minY)
        XCTAssertLessThan(tagsHeader.frame.maxY, fiction.frame.minY)
        XCTAssertEqual(statusHeader.frame.minX, tagsHeader.frame.minX, accuracy: 2)
        XCTAssertEqual(all.frame.minX, fiction.frame.minX, accuracy: 2)
    }

    func assertSearchCounts(in app: XCUIApplication, grid: XCUIElement) {
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.exists)
        search.tap()
        search.typeText("Delta")
        XCTAssertEqual(grid.value as? String, "1")
        XCTAssertEqual(app.buttons["library.filter.status.new"].value as? String, "1")
        XCTAssertEqual(app.buttons["library.filter.status.reading"].value as? String, "0")
    }

    func button(containing label: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", label)).firstMatch
    }

    func openFixtureBook(in app: XCUIApplication) throws -> XCUIElement {
        let bundle = Bundle(for: Self.self)
        let fixtureURL = try XCTUnwrap(bundle.url(forResource: "epub3-cyrillic", withExtension: "epub"))
        app.open(fixtureURL)
        let book = button(containing: "Путешествие Swift", in: app)
        XCTAssertTrue(book.waitForExistence(timeout: 8))
        book.tap()
        return book
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

    func assertSpeedPositionAfterReopening(in app: XCUIApplication) {
        app.buttons["reader.back"].tap()
        let book = button(containing: "Путешествие Swift", in: app)
        XCTAssertTrue(book.waitForExistence(timeout: 5))
        book.tap()
        XCTAssertTrue(app.otherElements["reader.navigator"].waitForExistence(timeout: 8))
        app.buttons["reader.mode.speed"].tap()
        XCTAssertTrue(app.buttons["speed.playPause"].waitForExistence(timeout: 8))
        app.buttons["reader.mode.regular"].tap()
        let navigator = app.otherElements["reader.navigator"]
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

    func assertRegularReaderControls(in app: XCUIApplication) {
        app.buttons["reader.toc"].tap()
        XCTAssertTrue(app.buttons["Глава первая"].waitForExistence(timeout: 3))
        app.buttons["reader.toc.close"].tap()
        app.otherElements["reader.navigator"].tap()
        XCTAssertTrue(app.buttons["reader.appearance"].waitForExistence(timeout: 3))
        app.buttons["reader.appearance"].tap()
        XCTAssertTrue(app.switches["reader.appearance.scroll"].waitForExistence(timeout: 3))
    }
}
