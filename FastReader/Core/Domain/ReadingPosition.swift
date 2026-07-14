import Foundation

struct ReadingPosition: Codable, Equatable, Sendable {
    let locatorJSON: String
    let totalProgression: Double
    let speedElementID: String?
    let speedTokenOffset: Int?
    let updatedAt: Date

    var clampedProgression: Double {
        min(max(totalProgression, 0), 1)
    }

    func updatingFromRegularReader(
        locatorJSON newLocatorJSON: String,
        totalProgression newTotalProgression: Double,
        at date: Date
    ) -> ReadingPosition {
        let preservesSpeedCursor = speedElementID != nil
            && speedTokenOffset != nil
            && ReadingLocatorContinuity.refersToSameContent(
                locatorJSON,
                newLocatorJSON
            )
        return ReadingPosition(
            locatorJSON: newLocatorJSON,
            totalProgression: newTotalProgression,
            speedElementID: preservesSpeedCursor ? speedElementID : nil,
            speedTokenOffset: preservesSpeedCursor ? speedTokenOffset : nil,
            updatedAt: date
        )
    }
}

private enum ReadingLocatorContinuity {
    private static let progressionTolerance = 0.000_001

    static func refersToSameContent(_ firstJSON: String, _ secondJSON: String) -> Bool {
        guard let first = LocatorKey(json: firstJSON),
              let second = LocatorKey(json: secondJSON)
        else {
            return firstJSON == secondJSON
        }
        guard first.normalizedHref == second.normalizedHref else {
            return false
        }
        let selectorsMatch = first.cssSelector != nil
            && first.cssSelector == second.cssSelector
        if selectorsMatch {
            return true
        }
        let isNavigatorNormalization = first.cssSelector != nil
            && second.cssSelector == nil
            && numbersMatch(first.position, second.position)
            && second.progression == 0
            && second.totalProgression == 0
        if isNavigatorNormalization {
            return true
        }
        guard numbersMatch(first.position, second.position),
              numbersMatch(first.progression, second.progression),
              numbersMatch(first.totalProgression, second.totalProgression)
        else {
            return false
        }
        return first.position != nil
            || first.progression != nil
            || first.totalProgression != nil
    }

    private static func numbersMatch(_ first: Double?, _ second: Double?) -> Bool {
        switch (first, second) {
        case let (.some(first), .some(second)):
            abs(first - second) <= progressionTolerance
        case (.none, .none):
            true
        case (.some, .none), (.none, .some):
            false
        }
    }

    private struct LocatorKey {
        let href: String
        let cssSelector: String?
        let position: Double?
        let progression: Double?
        let totalProgression: Double?

        var normalizedHref: String {
            href.replacingOccurrences(of: "\\", with: "/")
        }

        init?(json: String) {
            guard let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let href = object["href"] as? String,
                  let locations = object["locations"] as? [String: Any]
            else {
                return nil
            }
            self.href = href
            cssSelector = locations["cssSelector"] as? String
            position = (locations["position"] as? NSNumber)?.doubleValue
            progression = (locations["progression"] as? NSNumber)?.doubleValue
            totalProgression = (locations["totalProgression"] as? NSNumber)?.doubleValue
        }
    }
}

enum PublicationLayout: String, Codable, Sendable {
    case reflowable
    case fixed
}
