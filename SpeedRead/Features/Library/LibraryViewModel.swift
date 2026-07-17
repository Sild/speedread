import Foundation
import Observation

@MainActor
@Observable
final class LibraryViewModel {
    enum State {
        case loading
        case loaded([Book])
        case failure
    }

    private(set) var filter = LibraryFilter()
    private(set) var state: State = .loading
    private(set) var availableTags: [Tag] = []
    private(set) var facetCounts = LibraryFacetCounts()

    private let repository: any BookRepository
    private var allBooks: [Book] = []

    var hasBooks: Bool {
        !allBooks.isEmpty
    }

    init(repository: any BookRepository) {
        self.repository = repository
    }

    func load() {
        do {
            try reload()
        } catch {
            state = .failure
        }
    }

    func setStatus(_ status: BookStatus, bookID: UUID) {
        do {
            try repository.setStatus(status, for: bookID, at: .now)
            try reload()
        } catch {
            state = .failure
        }
    }

    func setTags(_ displayNames: [String], bookID: UUID) throws {
        try repository.setTags(displayNames, for: bookID, at: .now)
        try reload()
    }

    func selectStatus(_ status: BookStatus?) {
        if let status, filter.status == status {
            filter.status = nil
        } else {
            filter.status = status
        }
        refreshResults()
    }

    func toggleTag(_ tag: Tag) {
        if filter.requiredTagIDs.contains(tag.id) {
            filter.requiredTagIDs.remove(tag.id)
        } else {
            filter.requiredTagIDs.insert(tag.id)
        }
        refreshResults()
    }

    func setQuery(_ query: String) {
        filter.query = query
        refreshResults()
    }

    private func reload() throws {
        allBooks = try repository.books(matching: LibraryFilter())
        availableTags = try repository.tags()
        filter.requiredTagIDs.formIntersection(availableTags.map(\.id))
        refreshResults()
    }

    private func refreshResults() {
        let visibleBooks = allBooks.filter(filter.matches)
        facetCounts = LibraryFacetCounts(
            books: allBooks,
            availableTags: availableTags,
            filter: filter,
            visibleBookCount: visibleBooks.count
        )
        state = .loaded(visibleBooks)
    }
}

struct LibraryFacetCounts: Equatable {
    private(set) var allStatuses = 0
    private(set) var statuses: [BookStatus: Int] = [:]
    private(set) var tags: [UUID: Int] = [:]

    init() {}

    init(
        books: [Book],
        availableTags: [Tag],
        filter: LibraryFilter,
        visibleBookCount: Int? = nil
    ) {
        var statusBaseFilter = filter
        statusBaseFilter.status = nil
        allStatuses = books.count(where: statusBaseFilter.matches)
        statuses = Dictionary(uniqueKeysWithValues: BookStatus.allCases.map { status in
            var statusFilter = statusBaseFilter
            statusFilter.status = status
            return (status, books.count(where: statusFilter.matches))
        })

        let currentResultCount = visibleBookCount ?? books.count(where: filter.matches)
        tags = Dictionary(uniqueKeysWithValues: availableTags.map { tag in
            guard !filter.requiredTagIDs.contains(tag.id) else {
                return (tag.id, currentResultCount)
            }
            var candidateFilter = filter
            candidateFilter.requiredTagIDs.insert(tag.id)
            return (tag.id, books.count(where: candidateFilter.matches))
        })
    }

    func count(for status: BookStatus) -> Int {
        statuses[status, default: 0]
    }

    func count(for tag: Tag) -> Int {
        tags[tag.id, default: 0]
    }
}
