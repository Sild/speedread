@testable import FastReader
import Foundation
import Testing

@Suite("Speed reader session")
@MainActor
struct SpeedReaderSessionTests {
    @Test("Regular updates preserve only a matching speed cursor")
    func regularPositionUpdate() {
        let speedPosition = ReadingPosition(
            locatorJSON: Self.locator(selector: "#paragraph-two", progression: 0.3),
            totalProgression: 0.3,
            speedElementID: "chapter.xhtml|#paragraph-two",
            speedTokenOffset: 8,
            updatedAt: Date(timeIntervalSince1970: 1)
        )

        let unchanged = speedPosition.updatingFromRegularReader(
            locatorJSON: Self.locator(selector: "#paragraph-two", progression: 0.31),
            totalProgression: 0.31,
            at: Date(timeIntervalSince1970: 2)
        )
        #expect(unchanged.speedElementID == speedPosition.speedElementID)
        #expect(unchanged.speedTokenOffset == speedPosition.speedTokenOffset)

        let normalized = unchanged.updatingFromRegularReader(
            locatorJSON: Self.locator(selector: "#page-heading", progression: 0.31),
            totalProgression: 0.31,
            at: Date(timeIntervalSince1970: 3)
        )
        #expect(normalized.speedElementID == speedPosition.speedElementID)
        #expect(normalized.speedTokenOffset == speedPosition.speedTokenOffset)

        let navigatorNormalized = speedPosition.updatingFromRegularReader(
            locatorJSON: Self.resourceStartLocator,
            totalProgression: 0,
            at: Date(timeIntervalSince1970: 4)
        )
        #expect(navigatorNormalized.speedElementID == speedPosition.speedElementID)
        #expect(navigatorNormalized.speedTokenOffset == speedPosition.speedTokenOffset)

        let paged = navigatorNormalized.updatingFromRegularReader(
            locatorJSON: Self.resourcePageLocator,
            totalProgression: 0.4,
            at: Date(timeIntervalSince1970: 5)
        )
        #expect(paged.speedElementID == nil)
        #expect(paged.speedTokenOffset == nil)

        let navigated = normalized.updatingFromRegularReader(
            locatorJSON: Self.locator(selector: "#paragraph-three", progression: 0.4),
            totalProgression: 0.4,
            at: Date(timeIntervalSince1970: 6)
        )
        #expect(navigated.speedElementID == nil)
        #expect(navigated.speedTokenOffset == nil)
    }

    @Test("Session restores an exact token offset across extracted paragraphs")
    func resumeAcrossSegments() async throws {
        let element = SpeedContentElement(
            id: "chunk",
            segments: [
                SpeedContentSegment(
                    id: "paragraph-one",
                    text: "alpha beta",
                    locatorJSON: "first",
                    totalProgression: 0.2
                ),
                SpeedContentSegment(
                    id: "paragraph-two",
                    text: "gamma delta",
                    locatorJSON: "second",
                    totalProgression: 0.3,
                    tokenOffsetBase: 7
                )
            ]
        )
        let session = SpeedReaderSession(
            provider: ArraySpeedContentProvider(elements: [element]),
            settings: SpeedReaderSettings()
        )
        let position = ReadingPosition(
            locatorJSON: "second",
            totalProgression: 0.3,
            speedElementID: "paragraph-two",
            speedTokenOffset: 8,
            updatedAt: .now
        )

        try await session.start(from: position)

        #expect(session.currentToken?.text == "delta")
        #expect(session.currentToken?.offset == 8)
    }

    @Test("Session resumes token offset and navigates across elements")
    func resumeAndNavigate() async throws {
        let provider = ArraySpeedContentProvider(elements: [
            Self.element(id: "one", text: "one two three four five six seven", progress: 0.2),
            Self.element(id: "two", text: "восемь девять", progress: 0.5)
        ])
        let session = SpeedReaderSession(
            provider: provider,
            settings: SpeedReaderSettings()
        )
        let position = ReadingPosition(
            locatorJSON: "one",
            totalProgression: 0.2,
            speedElementID: "one",
            speedTokenOffset: 3,
            updatedAt: .now
        )

        try await session.start(from: position)

        #expect(session.currentToken?.text == "four")
        #expect(session.previousContext == ["one", "two", "three"])
        #expect(session.nextContext == ["five", "six", "seven"])

        await session.moveNext()
        await session.moveNext()
        await session.moveNext()
        await session.moveNext()
        #expect(session.currentToken?.text == "восемь")

        await session.movePrevious()
        #expect(session.currentToken?.text == "seven")
    }

