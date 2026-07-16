@testable import FastReader
import Foundation
@preconcurrency import ReadiumShared
import SwiftData
import Testing

@Suite("Domain behavior")
struct DomainTests {
    @Test("Speed tokenization is grapheme-safe for Latin and Cyrillic")
    func speedTokenizationAndORP() {
        let element = SpeedContentElement(
            id: "chapter#1",
            text: "“Reading,” скорость невероятная.",
            locatorJSON: "{}",
            totalProgression: 0.25
        )

        let tokens = SpeedTokenizer.tokenize(element)

        #expect(tokens.map(\.text) == ["“Reading,”", "скорость", "невероятная."])
        #expect(tokens[0].prefix == "“Re")
        #expect(tokens[0].focus == "a")
        #expect(tokens[1].prefix == "ск")
        #expect(tokens[1].focus == "о")
        #expect(tokens[2].prefix == "нев")
        #expect(tokens[2].focus == "е")
        #expect(tokens[2].endsParagraph)
    }

    @Test("Speed token locators preserve paragraph identity and exact word context")
    func speedTokenLocators() throws {
        let firstLocator =
            """
            {"href":"chapter.xhtml","type":"application/xhtml+xml",
            "locations":{"cssSelector":"p:nth-child(1)"},
            "text":{"before":"Lead ","highlight":"alpha beta","after":" tail"}}
            """
        let secondLocator =
            """
            {"href":"chapter.xhtml","type":"application/xhtml+xml",
            "locations":{"cssSelector":"p:nth-child(2)"},
            "text":{"highlight":"gamma delta"}}
            """
        let element = SpeedContentElement(
            id: "chunk",
            segments: [
                SpeedContentSegment(
                    id: "paragraph-one",
                    text: "alpha beta",
                    locatorJSON: firstLocator,
                    totalProgression: 0.2
                ),
                SpeedContentSegment(
                    id: "paragraph-two",
                    text: "gamma delta",
                    locatorJSON: secondLocator,
                    totalProgression: 0.3,
                    tokenOffsetBase: 7
                )
            ]
        )

        let tokens = SpeedTokenizer.tokenize(element)

        #expect(tokens.map(\.elementID) == [
            "paragraph-one", "paragraph-one", "paragraph-two", "paragraph-two"
        ])
        #expect(tokens.map(\.offset) == [0, 1, 7, 8])
        #expect(tokens.map(\.endsParagraph) == [false, true, false, true])

        let beta = try #require(tokens.first(where: { $0.text == "beta" }))
        let data = try #require(beta.locatorJSON.data(using: .utf8))
        let locator = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let locations = try #require(locator["locations"] as? [String: Any])
        let text = try #require(locator["text"] as? [String: Any])
        #expect(locations["cssSelector"] as? String == "p:nth-child(1)")
        #expect(text["highlight"] as? String == "beta")
        #expect(text["before"] as? String == "Lead alpha ")
        #expect(text["after"] as? String == " tail")
    }

    @Test("Adaptive pacing uses the largest applicable pause")
    func adaptivePacing() {
        let element = SpeedContentElement(
            id: "paragraph",
            text: "brief, extraordinarily.",
            locatorJSON: "{}",
            totalProgression: 0.4
        )
        let tokens = SpeedTokenizer.tokenize(element)

        #expect(
            SpeedPacing.durationMilliseconds(
                for: tokens[0],
                settings: SpeedReaderSettings(wordsPerMinute: 300, adaptivePauses: true)
            ) == 300
        )
        #expect(
            SpeedPacing.durationMilliseconds(
                for: tokens[1],
                settings: SpeedReaderSettings(wordsPerMinute: 300, adaptivePauses: true)
            ) == 500
        )
        #expect(
            SpeedPacing.durationMilliseconds(
                for: tokens[1],
                settings: SpeedReaderSettings(wordsPerMinute: 300, adaptivePauses: false)
            ) == 200
        )
    }

    @Test("Speed settings clamp and quantize WPM")
    func speedSettings() {
        #expect(SpeedReaderSettings(wordsPerMinute: 99).normalizedWordsPerMinute == 100)
        #expect(SpeedReaderSettings(wordsPerMinute: 338).normalizedWordsPerMinute == 350)
        #expect(SpeedReaderSettings(wordsPerMinute: 1200).normalizedWordsPerMinute == 1000)
    }

    @Test("Publication end requires the final resource at its final viewport")
    func publicationEndDetection() {
        #expect(
            ReaderEndDetection.hasReachedEnd(
                finalResourceIsVisible: true,
                finalResourceProgressionUpperBound: 1
            )
        )
        #expect(
            !ReaderEndDetection.hasReachedEnd(
                finalResourceIsVisible: true,
                finalResourceProgressionUpperBound: 0.99
            )
        )
        #expect(
            !ReaderEndDetection.hasReachedEnd(
                finalResourceIsVisible: false,
                finalResourceProgressionUpperBound: 1
            )
        )
    }

    @Test("Automatic status transitions preserve explicit terminal states")
    func statusTransitions() {
        #expect(nextStatus(progress: 0, reachedEnd: false, current: .new) == .new)
        #expect(nextStatus(progress: 0.1, reachedEnd: false, current: .new) == .reading)
        #expect(nextStatus(progress: 1, reachedEnd: true, current: .reading) == .done)
        #expect(nextStatus(progress: 0.4, reachedEnd: false, current: .done) == .done)
        #expect(nextStatus(progress: 0.4, reachedEnd: false, current: .canceled) == .canceled)
    }

    @Test("Library search, status, and every tag are AND predicates")
    func libraryFilter() {
        let fiction = Tag(id: UUID(), canonicalName: "fiction", displayName: "Fiction")
        let short = Tag(id: UUID(), canonicalName: "short", displayName: "Short")
        let book = Book(
            id: UUID(),
            contentHash: "hash",
            title: "The Swift Journey",
            authorsDisplay: "Иван Петров",
            mediaType: "application/epub+zip",
            layout: .reflowable,
            fileRelativePath: "Books/hash.epub",
            progress: 0.2,
            status: .reading,
            tags: [fiction, short],
            importedAt: .now,
            lastOpenedAt: nil,
            coverRelativePath: nil
        )

        let allFilters = LibraryFilter(
            query: "swift",
            status: .reading,
            requiredTagIDs: [fiction.id, short.id]
        )
        #expect(allFilters.matches(book))
        #expect(LibraryFilter(query: "иван", status: .reading, requiredTagIDs: [fiction.id]).matches(book))
        #expect(!LibraryFilter(query: "swift", status: .done, requiredTagIDs: [fiction.id]).matches(book))
        #expect(!LibraryFilter(query: "swift", status: .reading, requiredTagIDs: [UUID()]).matches(book))
    }

    @Test("Library facet counts predict the remaining AND-filter results")
    func libraryFacetCounts() {
        let fiction = FastReader.Tag(id: UUID(), canonicalName: "fiction", displayName: "Fiction")
        let short = FastReader.Tag(id: UUID(), canonicalName: "short", displayName: "Short")
        let favorite = FastReader.Tag(id: UUID(), canonicalName: "favorite", displayName: "Favorite")
        let books = [
            makeBook(title: "Alpha", status: .reading, tags: [fiction, short]),
            makeBook(title: "Beta", status: .reading, tags: [fiction]),
            makeBook(title: "Gamma", status: .done, tags: [short]),
            makeBook(title: "Delta", status: .new, tags: [fiction, short, favorite])
        ]
        let tags = [favorite, fiction, short]

        let fictionFilter = LibraryFilter(status: .reading, requiredTagIDs: [fiction.id])
        let fictionCounts = LibraryFacetCounts(
            books: books,
            availableTags: tags,
            filter: fictionFilter
        )

        #expect(fictionCounts.allStatuses == 3)
        #expect(fictionCounts.count(for: .new) == 1)
        #expect(fictionCounts.count(for: .reading) == 2)
        #expect(fictionCounts.count(for: .done) == 0)
        #expect(fictionCounts.count(for: fiction) == 2)
        #expect(fictionCounts.count(for: short) == 1)
        #expect(fictionCounts.count(for: favorite) == 0)

        let narrowedFilter = LibraryFilter(
            query: "alpha",
            status: .reading,
            requiredTagIDs: [fiction.id, short.id]
        )
        let narrowedCounts = LibraryFacetCounts(
            books: books,
            availableTags: tags,
            filter: narrowedFilter
        )

        #expect(narrowedCounts.allStatuses == 1)
        #expect(narrowedCounts.count(for: fiction) == 1)
        #expect(narrowedCounts.count(for: short) == 1)
        #expect(narrowedCounts.count(for: favorite) == 0)
    }

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
        let tag = FastReader.Tag(id: UUID(), canonicalName: "focus", displayName: "Focus")
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

    @Test("Tag normalization is whitespace, Unicode, and case stable")
    func tagNormalization() {
        #expect(TagNormalizer.canonicalize("  Чтение\n") == "чтение")
        #expect(TagNormalizer.canonicalize("Résumé") == TagNormalizer.canonicalize("Re\u{301}sume\u{301}"))
    }

    @Test("Reading progression is clamped for display and persistence boundaries")
    func progressionClamping() {
        let position = ReadingPosition(
            locatorJSON: "{}",
            totalProgression: 1.2,
            speedElementID: nil,
            speedTokenOffset: nil,
            updatedAt: .now
        )
        #expect(position.clampedProgression == 1)
    }

    private func nextStatus(
        progress: Double,
        reachedEnd: Bool,
        current: BookStatus
    ) -> BookStatus {
        BookStatusTransition.status(
            afterProgress: progress,
            reachedPublicationEnd: reachedEnd,
            currentStatus: current
        )
    }

    private func makeBook(title: String, status: BookStatus, tags: [FastReader.Tag]) -> Book {
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
}

extension DomainTests {
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
        #expect(FastReaderMigrationPlan.schemas.count == 2)
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
