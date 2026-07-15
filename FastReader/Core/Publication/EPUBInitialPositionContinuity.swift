import Foundation
@preconcurrency import ReadiumShared

struct EPUBInitialPositionContinuity {
    private static let progressionTolerance = 0.000_001

    private let exactLocator: Locator
    private var settledLocator: Locator?
    private var wasInvalidated = false

    init?(exactLocator: Locator?) {
        guard let exactLocator,
              exactLocator.locations.cssSelector?.isEmpty == false
        else {
            return nil
        }
        self.exactLocator = exactLocator
    }

    mutating func preservesSpeedCursor(at locator: Locator) -> Bool {
        guard !wasInvalidated,
              Self.normalizedHREF(locator) == Self.normalizedHREF(exactLocator)
        else {
            wasInvalidated = true
            return false
        }
        if locator.locations.cssSelector == exactLocator.locations.cssSelector {
            return true
        }
        guard let settledLocator else {
            settledLocator = locator
            return true
        }
        guard Self.refersToSameSettledLocation(locator, settledLocator) else {
            wasInvalidated = true
            return false
        }
        return true
    }

    mutating func invalidate() {
        wasInvalidated = true
    }

    private static func refersToSameSettledLocation(
        _ first: Locator,
        _ second: Locator
    ) -> Bool {
        guard normalizedHREF(first) == normalizedHREF(second) else {
            return false
        }
        var comparedLocation = false
        for values in comparableLocations(first, second) {
            switch values {
            case let (.some(first), .some(second)):
                comparedLocation = true
                guard abs(first - second) <= progressionTolerance else {
                    return false
                }
            case (.none, .none):
                continue
            case (.some, .none), (.none, .some):
                return false
            }
        }
        return comparedLocation
    }

    private static func comparableLocations(
        _ first: Locator,
        _ second: Locator
    ) -> [(Double?, Double?)] {
        [
            (first.locations.position.map(Double.init), second.locations.position.map(Double.init)),
            (first.locations.progression, second.locations.progression),
            (first.locations.totalProgression, second.locations.totalProgression)
        ]
    }

    private static func normalizedHREF(_ locator: Locator) -> String {
        locator.href.string.replacingOccurrences(of: "\\", with: "/")
    }
}

extension RegularReaderSession {
    static func snapshot(
        from locator: Locator,
        reachedPublicationEnd: Bool = false,
        preservesSpeedCursor: Bool = false
    ) -> ReaderPositionSnapshot? {
        guard let locatorJSON = locator.jsonString else {
            return nil
        }
        let progression = reachedPublicationEnd
            ? 1
            : min(max(locator.locations.totalProgression ?? 0, 0), 1)
        return ReaderPositionSnapshot(
            locatorJSON: locatorJSON,
            totalProgression: progression,
            reachedPublicationEnd: reachedPublicationEnd,
            sectionTitle: locator.title,
            preservesSpeedCursor: preservesSpeedCursor
        )
    }
}
