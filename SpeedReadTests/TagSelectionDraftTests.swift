import Foundation
@testable import SpeedRead
import Testing

@Suite("Tag selection draft")
struct TagSelectionDraftTests {
    @Test("Search selects canonical matches and creates one multiword tag")
    func searchAndCreation() {
        let fiction = tag("Fiction")
        let work = tag("Work")
        let resume = tag("Résumé")
        var draft = TagSelectionDraft(
            selectedTags: [fiction],
            availableTags: [resume, work, fiction]
        )

        #expect(draft.selectedOptions.map(\.displayName) == ["Fiction"])
        #expect(draft.availableOptions.map(\.displayName) == ["Résumé", "Work"])
        #expect(!draft.hasChanges)

        draft.query = "  WORK "
        #expect(draft.searchResults.map(\.displayName) == ["Work"])
        #expect(draft.creationDisplayName == nil)
        draft.selectOrCreateQuery()
        #expect(draft.query.isEmpty)
        #expect(draft.selectedDisplayNames == ["Fiction", "Work"])

        draft.query = "Re\u{301}sume\u{301}"
        #expect(draft.creationDisplayName == nil)
        draft.selectOrCreateQuery()
        #expect(draft.selectedDisplayNames == ["Fiction", "Résumé", "Work"])

        draft.query = "  Long Form  "
        #expect(draft.creationDisplayName == "Long Form")
        draft.selectOrCreateQuery()
        #expect(draft.selectedDisplayNames == ["Fiction", "Long Form", "Résumé", "Work"])
        #expect(draft.hasChanges)
    }

    @Test("Dirty state ignores unselected draft options")
    func dirtyState() throws {
        let fiction = tag("Fiction")
        var draft = TagSelectionDraft(selectedTags: [fiction], availableTags: [fiction])
        let fictionOption = try #require(draft.selectedOptions.first)

        draft.toggle(fictionOption)
        #expect(draft.selectedDisplayNames.isEmpty)
        #expect(draft.hasChanges)
        draft.toggle(fictionOption)
        #expect(!draft.hasChanges)

        draft.query = "   "
        draft.selectOrCreateQuery()
        #expect(draft.query == "   ")
        #expect(!draft.hasChanges)

        draft.query = "Draft Only"
        draft.selectOrCreateQuery()
        let draftOption = try #require(
            draft.selectedOptions.first(where: { $0.canonicalName == "draft only" })
        )
        draft.toggle(draftOption)
        #expect(draft.selectedDisplayNames == ["Fiction"])
        #expect(!draft.hasChanges)
    }

    @Test("Library reloads on success and remains loaded on write failure")
    @MainActor
    func librarySaveOutcome() throws {
        let book = makeBook()
        let repository = InMemoryBookRepository(books: [book])
        let viewModel = LibraryViewModel(repository: repository)
        viewModel.load()

        try viewModel.setTags(["Long Form"], bookID: book.id)
        #expect(viewModel.availableTags.map(\.canonicalName) == ["long form"])

        let rejectingRepository = RejectingTagBookRepository(book: book)
        let rejectingViewModel = LibraryViewModel(repository: rejectingRepository)
        rejectingViewModel.load()
        #expect(throws: RejectingTagBookRepository.Failure.self) {
            try rejectingViewModel.setTags(["Focus"], bookID: book.id)
        }
        guard case let .loaded(books) = rejectingViewModel.state else {
            Issue.record("Expected failed tag saving to preserve the loaded library")
            return
        }
        #expect(books == [book])
    }

    private func tag(_ displayName: String) -> SpeedRead.Tag {
        SpeedRead.Tag(
            id: UUID(),
            canonicalName: TagNormalizer.canonicalize(displayName),
            displayName: displayName
        )
    }

    private func makeBook() -> Book {
        Book(
            id: UUID(),
            contentHash: "alpha",
            title: "Alpha",
            authorsDisplay: "Author",
            mediaType: "application/epub+zip",
            layout: .reflowable,
            fileRelativePath: "Books/alpha.epub",
            progress: 0.25,
            status: .reading,
            tags: [],
            importedAt: .now,
            lastOpenedAt: nil,
            coverRelativePath: nil
        )
    }
}

@MainActor
private final class RejectingTagBookRepository: BookRepository {
    enum Failure: Error {
        case rejected
    }

    private let storedBook: Book

    init(book: Book) {
        storedBook = book
    }

    func books(matching filter: LibraryFilter) throws -> [Book] {
        filter.matches(storedBook) ? [storedBook] : []
    }

    func book(id: UUID) throws -> Book? {
        id == storedBook.id ? storedBook : nil
    }

    func book(contentHash: String) throws -> Book? {
        contentHash == storedBook.contentHash ? storedBook : nil
    }

    func tags() throws -> [SpeedRead.Tag] {
        storedBook.tags
    }

    func insert(_: ImportedPublication, importedAt _: Date) throws -> Book {
        throw Failure.rejected
    }

    func setStatus(_: BookStatus, for _: UUID, at _: Date) throws {
        throw Failure.rejected
    }

    func setTags(_: [String], for _: UUID, at _: Date) throws {
        throw Failure.rejected
    }

    func delete(bookID _: UUID, at _: Date) throws -> Book {
        throw Failure.rejected
    }
}
