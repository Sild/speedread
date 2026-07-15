@testable import FastReader
import Foundation
import Testing

private final class TestBundleToken {}

private enum FixtureError: Error {
    case missing(String)
}

@Suite("EPUB import")
@MainActor
struct ImportTests {
    @Test("Readium extracts Cyrillic EPUB metadata")
    func readiumMetadata() async throws {
        let url = try fixture(named: "epub3-cyrillic")
        let metadata = try await ReadiumPublicationService().inspectPublication(at: url)

        #expect(metadata.title == "Путешествие Swift")
        #expect(metadata.authorsDisplay == "Иван Петров")
        #expect(metadata.mediaType == "application/epub+zip")
        #expect(metadata.layout == .reflowable)
        #expect(metadata.coverPNGData?.isEmpty == false)
    }

    @Test("Readium creates a regular reader session with table of contents")
    func regularReaderSession() async throws {
        let service = ReadiumPublicationService()
        let locatorJSON =
            """
            {"href":"chapter.xhtml","type":"application/xhtml+xml",
            "locations":{"progression":0.4,"totalProgression":0.4}}
            """
        let session = try await service.makeRegularReaderSession(
            at: fixture(named: "epub3-cyrillic"),
            initialLocatorJSON: locatorJSON,
            highlightLocatorJSON: nil,
            preferences: RegularReaderPreferences()
        )

        #expect(session.outline.map(\.title) == ["Глава первая"])
        #expect(session.progress == 0.4)
        #expect(session.currentPosition()?.totalProgression == 0.4)
        #expect(session.viewController.view != nil)

        session.apply(RegularReaderPreferences(fontScale: 1.4, pageMargins: 1.6, scroll: true))
        #expect(session.currentPosition()?.totalProgression == 0.4)

        let fixedSession = try await service.makeRegularReaderSession(
            at: fixture(named: "epub3-fixed"),
            initialLocatorJSON: nil,
            highlightLocatorJSON: nil,
            preferences: RegularReaderPreferences()
        )
        #expect(fixedSession.viewController.view != nil)
    }

    @Test("Readium extracts bounded speed content and restores it in regular mode")
    func speedContentRoundTrip() async throws {
        let service = ReadiumPublicationService()
        let fileStore = try ApplicationSupportBookFileStore(rootURL: temporaryRoot())
        let provider = try await service.makeSpeedContentProvider(
            at: fixture(named: "epub3-cyrillic"),
            contentHash: "epub-fixture",
            fileStore: fileStore
        )
        let firstCandidate = try await provider.start(at: nil)
        let first = try #require(firstCandidate)
        #expect(first.segments.count >= 2)
        #expect(Set(first.segments.map(\.id)).count >= 2)
        var extractedText = first.text
        var latest = first
        for _ in 0 ..< 8 {
            guard let next = try await provider.next() else {
                break
            }
            extractedText += " \(next.text)"
            latest = next
        }

        #expect(extractedText.contains("Глава первая"))
        #expect(extractedText.contains("Скорочтение"))
        #expect(extractedText.contains("контекст"))
        #expect(latest.text.count <= 100_000)

        let session = SpeedReaderSession(provider: provider, settings: SpeedReaderSettings())
        try await session.start(from: ReadingPosition?.none)
        #expect(session.nextContext.count == 3)
        await session.moveNext()
        await session.moveNext()
        await session.moveNext()
        let activeToken = try #require(session.currentToken)
        let speedSnapshot = try #require(session.currentPosition())
        try await assertRegularSpeedRoundTrip(
            service: service,
            fileStore: fileStore,
            activeToken: activeToken,
            speedSnapshot: speedSnapshot
        )

        let soughtCandidate = try await provider.seek(toTotalProgression: 0.5)
        let sought = try #require(soughtCandidate)
        let regularSession = try await service.makeRegularReaderSession(
            at: fixture(named: "epub3-cyrillic"),
            initialLocatorJSON: sought.locatorJSON,
            highlightLocatorJSON: nil,
            preferences: RegularReaderPreferences()
        )
        #expect(regularSession.currentPosition() != nil)
    }

