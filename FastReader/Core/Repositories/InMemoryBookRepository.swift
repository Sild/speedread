import Foundation

@MainActor
final class InMemoryBookRepository: BookRepository, ReadingProgressStore {
    private var storedBooks: [Book]
    private var positions: [UUID: ReadingPosition] = [:]

    init(books: [Book] = []) {
        storedBooks = books
    }

    func books(matching filter: LibraryFilter) throws -> [Book] {
        storedBooks.filter(filter.matches)
    }

    func book(id: UUID) throws -> Book? {
        storedBooks.first { $0.id == id }
    }

    func book(contentHash: String) throws -> Book? {
        storedBooks.first { $0.contentHash == contentHash }
    }

    func tags() throws -> [Tag] {
        Array(Set(storedBooks.flatMap(\.tags))).sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    func insert(_ publication: ImportedPublication, importedAt: Date) throws -> Book {
        guard try book(contentHash: publication.contentHash) == nil else {
            throw BookRepositoryError.duplicateContent(publication.contentHash)
        }
        let book = Book(
            id: UUID(),
            contentHash: publication.contentHash,
            title: publication.title,
            authorsDisplay: publication.authorsDisplay,
            mediaType: publication.mediaType,
            layout: publication.layout,
            fileRelativePath: publication.fileRelativePath,
            progress: 0,
            status: .new,
            tags: [],
            importedAt: importedAt,
            lastOpenedAt: nil,
            coverRelativePath: publication.coverRelativePath
        )
        storedBooks.append(book)
        return book
    }

    func setStatus(_ status: BookStatus, for bookID: UUID, at _: Date) throws {
        try replace(bookID: bookID) { book in
            Book(
                id: book.id,
                contentHash: book.contentHash,
                title: book.title,
                authorsDisplay: book.authorsDisplay,
                mediaType: book.mediaType,
                layout: book.layout,
                fileRelativePath: book.fileRelativePath,
                progress: book.progress,
                status: status,
                tags: book.tags,
                importedAt: book.importedAt,
                lastOpenedAt: book.lastOpenedAt,
                coverRelativePath: book.coverRelativePath
            )
        }
    }

    func setTags(_ displayNames: [String], for bookID: UUID, at _: Date) throws {
        var tagsByCanonical: [String: Tag] = [:]
        for name in displayNames {
            let canonical = TagNormalizer.canonicalize(name)
            guard !canonical.isEmpty else {
                throw BookRepositoryError.emptyTag
            }
            if tagsByCanonical[canonical] == nil {
                tagsByCanonical[canonical] = Tag(
                    id: UUID(),
                    canonicalName: canonical,
                    displayName: name.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
        }
        let tags = Array(tagsByCanonical.values)
        try replace(bookID: bookID) { book in
            Book(
                id: book.id,
                contentHash: book.contentHash,
                title: book.title,
                authorsDisplay: book.authorsDisplay,
                mediaType: book.mediaType,
                layout: book.layout,
                fileRelativePath: book.fileRelativePath,
                progress: book.progress,
                status: book.status,
                tags: tags,
                importedAt: book.importedAt,
                lastOpenedAt: book.lastOpenedAt,
                coverRelativePath: book.coverRelativePath
            )
        }
    }

    func delete(bookID: UUID, at _: Date) throws -> Book {
        guard let index = storedBooks.firstIndex(where: { $0.id == bookID }) else {
            throw BookRepositoryError.missingBook(bookID)
        }
        positions[bookID] = nil
        return storedBooks.remove(at: index)
    }

    func readingPosition(for bookID: UUID) throws -> ReadingPosition? {
        guard try book(id: bookID) != nil else {
            throw BookRepositoryError.missingBook(bookID)
        }
        return positions[bookID]
    }

    func markOpened(bookID: UUID, at date: Date) throws {
        try replace(bookID: bookID) { book in
            Self.copy(book, lastOpenedAt: date)
        }
    }

    func saveReadingPosition(
        _ position: ReadingPosition,
        for bookID: UUID,
        reachedPublicationEnd: Bool
    ) throws {
        let progression = reachedPublicationEnd ? 1 : position.clampedProgression
        try replace(bookID: bookID) { book in
            Self.copy(
                book,
                progress: progression,
                status: BookStatusTransition.status(
                    afterProgress: progression,
                    reachedPublicationEnd: reachedPublicationEnd,
                    currentStatus: book.status
                ),
                lastOpenedAt: position.updatedAt
            )
        }
        positions[bookID] = ReadingPosition(
            locatorJSON: position.locatorJSON,
            totalProgression: progression,
            speedElementID: position.speedElementID,
            speedTokenOffset: position.speedTokenOffset,
            updatedAt: position.updatedAt
        )
    }

    private func replace(bookID: UUID, transform: (Book) -> Book) throws {
        guard let index = storedBooks.firstIndex(where: { $0.id == bookID }) else {
            throw BookRepositoryError.missingBook(bookID)
        }
        storedBooks[index] = transform(storedBooks[index])
    }

    private static func copy(
        _ book: Book,
        progress: Double? = nil,
        status: BookStatus? = nil,
        lastOpenedAt: Date? = nil
    ) -> Book {
        Book(
            id: book.id,
            contentHash: book.contentHash,
            title: book.title,
            authorsDisplay: book.authorsDisplay,
            mediaType: book.mediaType,
            layout: book.layout,
            fileRelativePath: book.fileRelativePath,
            progress: progress ?? book.progress,
            status: status ?? book.status,
            tags: book.tags,
            importedAt: book.importedAt,
            lastOpenedAt: lastOpenedAt ?? book.lastOpenedAt,
            coverRelativePath: book.coverRelativePath
        )
    }
}
