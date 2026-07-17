import Foundation
import SwiftData

@MainActor
final class SwiftDataBookRepository: BookRepository, ReadingProgressStore {
    let context: ModelContext
    let syncJournal: CloudSyncJournal
    private var cloudMutationHandler: (() -> Void)?

    init(modelContainer: ModelContainer) {
        context = modelContainer.mainContext
        syncJournal = CloudSyncJournal(context: context)
    }

    func setCloudMutationHandler(_ handler: @escaping () -> Void) {
        cloudMutationHandler = handler
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

        let tombstones = try context.fetch(FetchDescriptor<BookRecord>())
            .filter { $0.contentHash == publication.contentHash && $0.deletedAt != nil }
        if let tombstone = tombstones.max(by: { $0.metadataUpdatedAt < $1.metadataUpdatedAt }) {
            tombstone.title = publication.title
            tombstone.authorsDisplay = publication.authorsDisplay
            tombstone.mediaType = publication.mediaType
            tombstone.layoutRawValue = publication.layout.rawValue
            tombstone.fileRelativePath = publication.fileRelativePath
            tombstone.coverRelativePath = publication.coverRelativePath
            tombstone.fileByteCount = publication.fileByteCount
            tombstone.metadataUpdatedAt = importedAt
            tombstone.deletedAt = nil
            try queueBook(tombstone, assetAction: .save, at: importedAt)
            try context.save()
            notifyCloudMutation(for: tombstone)
            return try makeBook(tombstone)
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
        try queueBook(record, assetAction: .save, at: importedAt)
        try context.save()
        notifyCloudMutation(for: record)
        return try makeBook(record)
    }

    func setStatus(_ status: BookStatus, for bookID: UUID, at date: Date) throws {
        let record = try requiredBookRecord(id: bookID)
        record.statusRawValue = status.rawValue
        record.statusUpdatedAt = date
        try queueBook(record, at: date)
        try context.save()
        notifyCloudMutation(for: record)
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
        try queueBook(record, at: position.updatedAt)
        try context.save()
        notifyCloudMutation(for: record)
    }

    private func activeBookRecords() throws -> [BookRecord] {
        try context.fetch(FetchDescriptor<BookRecord>()).filter { $0.deletedAt == nil }
    }

    private func activeTagRecords() throws -> [TagRecord] {
        try context.fetch(FetchDescriptor<TagRecord>()).filter { $0.deletedAt == nil }
    }

    func requiredBookRecord(id: UUID) throws -> BookRecord {
        guard let record = try activeBookRecords().first(where: { $0.id == id }) else {
            throw BookRepositoryError.missingBook(id)
        }
        return record
    }

    func makeBook(_ record: BookRecord) throws -> Book {
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

    func notifyCloudMutation(for record: BookRecord) {
        guard Self.isSyncable(record) else {
            return
        }
        cloudMutationHandler?()
    }
}