    private func assertRegularSpeedRoundTrip(
        service: ReadiumPublicationService,
        fileStore: ApplicationSupportBookFileStore,
        activeToken: SpeedToken,
        speedSnapshot: SpeedPositionSnapshot
    ) async throws {
        let speedPosition = ReadingPosition(
            locatorJSON: speedSnapshot.locatorJSON,
            totalProgression: speedSnapshot.totalProgression,
            speedElementID: speedSnapshot.elementID,
            speedTokenOffset: speedSnapshot.tokenOffset,
            updatedAt: .now
        )
        let regularSession = try await service.makeRegularReaderSession(
            at: fixture(named: "epub3-cyrillic"),
            initialLocatorJSON: activeToken.locatorJSON,
            highlightLocatorJSON: activeToken.locatorJSON,
            preferences: RegularReaderPreferences()
        )
        #expect(regularSession.transitionHighlightText == activeToken.text)
        #expect(regularSession.viewController.view != nil)
        let regularSnapshot = try #require(regularSession.currentPosition())
        let roundTripPosition = speedPosition.updatingFromRegularReader(
            locatorJSON: regularSnapshot.locatorJSON,
            totalProgression: regularSnapshot.totalProgression,
            at: .now
        )
        let resumedProvider = try await service.makeSpeedContentProvider(
            at: fixture(named: "epub3-cyrillic"),
            contentHash: "epub-fixture",
            fileStore: fileStore
        )
        let resumedSession = SpeedReaderSession(
            provider: resumedProvider,
            settings: SpeedReaderSettings()
        )
        try await resumedSession.start(from: roundTripPosition)
        #expect(resumedSession.currentToken?.id == activeToken.id)
        #expect(resumedSession.currentToken?.text == activeToken.text)
    }

    @Test("Readium accepts EPUB 2 and fixed-layout EPUB 3")
    func supportedEPUBVariants() async throws {
        let service = ReadiumPublicationService()
        let epub2 = try await service.inspectPublication(at: fixture(named: "epub2"))
        let fixed = try await service.inspectPublication(at: fixture(named: "epub3-fixed"))
        let longChapter = try await service.inspectPublication(at: fixture(named: "long-chapter"))

        #expect(epub2.title == "EPUB 2 Fixture")
        #expect(epub2.layout == .reflowable)
        #expect(epub2.coverPNGData == nil)
        #expect(fixed.title == "Fixed Layout Fixture")
        #expect(fixed.layout == .fixed)
        #expect(longChapter.title == "Путешествие Swift")
        #expect(longChapter.layout == .reflowable)
    }

    @Test("Unsupported publication protection is rejected")
    func protectedEPUB() async throws {
        var receivedError: PublicationServiceError?
        do {
            _ = try await ReadiumPublicationService().inspectPublication(at: fixture(named: "protected"))
        } catch let error as PublicationServiceError {
            receivedError = error
        }

        #expect(receivedError == .protectedPublication)
    }

    @Test("Missing title, author, and cover use safe import fallbacks")
    func missingMetadata() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let repository = InMemoryBookRepository()
        let fileStore = try ApplicationSupportBookFileStore(rootURL: root)
        let coordinator = ImportCoordinator(
            repository: repository,
            fileStore: fileStore,
            publicationService: ReadiumPublicationService()
        )
        let outcome = try await coordinator.importFile(at: fixture(named: "missing-metadata"))
        guard case let .imported(bookID) = outcome,
              let book = try repository.book(id: bookID)
        else {
            Issue.record("Expected an imported fallback book")
            return
        }

