import Foundation
import SwiftData

@MainActor
final class SwiftDataBookRepository: BookRepository, ReadingProgressStore {
    private let context: ModelContext

    init(modelContainer: ModelContainer) {
        context = modelContainer.mainContext
    }

    func books(matching filter: LibraryFilter) throws -> [Book] {
        try activeBookRecords()
            .map(makeBook)
            .filter(filter.matches)
            .sorted(by: Self.sortBooks)
    }

    func book(id: UUID) throws -> Book? {
        guard let record = try activeBookRecords().first(where: { $0.id == id }) else {
            return nil
        }
        return try makeBook(record)
    }

    func book(contentHash: String) throws -> Book? {
        guard let record = try activeBookRecords().first(where: { $0.contentHash == contentHash }) else {
            return nil
        }
        return try makeBook(record)
    }

    func tags() throws -> [Tag] {
        let activeTagIDs = try Set(
            context.fetch(FetchDescriptor<BookTagRecord>())
                .lazy
                .filter { $0.deletedAt == nil }
                .map(\.tagID)
        )
        return try activeTagRecords()
            .filter { activeTagIDs.contains($0.id) }
            .map { Tag(id: $0.id, canonicalName: $0.canonicalName, displayName: $0.displayName) }
            .sorted {
                $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
    }

    func insert(_ publication: ImportedPublication, importedAt: Date) throws -> Book {
        guard try book(contentHash: publication.contentHash) == nil else {
            throw BookRepositoryError.duplicateContent(publication.contentHash)
        }

        let record = BookRecord(
            id: UUID(),
            contentHash: publication.contentHash,
            title: publication.title,
            authorsDisplay: publication.authorsDisplay,
            mediaType: publication.mediaType,
            layout: publication.layout,
            fileRelativePath: publication.fileRelativePath,
            coverRelativePath: publication.coverRelativePath,
            fileByteCount: publication.fileByteCount,
            importedAt: importedAt
        )
        context.insert(record)
        try context.save()
        return try makeBook(record)
    }

    func setStatus(_ status: BookStatus, for bookID: UUID, at date: Date) throws {
        let record = try requiredBookRecord(id: bookID)
        record.statusRawValue = status.rawValue
        record.statusUpdatedAt = date
        try context.save()
    }

    func setTags(_ displayNames: [String], for bookID: UUID, at date: Date) throws {
        _ = try requiredBookRecord(id: bookID)
        var requested: [String: String] = [:]
        for displayName in displayNames {
            let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            let canonical = TagNormalizer.canonicalize(trimmed)
            guard !canonical.isEmpty else {
                throw BookRepositoryError.emptyTag
            }
            requested[canonical] = requested[canonical] ?? trimmed
        }

        let tagRecords = try context.fetch(FetchDescriptor<TagRecord>())
        let allLinks = try context.fetch(FetchDescriptor<BookTagRecord>())
        let activeLinks = allLinks.filter { $0.bookID == bookID && $0.deletedAt == nil }
        let tagsByCanonical = tagRecords.reduce(into: [String: TagRecord]()) { result, tag in
            if result[tag.canonicalName] == nil {
                result[tag.canonicalName] = tag
            }
        }

        for link in activeLinks {
            link.deletedAt = date
            link.updatedAt = date
        }

        var requestedTagIDs: Set<UUID> = []
        for (canonical, displayName) in requested {
            let tag: TagRecord
            if let existing = tagsByCanonical[canonical] {
                tag = existing
                tag.deletedAt = nil
                tag.updatedAt = date
            } else {
                tag = TagRecord(
                    id: UUID(),
                    canonicalName: canonical,
                    displayName: displayName,
                    createdAt: date
                )
                context.insert(tag)
            }
            requestedTagIDs.insert(tag.id)
            context.insert(BookTagRecord(id: UUID(), bookID: bookID, tagID: tag.id, createdAt: date))
        }

        retireOrphanedTags(
            tagRecords,
            activeLinks: allLinks,
            replacingBookID: bookID,
            retainedTagIDs: requestedTagIDs,
            at: date
        )

        try context.save()
    }

    func delete(bookID: UUID, at date: Date) throws -> Book {
        let record = try requiredBookRecord(id: bookID)
        let book = try makeBook(record)
        record.deletedAt = date
        record.metadataUpdatedAt = date
        let links = try context.fetch(FetchDescriptor<BookTagRecord>())
            .filter { $0.bookID == bookID && $0.deletedAt == nil }
        for link in links {
            link.deletedAt = date
            link.updatedAt = date
        }
        try context.save()
        return book
    }

    func readingPosition(for bookID: UUID) throws -> ReadingPosition? {
        let record = try requiredBookRecord(id: bookID)
        guard let locatorJSON = record.locatorJSON else {
            return nil
        }
        return ReadingPosition(
            locatorJSON: locatorJSON,
            totalProgression: record.progress,
            speedElementID: record.speedElementID,
            speedTokenOffset: record.speedTokenOffset,
            updatedAt: record.positionUpdatedAt
        )
    }

    func markOpened(bookID: UUID, at date: Date) throws {
        let record = try requiredBookRecord(id: bookID)
        record.lastOpenedAt = date
        try context.save()
    }

    func saveReadingPosition(
        _ position: ReadingPosition,
        for bookID: UUID,
        reachedPublicationEnd: Bool
    ) throws {
        let record = try requiredBookRecord(id: bookID)
        let progression = reachedPublicationEnd ? 1 : position.clampedProgression
        record.locatorJSON = position.locatorJSON
        record.progress = progression
        record.speedElementID = position.speedElementID
        record.speedTokenOffset = position.speedTokenOffset
        record.positionUpdatedAt = position.updatedAt
        record.lastOpenedAt = position.updatedAt

        guard let currentStatus = BookStatus(rawValue: record.statusRawValue) else {
            throw BookRepositoryError.invalidStatus(record.statusRawValue)
        }
        let nextStatus = BookStatusTransition.status(
            afterProgress: progression,
            reachedPublicationEnd: reachedPublicationEnd,
            currentStatus: currentStatus
        )
        if nextStatus != currentStatus {
            record.statusRawValue = nextStatus.rawValue
            record.statusUpdatedAt = position.updatedAt
        }
        try context.save()
    }

    private func activeBookRecords() throws -> [BookRecord] {
        try context.fetch(FetchDescriptor<BookRecord>()).filter { $0.deletedAt == nil }
    }

    private func activeTagRecords() throws -> [TagRecord] {
        try context.fetch(FetchDescriptor<TagRecord>()).filter { $0.deletedAt == nil }
    }

    private func retireOrphanedTags(
        _ tagRecords: [TagRecord],
        activeLinks: [BookTagRecord],
        replacingBookID: UUID,
        retainedTagIDs: Set<UUID>,
        at date: Date
    ) {
        let activeTagIDsOutsideBook = Set(
            activeLinks.lazy
                .filter { $0.bookID != replacingBookID && $0.deletedAt == nil }
                .map(\.tagID)
        )
        let activeTagIDs = activeTagIDsOutsideBook.union(retainedTagIDs)
        for tag in tagRecords where tag.deletedAt == nil && !activeTagIDs.contains(tag.id) {
            tag.deletedAt = date
            tag.updatedAt = date
        }
    }

    private func requiredBookRecord(id: UUID) throws -> BookRecord {
        guard let record = try activeBookRecords().first(where: { $0.id == id }) else {
            throw BookRepositoryError.missingBook(id)
        }
        return record
    }

    private func makeBook(_ record: BookRecord) throws -> Book {
        guard let status = BookStatus(rawValue: record.statusRawValue) else {
            throw BookRepositoryError.invalidStatus(record.statusRawValue)
        }
        guard let layout = PublicationLayout(rawValue: record.layoutRawValue) else {
            throw BookRepositoryError.invalidLayout(record.layoutRawValue)
        }
        let tagRecords = try activeTagRecords()
        let links = try context.fetch(FetchDescriptor<BookTagRecord>())
            .filter { $0.bookID == record.id && $0.deletedAt == nil }
        let tagsByID = tagRecords.reduce(into: [UUID: TagRecord]()) { result, tag in
            result[tag.id] = result[tag.id] ?? tag
        }
        let tags = links.compactMap { link -> Tag? in
            guard let tag = tagsByID[link.tagID] else {
                return nil
            }
            return Tag(id: tag.id, canonicalName: tag.canonicalName, displayName: tag.displayName)
        }

        return Book(
            id: record.id,
            contentHash: record.contentHash,
            title: record.title,
            authorsDisplay: record.authorsDisplay,
            mediaType: record.mediaType,
            layout: layout,
            fileRelativePath: record.fileRelativePath,
            progress: min(max(record.progress, 0), 1),
            status: status,
            tags: tags.sorted {
                $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            },
            importedAt: record.importedAt,
            lastOpenedAt: record.lastOpenedAt,
            coverRelativePath: record.coverRelativePath
        )
    }

    private static func sortBooks(_ lhs: Book, _ rhs: Book) -> Bool {
        let lhsDate = lhs.lastOpenedAt ?? lhs.importedAt
        let rhsDate = rhs.lastOpenedAt ?? rhs.importedAt
        if lhsDate != rhsDate {
            return lhsDate > rhsDate
        }
        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }
}