    @Test("Session owns playback cancellation and reports publication end")
    func lifecycleAndCompletion() async throws {
        let provider = ArraySpeedContentProvider(elements: [
            Self.element(id: "only", text: "done", progress: 0.9)
        ])
        let session = SpeedReaderSession(
            provider: provider,
            settings: SpeedReaderSettings(wordsPerMinute: 1000, adaptivePauses: false)
        )
        var lastSnapshot: SpeedPositionSnapshot?
        session.onPositionChange = { lastSnapshot = $0 }
        try await session.start(from: ReadingPosition?.none)

        session.play()
        #expect(session.isPlaying)
        session.stop()
        #expect(!session.isPlaying)
        try await Task.sleep(for: .milliseconds(100))
        #expect(session.currentToken?.text == "done")

        await session.moveNext()
        #expect(session.progress == 1)
        #expect(lastSnapshot?.reachedPublicationEnd == true)
    }

    @Test("Playing session deinitializes without retaining itself")
    func playbackDeinitialization() async throws {
        let provider = ArraySpeedContentProvider(elements: [
            Self.element(id: "only", text: "one two", progress: 0.2)
        ])
        var session: SpeedReaderSession? = SpeedReaderSession(
            provider: provider,
            settings: SpeedReaderSettings(wordsPerMinute: 100, adaptivePauses: false)
        )
        weak let weakSession = session
        try await session?.start(from: ReadingPosition?.none)
        session?.play()

        session = nil
        try await Task.sleep(for: .milliseconds(20))

        #expect(weakSession == nil)
    }

    private static func element(
        id: String,
        text: String,
        progress: Double
    ) -> SpeedContentElement {
        SpeedContentElement(
            id: id,
            text: text,
            locatorJSON: id,
            totalProgression: progress
        )
    }

    private static func locator(selector: String, progression: Double) -> String {
        """
        {"href":"EPUB\\\\chapter.xhtml","locations":{
          "cssSelector":"\(selector)","position":1,"totalProgression":\(progression)
        }}
        """
    }

    private static let resourceStartLocator = """
    {"href":"EPUB/chapter.xhtml","locations":{"position":1,"progression":0,"totalProgression":0}}
    """

    private static let resourcePageLocator = """
    {"href":"EPUB/chapter.xhtml","locations":{"position":1,"progression":0.4,"totalProgression":0.4}}
    """
}

@MainActor
private final class ArraySpeedContentProvider: SpeedContentProviding {
    private let elements: [SpeedContentElement]
    private var index = 0

    init(elements: [SpeedContentElement]) {
        self.elements = elements
    }

    func start(at locatorJSON: String?) async throws -> SpeedContentElement? {
        if let locatorJSON, let matchingIndex = elements.firstIndex(where: {
            $0.locatorJSON == locatorJSON
        }) {
            index = matchingIndex
        } else {
            index = 0
        }
        return elements.indices.contains(index) ? elements[index] : nil
    }

    func next() async throws -> SpeedContentElement? {
        let nextIndex = index + 1
        guard elements.indices.contains(nextIndex) else {
            return nil
        }
        index = nextIndex
        return elements[index]
    }

    func previous() async throws -> SpeedContentElement? {
        let previousIndex = index - 1
        guard elements.indices.contains(previousIndex) else {
            return nil
        }
        index = previousIndex
        return elements[index]
    }

    func seek(toTotalProgression progression: Double) async throws -> SpeedContentElement? {
        guard let closestIndex = elements.indices.min(by: {
            abs(elements[$0].totalProgression - progression)
                < abs(elements[$1].totalProgression - progression)
        }) else {
            return nil
        }
        index = closestIndex
        return elements[index]
    }
}