        #expect(book.title == "missing-metadata")
        #expect(book.authorsDisplay.isEmpty)
        #expect(book.coverRelativePath == nil)
    }

    @Test("Import is content-addressed and a missing duplicate file is repaired")
    func duplicateRepair() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let repository = InMemoryBookRepository()
        let fileStore = try ApplicationSupportBookFileStore(rootURL: root)
        let coordinator = ImportCoordinator(
            repository: repository,
            fileStore: fileStore,
            publicationService: ReadiumPublicationService()
        )
        let fixtureURL = try fixture(named: "epub3-cyrillic")

        let first = try await coordinator.importFile(at: fixtureURL)
        guard case let .imported(bookID) = first,
              let book = try repository.book(id: bookID)
        else {
            Issue.record("Expected an imported book")
            return
        }
        #expect(await fileStore.fileExists(relativePath: book.fileRelativePath))

        try await fileStore.remove(relativePaths: [book.fileRelativePath])
        let second = try await coordinator.importFile(at: fixtureURL)
        #expect(second == .repaired(bookID))
        #expect(try repository.books(matching: LibraryFilter()).count == 1)
        #expect(await fileStore.fileExists(relativePath: book.fileRelativePath))
    }

    @Test("Malformed EPUB import leaves no record or staged file")
    func malformedRollback() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let repository = InMemoryBookRepository()
        let fileStore = try ApplicationSupportBookFileStore(rootURL: root)
        let coordinator = ImportCoordinator(
            repository: repository,
            fileStore: fileStore,
            publicationService: ReadiumPublicationService()
        )

        var failed = false
        do {
            _ = try await coordinator.importFile(at: fixtureURL(named: "malformed"))
        } catch {
            failed = true
        }

        #expect(failed)
        #expect(try repository.books(matching: LibraryFilter()).isEmpty)
        #expect(try children(at: root.appending(path: "Staging")).isEmpty)
        #expect(try children(at: root.appending(path: "Books")).isEmpty)
        #expect(try children(at: root.appending(path: "Covers")).isEmpty)
    }

    @Test("Persistence failure rolls back committed publication files")
    func persistenceRollback() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let fileStore = try ApplicationSupportBookFileStore(rootURL: root)
        let coordinator = ImportCoordinator(
            repository: RejectingInsertRepository(),
            fileStore: fileStore,
            publicationService: ReadiumPublicationService()
        )

        var failed = false
        do {
            _ = try await coordinator.importFile(at: fixture(named: "epub3-cyrillic"))
        } catch {
            failed = true
        }

        #expect(failed)
        #expect(try children(at: root.appending(path: "Staging")).isEmpty)
        #expect(try children(at: root.appending(path: "Books")).isEmpty)
        #expect(try children(at: root.appending(path: "Covers")).isEmpty)
    }

    @Test("Repository edits status and all tag memberships")
    func metadataEditing() throws {
        let repository = InMemoryBookRepository()
        let imported = try repository.insert(
            ImportedPublication(
                contentHash: "hash",
                title: "Fixture",
                authorsDisplay: "Author",
                mediaType: "application/epub+zip",
                layout: .reflowable,
                fileRelativePath: "Books/hash.epub",
                coverRelativePath: nil,
                fileByteCount: 42
            ),
            importedAt: .now
        )

        try repository.setStatus(.reading, for: imported.id, at: .now)
        try repository.setTags(["Work", " Cyrillic "], for: imported.id, at: .now)
        let updated = try repository.book(id: imported.id)

        #expect(updated?.status == .reading)
        #expect(updated?.tags.map(\.canonicalName).sorted() == ["cyrillic", "work"])
    }

    private func fixture(named name: String) throws -> URL {
        try fixtureURL(named: name)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "FastReaderTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private func children(at url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
    }
}

@MainActor
private final class RejectingInsertRepository: BookRepository {
    enum Failure: Error {
        case rejected
    }

    func books(matching _: LibraryFilter) throws -> [Book] {
        []
    }

    func book(id _: UUID) throws -> Book? {
        nil
    }

    func book(contentHash _: String) throws -> Book? {
        nil
    }

    func tags() throws -> [FastReader.Tag] {
        []
    }

    func insert(_: ImportedPublication, importedAt _: Date) throws -> Book {
        throw Failure.rejected
    }

    func setStatus(_: BookStatus, for _: UUID, at _: Date) throws {}

    func setTags(_: [String], for _: UUID, at _: Date) throws {}

    func delete(bookID _: UUID, at _: Date) throws -> Book {
        throw Failure.rejected
    }
}

private func fixtureURL(named name: String) throws -> URL {
    let bundle = Bundle(for: TestBundleToken.self)
    guard let url = bundle.url(forResource: name, withExtension: "epub") else {
        throw FixtureError.missing(name)
    }
    return url
}
