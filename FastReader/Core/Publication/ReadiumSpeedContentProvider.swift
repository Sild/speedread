import Foundation
@preconcurrency import ReadiumShared

@MainActor
final class ReadiumSpeedContentProvider: SpeedContentProviding {
    private static let maximumChunkCharacters = 100_000
    private static let maximumElementsPerChunk = 32
    private static let maximumCachedChunks = 3

    private let publication: Publication
    private var iterator: ContentIterator?
    private var pendingTextElement: RawTextElement?
    private var cachedChunks: [SpeedContentElement] = []
    private var cachedChunkIndex = 0

    init(publication: Publication) {
        self.publication = publication
    }

    func start(at locatorJSON: String?) async throws -> SpeedContentElement? {
        let locator: Locator? = if let locatorJSON {
            try Locator(jsonString: locatorJSON)
        } else {
            nil
        }
        return try await restart(at: locator)
    }

    func next() async throws -> SpeedContentElement? {
        guard let iterator else {
            throw SpeedContentError.unavailable
        }
        if cachedChunkIndex + 1 < cachedChunks.count {
            cachedChunkIndex += 1
            return cachedChunks[cachedChunkIndex]
        }
        guard let chunk = try await nextTextChunk(from: iterator) else {
            return nil
        }
        cachedChunks.append(chunk)
        cachedChunkIndex = cachedChunks.count - 1
        if cachedChunks.count > Self.maximumCachedChunks {
            cachedChunks.removeFirst()
            cachedChunkIndex -= 1
        }
        return chunk
    }

    func previous() async throws -> SpeedContentElement? {
        guard iterator != nil else {
            throw SpeedContentError.unavailable
        }
        guard cachedChunkIndex > 0 else {
            return nil
        }
        cachedChunkIndex -= 1
        return cachedChunks[cachedChunkIndex]
    }

    func seek(toTotalProgression progression: Double) async throws -> SpeedContentElement? {
        let requested = min(max(progression, 0), 1)
        let positions: [Locator]
        switch await publication.positions() {
        case let .success(value):
            positions = value
        case .failure:
            throw SpeedContentError.extractionFailed
        }
        guard let closest = positions.min(by: {
            abs(($0.locations.totalProgression ?? 0) - requested)
                < abs(($1.locations.totalProgression ?? 0) - requested)
        }) else {
            throw SpeedContentError.unavailable
        }
        return try await restart(at: closest)
    }

    private func restart(at locator: Locator?) async throws -> SpeedContentElement? {
        guard let content = publication.content(from: locator) else {
            throw SpeedContentError.unavailable
        }
        let iterator = content.iterator()
        self.iterator = iterator
        pendingTextElement = nil
        cachedChunks = []
        cachedChunkIndex = 0
        guard let first = try await nextTextChunk(from: iterator) else {
            return nil
        }
        cachedChunks = [first]
        return first
    }

    private func nextTextChunk(from iterator: ContentIterator) async throws -> SpeedContentElement? {
        var elements: [RawTextElement] = []
        var characterCount = 0

        while elements.count < Self.maximumElementsPerChunk {
            guard let element = try await nextRawTextElement(from: iterator) else {
                break
            }
            if element.text.count > Self.maximumChunkCharacters {
                guard elements.isEmpty else {
                    pendingTextElement = element
                    break
                }
                let split = splitOversized(element)
                elements.append(split.head)
                pendingTextElement = split.tail
                break
            }
            let separatorCount = elements.isEmpty ? 0 : 2
            let nextCharacterCount = characterCount + separatorCount + element.text.count
            if !elements.isEmpty, nextCharacterCount > Self.maximumChunkCharacters {
                pendingTextElement = element
                break
            }
            elements.append(element)
            characterCount += separatorCount + element.text.count
        }

        guard let first = elements.first else {
            return nil
        }
        return SpeedContentElement(
            id: first.id,
            segments: elements.map {
                SpeedContentSegment(
                    id: $0.id,
                    text: $0.text,
                    locatorJSON: $0.locatorJSON,
                    totalProgression: $0.totalProgression,
                    tokenOffsetBase: $0.tokenOffsetBase
                )
            }
        )
    }

    private func nextRawTextElement(from iterator: ContentIterator) async throws -> RawTextElement? {
        if let pendingTextElement {
            self.pendingTextElement = nil
            return pendingTextElement
        }
        for _ in 0 ..< 1024 {
            let element = try await iterator.next()
            guard let element else {
                return nil
            }
            guard let text = (element as? TextualContentElement)?.text?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !text.isEmpty
            else {
                continue
            }
            guard let locatorJSON = element.locator.jsonString else {
                throw SpeedContentError.invalidLocator
            }
            return RawTextElement(
                id: Self.elementID(for: element.locator, fallback: locatorJSON),
                text: text,
                locatorJSON: locatorJSON,
                totalProgression: min(max(element.locator.locations.totalProgression ?? 0, 0), 1),
                tokenOffsetBase: 0
            )
        }
        throw SpeedContentError.extractionFailed
    }

    private func splitOversized(_ element: RawTextElement) -> (
        head: RawTextElement,
        tail: RawTextElement?
    ) {
        let candidate = element.text.prefix(Self.maximumChunkCharacters)
        let splitIndex = candidate.lastIndex(where: \.isWhitespace).map {
            element.text.index(after: $0)
        } ?? candidate.endIndex
        let headText = String(element.text[..<splitIndex])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let tailText = String(element.text[splitIndex...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let head = RawTextElement(
            id: element.id,
            text: headText,
            locatorJSON: element.locatorJSON,
            totalProgression: element.totalProgression,
            tokenOffsetBase: element.tokenOffsetBase
        )
        let tail = tailText.isEmpty ? nil : RawTextElement(
            id: element.id,
            text: tailText,
            locatorJSON: element.locatorJSON,
            totalProgression: element.totalProgression,
            tokenOffsetBase: element.tokenOffsetBase + headText.split(
                whereSeparator: \Character.isWhitespace
            ).count
        )
        return (head, tail)
    }

    private static func elementID(for locator: Locator, fallback: String) -> String {
        guard let cssSelector = locator.locations.cssSelector, !cssSelector.isEmpty else {
            return fallback
        }
        return "\(locator.href.string)|\(cssSelector)"
    }

    private struct RawTextElement {
        let id: String
        let text: String
        let locatorJSON: String
        let totalProgression: Double
        let tokenOffsetBase: Int
    }
}
