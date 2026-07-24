import Foundation
import Testing

@Suite("Native domain behavior")
struct DomainLogicTests {
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
        let fiction = Tag(id: UUID(), canonicalName: "fiction", displayName: "Fiction")
        let short = Tag(id: UUID(), canonicalName: "short", displayName: "Short")
        let favorite = Tag(id: UUID(), canonicalName: "favorite", displayName: "Favorite")
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

    private func makeBook(title: String, status: BookStatus, tags: [Tag]) -> Book {
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
