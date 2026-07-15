@testable import FastReader
import Foundation
import Testing
import UIKit

private final class ReaderModeBundleToken {}

@Suite("Reader mode continuity")
@MainActor
struct ReaderModeContinuityTests {
    private static let epubContentHash = "long-epub-fixture"
    private static let pdfContentHash = "mode-round-trip"

    @Test("Settled EPUB navigator locator preserves the exact speed word")
    func settledEPUBLocatorModeRoundTrip() async throws {
        let fixtureURL = try fixture(named: "long-chapter", extension: "epub")
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileStore = try ApplicationSupportBookFileStore(rootURL: root)
        let service = ReadiumPublicationService()
        let activeToken = try await laterEPUBToken(
            service: service,
            fileStore: fileStore,
            fixtureURL: fixtureURL
        )
        let initialPosition = readingPosition(for: activeToken)
        let regularSession = try await service.makeRegularReaderSession(
            at: fixtureURL,
            initialLocatorJSON: activeToken.locatorJSON,
            highlightLocatorJSON: activeToken.locatorJSON,
            preferences: RegularReaderPreferences()
        )
        let window = mount(regularSession)
        defer { window.isHidden = true }
        let settled = try await settledSnapshot(from: regularSession)
        let preserved = updated(initialPosition, from: settled)

        #expect(!locatorHasCSSSelector(settled.locatorJSON))
        #expect(settled.preservesSpeedCursor)
        #expect(preserved.locatorJSON == activeToken.locatorJSON)
        #expect(preserved.speedElementID == activeToken.elementID)
        #expect(preserved.speedTokenOffset == activeToken.offset)
        let resumedProvider = try await service.makeSpeedContentProvider(
            at: fixtureURL,
            contentHash: Self.epubContentHash,
            fileStore: fileStore
        )
        _ = try await resumedPosition(
            activeToken,
            from: preserved,
            provider: resumedProvider
        )
        try await assertNavigationInvalidates(
            initialPosition,
            in: regularSession
        )
    }

    @Test("PDF exact speed word survives repeated regular mode round trips")
    func pdfSpeedWordModeRoundTrip() async throws {
        let fixtureURL = try fixture(named: "pdf-metadata-outline", extension: "pdf")
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileStore = try ApplicationSupportBookFileStore(rootURL: root)
        let service = ReadiumPublicationService()
        let (activeToken, baseLocatorJSON) = try await laterPDFToken(
            service: service,
            fileStore: fileStore,
            fixtureURL: fixtureURL
        )
        var position = readingPosition(for: activeToken)

        for _ in 0 ..< 2 {
            let exactResumeLocator = position.locatorJSON
            let regularSession = try await service.makeRegularReaderSession(
                at: fixtureURL,
                initialLocatorJSON: exactResumeLocator,
                highlightLocatorJSON: nil,
                preferences: RegularReaderPreferences(scroll: true)
            )
            #expect(regularSession.viewController.view != nil)
            let regularSnapshot = try #require(regularSession.currentPosition())
            position = position.updatingFromRegularReader(
                locatorJSON: baseLocatorJSON,
                totalProgression: regularSnapshot.totalProgression,
                at: .now
            )
            #expect(position.locatorJSON == exactResumeLocator)
            let resumedProvider = try await service.makeSpeedContentProvider(
                at: fixtureURL,
                contentHash: Self.pdfContentHash,
                fileStore: fileStore
            )
            position = try await resumedPosition(
                activeToken,
                from: position,
                provider: resumedProvider
            )
        }
    }

