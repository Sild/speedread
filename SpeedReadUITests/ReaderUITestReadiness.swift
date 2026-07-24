import XCTest

@MainActor
extension XCTestCase {
    func requireExistence(
        _ element: XCUIElement,
        timeout: TimeInterval,
        message: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> XCUIElement {
        try XCTUnwrap(
            element.waitForExistence(timeout: timeout) ? element : nil,
            message ?? "Expected \(element) to exist within \(timeout) seconds",
            file: file,
            line: line
        )
    }

    func requireReaderControl(
        _ identifier: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 8,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> XCUIElement {
        _ = try requireExistence(
            app.otherElements["reader.navigator"],
            timeout: timeout,
            message: "Reader navigator did not become ready",
            file: file,
            line: line
        )
        let control = app.buttons[identifier]
        let readerCenter = app.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        )

        if control.exists, control.isHittable {
            readerCenter.tap()
            _ = waitForHittableState(false, of: control, timeout: 2)
        }

        for _ in 0 ..< 3 {
            readerCenter.tap()
            if waitForHittableState(true, of: control, timeout: 2) {
                return control
            }
        }

        return try XCTUnwrap(
            nil as XCUIElement?,
            "Reader control \(identifier) did not become visible and hittable",
            file: file,
            line: line
        )
    }

    private func waitForHittableState(
        _ expectedState: Bool,
        of element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let isHittable = element.exists && element.isHittable
            if isHittable == expectedState {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline
        return (element.exists && element.isHittable) == expectedState
    }
}
