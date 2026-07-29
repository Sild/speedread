import Foundation

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
