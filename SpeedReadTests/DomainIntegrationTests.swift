import Foundation
@preconcurrency import ReadiumShared
@testable import SpeedRead
import SwiftData
import Testing

@Suite("Domain integration")
struct DomainIntegrationTests {
    @Test("Selecting the active library status clears it")
    @MainActor
    func libraryStatusToggle() {
        let book = makeBook(title: "Alpha", status: .reading, tags: [])
        let viewModel = LibraryViewModel(repository: InMemoryBookRepository(books: [book]))
        viewModel.load()

        viewModel.selectStatus(.reading)
        #expect(viewModel.filter.status == .reading)

        viewModel.selectStatus(.reading)
        #expect(viewModel.filter.status == nil)
        guard case let .loaded(books) = viewModel.state else {
            Issue.record("Expected the library to remain loaded")
            return
        }
        #expect(books == [book])
    }

    @Test("Reload removes selected tags that no longer exist")
    @MainActor
    func libraryRemovedTagSelection() throws {
        let tag = SpeedRead.Tag(id: UUID(), canonicalName: "focus", displayName: "Focus")
        let book = makeBook(title: "Alpha", status: .reading, tags: [tag])
        let repository = InMemoryBookRepository(books: [book])
        let viewModel = LibraryViewModel(repository: repository)
        viewModel.load()
        viewModel.toggleTag(tag)
        #expect(viewModel.filter.requiredTagIDs == [tag.id])

        try repository.setTags([], for: book.id, at: .now)
        viewModel.load()

        #expect(viewModel.availableTags.isEmpty)
        #expect(viewModel.filter.requiredTagIDs.isEmpty)
        guard case let .loaded(books) = viewModel.state else {
            Issue.record("Expected the library to remain loaded")
            return
        }
        #expect(books.count == 1)
    }

    @Test("Regular-reader seek targets snap to positions and preserve full endpoints")
    @MainActor
    func regularReaderSeekTargets() throws {
        let positions = try [
            locator(position: 1, progression: 0),
            locator(position: 2, progression: 0.5),
            locator(position: 3, progression: 0.9)
        ]

        let midpoint = try #require(RegularReaderSession.seekLocator(for: 0.6, in: positions))
        #expect(midpoint.locations.position == 2)
        #expect(midpoint.locations.totalProgression == 0.5)

        let beginning = try #require(RegularReaderSession.seekLocator(for: -1, in: positions))
        #expect(beginning.locations.position == 1)
        #expect(beginning.locations.progression == 0)
        #expect(beginning.locations.totalProgression == 0)

        let end = try #require(RegularReaderSession.seekLocator(for: 2, in: positions))
        #expect(end.locations.position == 3)
        #expect(end.locations.progression == 1)
        #expect(end.locations.totalProgression == 1)
    }

    private func makeBook(title: String, status: BookStatus, tags: [SpeedRead.Tag]) -> Book {
        Book(
            id: UUID(),
            contentHash: title,
            title: title,
            authorsDisplay: "Author",
            mediaType: "application/epub+zip",
            layout: .reflowable,
            fileRelativePath: "Books/\(title).epub",
            progress: 0.25,
            status: status,
            tags: tags,
            importedAt: .now,
            lastOpenedAt: nil,
            coverRelativePath: nil
        )
    }

    private func locator(position: Int, progression: Double) throws -> Locator {
        let json =
            """
            {"href":"chapter.xhtml","type":"application/xhtml+xml",
            "locations":{"position":\(position),"progression":\(progression),
            "totalProgression":\(progression)}}
            """
        return try #require(try Locator(jsonString: json))
    }
}

@Suite("Persistence schema")
@MainActor
struct PersistenceTests {
    @Test("Version one schema saves and fetches a book")
    func schemaRoundTrip() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let now = Date()
        let record = BookRecord(
            id: UUID(),
            contentHash: "fixture-hash",
            title: "Fixture",
            authorsDisplay: "Author",
            mediaType: "application/epub+zip",
            layout: .reflowable,
            fileRelativePath: "Books/fixture.epub",
            coverRelativePath: nil,
            fileByteCount: 42,
            importedAt: now
        )
        container.mainContext.insert(record)
        try container.mainContext.save()

        let fetched = try container.mainContext.fetch(FetchDescriptor<BookRecord>())
        #expect(fetched.count == 1)
        #expect(fetched.first?.title == "Fixture")
        #expect(SpeedReadMigrationPlan.schemas.count == 2)
    }

    @Test("Reading position round-trips and automates status")
    func readingProgressRoundTrip() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let repository = SwiftDataBookRepository(modelContainer: container)
        let imported = try repository.insert(
            ImportedPublication(
                contentHash: "progress-fixture",
                title: "Progress Fixture",
                authorsDisplay: "Author",
                mediaType: "application/epub+zip",
                layout: .reflowable,
                fileRelativePath: "Books/progress.epub",
                coverRelativePath: nil,
                fileByteCount: 100
            ),
            importedAt: Date(timeIntervalSince1970: 1)
        )
        let updateDate = Date(timeIntervalSince1970: 2)
        let position = ReadingPosition(
            locatorJSON: "{\"href\":\"chapter.xhtml\",\"type\":\"application/xhtml+xml\"}",
            totalProgression: 0.25,
            speedElementID: "chapter.xhtml#paragraph-2",
            speedTokenOffset: 12,
            updatedAt: updateDate
        )

        try repository.saveReadingPosition(position, for: imported.id, reachedPublicationEnd: false)

        #expect(try repository.readingPosition(for: imported.id) == position)
        #expect(try repository.book(id: imported.id)?.progress == 0.25)
        #expect(try repository.book(id: imported.id)?.status == .reading)

        try repository.saveReadingPosition(position, for: imported.id, reachedPublicationEnd: true)
        #expect(try repository.book(id: imported.id)?.progress == 1)
        #expect(try repository.book(id: imported.id)?.status == .done)
    }

    @Test("Tags disappear only after their final active membership is removed")
    func orphanedTags() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let repository = SwiftDataBookRepository(modelContainer: container)
        container.mainContext.insert(
            TagRecord(
                id: UUID(),
                canonicalName: "legacy-orphan",
                displayName: "Legacy Orphan",
                createdAt: Date(timeIntervalSince1970: 0)
            )
        )
        try container.mainContext.save()
        #expect(try repository.tags().isEmpty)

        let first = try repository.insert(
            importedPublication(hash: "first", title: "First"),
            importedAt: Date(timeIntervalSince1970: 1)
        )
        let second = try repository.insert(
            importedPublication(hash: "second", title: "Second"),
            importedAt: Date(timeIntervalSince1970: 2)
        )

        try repository.setTags(["Shared", "Only First"], for: first.id, at: Date(timeIntervalSince1970: 3))
        try repository.setTags(["Shared"], for: second.id, at: Date(timeIntervalSince1970: 4))
        try repository.setTags([], for: first.id, at: Date(timeIntervalSince1970: 5))

        #expect(try repository.tags().map(\.canonicalName) == ["shared"])
        #expect(try repository.book(id: first.id)?.tags.isEmpty == true)

        try repository.setTags([], for: second.id, at: Date(timeIntervalSince1970: 6))
        #expect(try repository.tags().isEmpty)
    }

    private func importedPublication(hash: String, title: String) -> ImportedPublication {
        ImportedPublication(
            contentHash: hash,
            title: title,
            authorsDisplay: "Author",
            mediaType: "application/epub+zip",
            layout: .reflowable,
            fileRelativePath: "Books/\(hash).epub",
            coverRelativePath: nil,
            fileByteCount: 42
        )
    }
}
