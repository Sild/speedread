import Foundation
@preconcurrency import ReadiumShared

@MainActor
final class PDFSpeedContentProvider: SpeedContentProviding {
    private static let maximumSegmentCharacters = 100_000

    private let extractor: PDFPageTextExtractor
    private let pageLocators: [Locator]
    private var pageIndex = 0
    private var segmentIndex = 0
    private var segments: [String] = []
    private var prefetchTask: Task<Void, Never>?

    init(
        fileURL: URL,
        publication: Publication,
        contentHash: String,
        fileStore: any BookFileStore
    ) async throws {
        extractor = try PDFPageTextExtractor(
            fileURL: fileURL,
            contentHash: contentHash,
            fileStore: fileStore
        )
        switch await publication.positions() {
        case let .success(positions):
            pageLocators = positions.sorted {
                ($0.locations.position ?? 0) < ($1.locations.position ?? 0)
            }
        case .failure:
            throw SpeedContentError.extractionFailed
        }
        guard !pageLocators.isEmpty else {
            throw SpeedContentError.unavailable
        }
    }

    deinit {
        prefetchTask?.cancel()
    }

    func start(at locatorJSON: String?) async throws -> SpeedContentElement? {
        let targetPage: Int
        if let locatorJSON {
            guard let locator = try Locator(jsonString: locatorJSON) else {
                throw SpeedContentError.extractionFailed
            }
            targetPage = min(max((locator.locations.position ?? 1) - 1, 0), pageLocators.count - 1)
        } else {
            targetPage = 0
        }
        return try await load(page: targetPage, segment: 0)
    }

    func next() async throws -> SpeedContentElement? {
        if segmentIndex + 1 < segments.count {
            segmentIndex += 1
            return currentElement
        }
        guard pageIndex + 1 < pageLocators.count else {
            return nil
        }
        return try await load(page: pageIndex + 1, segment: 0)
    }

    func previous() async throws -> SpeedContentElement? {
        if segmentIndex > 0 {
            segmentIndex -= 1
            return currentElement
        }
        guard pageIndex > 0 else {
            return nil
        }
        let text = try await extractor.text(forPage: pageIndex - 1)
        let previousSegments = Self.split(text.text)
        guard !previousSegments.isEmpty else {
            throw SpeedContentError.unavailable
        }
        pageIndex -= 1
        segments = previousSegments
        segmentIndex = previousSegments.count - 1
        schedulePrefetch()
        return currentElement
    }

    func seek(toTotalProgression progression: Double) async throws -> SpeedContentElement? {
        let requested = min(max(progression, 0), 1)
        let target = pageLocators.enumerated().min { left, right in
            abs((left.element.locations.totalProgression ?? 0) - requested)
                < abs((right.element.locations.totalProgression ?? 0) - requested)
        }?.offset ?? 0
        return try await load(page: target, segment: 0)
    }

    private func load(page: Int, segment: Int) async throws -> SpeedContentElement? {
        prefetchTask?.cancel()
        let text = try await extractor.text(forPage: page)
        let loadedSegments = Self.split(text.text)
        guard loadedSegments.indices.contains(segment) else {
            throw SpeedContentError.unavailable
        }
        pageIndex = page
        segments = loadedSegments
        segmentIndex = segment
        schedulePrefetch()
        return currentElement
    }

    private var currentElement: SpeedContentElement? {
        guard segments.indices.contains(segmentIndex),
              pageLocators.indices.contains(pageIndex),
              let locatorJSON = pageLocators[pageIndex].jsonString
        else {
            return nil
        }
        return SpeedContentElement(
            id: "pdf-text-v\(PDFPageTextExtractor.cacheVersion):\(pageIndex + 1):\(segmentIndex)",
            text: segments[segmentIndex],
            locatorJSON: locatorJSON,
            totalProgression: min(
                max(pageLocators[pageIndex].locations.totalProgression ?? 0, 0),
                1
            )
        )
    }

    private func schedulePrefetch() {
        prefetchTask?.cancel()
        let extractor = extractor
        let previous = pageIndex - 1
        let next = pageIndex + 1
        let pageCount = pageLocators.count
        prefetchTask = Task {
            if previous >= 0 {
                await extractor.prepare(page: previous)
            }
            guard !Task.isCancelled, next < pageCount else {
                return
            }
            await extractor.prepare(page: next)
        }
    }

    static func split(_ text: String) -> [String] {
        var remaining = text[...]
        var result: [String] = []
        while !remaining.isEmpty {
            let candidate = remaining.prefix(maximumSegmentCharacters)
            let end = candidate.count == remaining.count
                ? candidate.endIndex
                : candidate.lastIndex(where: \.isWhitespace) ?? candidate.endIndex
            let segment = remaining[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            if !segment.isEmpty {
                result.append(segment)
            }
            remaining = remaining[end...].drop(while: \.isWhitespace)
        }
        return result
    }
}
