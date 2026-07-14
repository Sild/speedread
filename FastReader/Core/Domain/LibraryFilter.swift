import Foundation

struct LibraryFilter: Equatable, Sendable {
    var query = ""
    var status: BookStatus?
    var requiredTagIDs: Set<UUID> = []

    func matches(_ book: Book) -> Bool {
        let normalizedQuery = TagNormalizer.canonicalize(query)
        let searchableText = TagNormalizer.canonicalize(
            [book.title, book.authorsDisplay].joined(separator: " ")
        )
        let tagIDs = Set(book.tags.map(\.id))

        let matchesQuery = normalizedQuery.isEmpty || searchableText.contains(normalizedQuery)
        let matchesStatus = status == nil || book.status == status
        let matchesTags = requiredTagIDs.isSubset(of: tagIDs)

        return matchesQuery && matchesStatus && matchesTags
    }
}