    private func laterPDFToken(
        service: ReadiumPublicationService,
        fileStore: ApplicationSupportBookFileStore,
        fixtureURL: URL
    ) async throws -> (token: SpeedToken, baseLocatorJSON: String) {
        let cacheEntry = PDFPageCacheFixture(
            version: PDFPageTextExtractor.cacheVersion,
            pageIndex: 0,
            result: .text(
                PDFPageText(
                    text: String(repeating: "leading ", count: 12600) + "target active ending",
                    source: .embedded
                )
            )
        )
        try await fileStore.writeDerivedData(
            JSONEncoder().encode(cacheEntry),
            relativePath: "\(Self.pdfContentHash)/pdf-text-v2/page-0.json"
        )
        let provider = try await service.makeSpeedContentProvider(
            at: fixtureURL,
            contentHash: Self.pdfContentHash,
            fileStore: fileStore
        )
        _ = try #require(try await provider.start(at: nil, preferredElementID: nil))
        let secondSegment = try #require(try await provider.next())
        let token = try #require(
            SpeedTokenizer.tokenize(secondSegment).first(where: { $0.text == "active" })
        )
        return (token, secondSegment.locatorJSON)
    }

    private func laterEPUBToken(
        service: ReadiumPublicationService,
        fileStore: ApplicationSupportBookFileStore,
        fixtureURL: URL
    ) async throws -> SpeedToken {
        let provider = try await service.makeSpeedContentProvider(
            at: fixtureURL,
            contentHash: Self.epubContentHash,
            fileStore: fileStore
        )
        _ = try #require(try await provider.start(at: nil, preferredElementID: nil))
        let second = try #require(try await provider.next())
        let segment = try #require(second.segments.dropFirst(4).first)
        let token = try #require(
            SpeedTokenizer.tokenize(SpeedContentElement(id: segment.id, segments: [segment]))
                .dropFirst(8).first
        )
        #expect(token.text == "visible")
        return token
    }

    private func readingPosition(for token: SpeedToken) -> ReadingPosition {
        ReadingPosition(
            locatorJSON: token.locatorJSON,
            totalProgression: token.totalProgression,
            speedElementID: token.elementID,
            speedTokenOffset: token.offset,
            updatedAt: .now
        )
    }

    private func mount(_ session: RegularReaderSession) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = session.viewController
        window.makeKeyAndVisible()
        session.viewController.view.setNeedsLayout()
        session.viewController.view.layoutIfNeeded()
        return window
    }

    private func settledSnapshot(
        from session: RegularReaderSession
    ) async throws -> ReaderPositionSnapshot {
        for _ in 0 ..< 100 {
            if let snapshot = session.currentPosition(), !locatorHasCSSSelector(snapshot.locatorJSON) {
                return snapshot
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        return try #require(session.currentPosition())
    }

    private func updated(
        _ position: ReadingPosition,
        from snapshot: ReaderPositionSnapshot
    ) -> ReadingPosition {
        position.updatingFromRegularReader(
            locatorJSON: snapshot.locatorJSON,
            totalProgression: snapshot.totalProgression,
            preserveSpeedCursor: snapshot.preservesSpeedCursor,
            at: .now
        )
    }

    private func resumedPosition(
        _ activeToken: SpeedToken,
        from position: ReadingPosition,
        provider: any SpeedContentProviding
    ) async throws -> ReadingPosition {
        let session = SpeedReaderSession(
            provider: provider,
            settings: SpeedReaderSettings()
        )
        try await session.start(from: position)
        #expect(session.currentToken?.id == activeToken.id)
        #expect(session.currentToken?.text == activeToken.text)
        let snapshot = try #require(session.currentPosition())
        return ReadingPosition(
            locatorJSON: snapshot.locatorJSON,
            totalProgression: snapshot.totalProgression,
            speedElementID: snapshot.elementID,
            speedTokenOffset: snapshot.tokenOffset,
            updatedAt: .now
        )
    }

    private func assertNavigationInvalidates(
        _ position: ReadingPosition,
        in session: RegularReaderSession
    ) async throws {
        var snapshot: ReaderPositionSnapshot?
        session.onPositionChange = { snapshot = $0 }
        #expect(await session.seek(toTotalProgression: 0.25))
        let movedSnapshot = try #require(snapshot)
        #expect(!movedSnapshot.preservesSpeedCursor)
        let movedPosition = updated(position, from: movedSnapshot)
        #expect(movedPosition.speedElementID == nil)
        #expect(movedPosition.speedTokenOffset == nil)
    }

    private func locatorHasCSSSelector(_ locatorJSON: String) -> Bool {
        guard let data = locatorJSON.data(using: .utf8),
              let locator = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let locations = locator["locations"] as? [String: Any]
        else {
            return false
        }
        return locations["cssSelector"] is String
    }

    private func fixture(named name: String, extension fileExtension: String) throws -> URL {
        let bundle = Bundle(for: ReaderModeBundleToken.self)
        guard let url = bundle.url(forResource: name, withExtension: fileExtension) else {
            throw ReaderModeFixtureError.missing(name)
        }
        return url
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}

private enum ReaderModeFixtureError: Error {
    case missing(String)
}

private struct PDFPageCacheFixture: Codable {
    let version: Int
    let pageIndex: Int
    let result: PDFPageCacheFixtureResult
}

private enum PDFPageCacheFixtureResult: Codable {
    case text(PDFPageText)
}
