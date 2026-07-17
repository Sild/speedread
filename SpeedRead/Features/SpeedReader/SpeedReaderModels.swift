struct SpeedContentElement: Equatable, Sendable {
    let id: String
    let segments: [SpeedContentSegment]

    init(
        id: String,
        text: String,
        locatorJSON: String,
        totalProgression: Double
    ) {
        self.id = id
        segments = [
            SpeedContentSegment(
                id: id,
                text: text,
                locatorJSON: locatorJSON,
                totalProgression: totalProgression
            )
        ]
    }

    init(id: String, segments: [SpeedContentSegment]) {
        self.id = id
        self.segments = segments
    }

    var text: String {
        segments.map(\.text).joined(separator: "\n\n")
    }

    var locatorJSON: String {
        segments.first?.locatorJSON ?? ""
    }

    var totalProgression: Double {
        segments.first?.totalProgression ?? 0
    }
}

struct SpeedContentSegment: Equatable, Sendable {
    let id: String
    let text: String
    let locatorJSON: String
    let totalProgression: Double
    var tokenOffsetBase = 0
}

struct SpeedToken: Identifiable, Equatable, Sendable {
    let elementID: String
    let offset: Int
    let text: String
    let prefix: String
    let focus: String
    let suffix: String
    let locatorJSON: String
    let totalProgression: Double
    let endsParagraph: Bool
    let wordGraphemeCount: Int

    var id: String {
        "\(elementID)#\(offset)"
    }
}

struct SpeedPositionSnapshot: Equatable, Sendable {
    let locatorJSON: String
    let totalProgression: Double
    let elementID: String
    let tokenOffset: Int
    let reachedPublicationEnd: Bool
}

struct SpeedReaderSettings: Equatable, Sendable {
    var wordsPerMinute = 300
    var adaptivePauses = true

    var normalizedWordsPerMinute: Int {
        let clamped = min(max(wordsPerMinute, 100), 1000)
        return Int((Double(clamped) / 25).rounded()) * 25
    }
}

enum SpeedContentError: Error, Equatable, Sendable {
    case invalidLocator
    case unavailable
    case extractionFailed
    case copyRestricted
    case lowConfidence(page: Int)
    case unsupportedText(page: Int)
    case ocrFailed(page: Int)
}

extension SpeedContentError {
    @MainActor
    var userMessage: String {
        switch self {
        case .copyRestricted:
            String(localized: "speed.unavailable.copyRestricted")
        case let .lowConfidence(page):
            String.localizedStringWithFormat(
                String(localized: "speed.unavailable.lowConfidence"),
                page
            )
        case let .unsupportedText(page):
            String.localizedStringWithFormat(
                String(localized: "speed.unavailable.unsupportedText"),
                page
            )
        case let .ocrFailed(page):
            String.localizedStringWithFormat(
                String(localized: "speed.unavailable.ocrFailed"),
                page
            )
        case .invalidLocator, .unavailable, .extractionFailed:
            String(localized: "speed.unavailable.message")
        }
    }
}
