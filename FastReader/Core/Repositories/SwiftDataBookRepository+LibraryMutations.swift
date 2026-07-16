import Foundation
import SwiftData

@MainActor
extension SwiftDataBookRepository {
    func setTags(_ displayNames: [String], for bookID: UUID, at date: Date) throws {
        let bookRecord = try requiredBookRecord(id: bookID)
        let requested = try requestedTags(displayNames)
        var tagState = try TagMutationState(
            records: context.fetch(FetchDescriptor<TagRecord>()),
            changed: []
        )
        var allLinks = try context.fetch(FetchDescriptor<BookTagRecord>())
        let tagsByCanonical = canonicalTagRecords(tagState.records)
        var changedLinks = retireRemovedMemberships(
            from: allLinks,
            for: bookID,
            requested: requested,
            tags: tagState.records,
            at: date
        )

        for (canonical, displayName) in requested {
            let tag = upsertTag(
                canonicalName: canonical,
                displayName: displayName,
                existing: tagsByCanonical[canonical],
                state: &tagState,
                at: date
            )
            upsertMembership(
                bookID: bookID,
                tagID: tag.id,
                allLinks: &allLinks,
                changedLinks: &changedLinks,
                at: date
            )
        }

        tagState.changed.append(
            contentsOf: retireOrphanedTags(tagState.records, activeLinks: allLinks, at: date)
        )
        if Self.isSyncable(bookRecord) {
            try queueTags(tagState.changed, at: date)
            try queueMemberships(
                changedLinks,
                bookContentHash: bookRecord.contentHash,
                tagRecords: tagState.records,
                at: date
            )
        }
        try context.save()
        notifyCloudMutation(for: bookRecord)
    }

    func delete(bookID: UUID, at date: Date) throws -> Book {
        let record = try requiredBookRecord(id: bookID)
        let book = try makeBook(record)
        record.deletedAt = date
        record.metadataUpdatedAt = date
        let tagRecords = try context.fetch(FetchDescriptor<TagRecord>())
        let allLinks = try context.fetch(FetchDescriptor<BookTagRecord>())
        let links = allLinks.filter { $0.bookID == bookID && $0.deletedAt == nil }
        for link in links {
            link.deletedAt = date
            link.updatedAt = date
        }
        let retiredTags = retireOrphanedTags(tagRecords, activeLinks: allLinks, at: date)
        try queueBook(record, assetAction: .delete, at: date)
        if Self.isSyncable(record) {
            try queueTags(retiredTags, at: date)
            try queueMemberships(
                links,
                bookContentHash: record.contentHash,
                tagRecords: tagRecords,
                at: date
            )
        }
        try context.save()
        notifyCloudMutation(for: record)
        return book
    }

    func queueBook(
        _ record: BookRecord,
        assetAction: CloudPendingAction? = nil,
        at date: Date
    ) throws {
        guard Self.isSyncable(record) else {
            return
        }
        try syncJournal.queue(.book(contentHash: record.contentHash), action: .save, at: date)
        if let assetAction {
            try syncJournal.queue(.bookAsset(contentHash: record.contentHash), action: assetAction, at: date)
        }
    }

    private func requestedTags(_ displayNames: [String]) throws -> [String: String] {
        var requested: [String: String] = [:]
        for displayName in displayNames {
            let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            let canonical = TagNormalizer.canonicalize(trimmed)
            guard !canonical.isEmpty else {
                throw BookRepositoryError.emptyTag
            }
            requested[canonical] = requested[canonical] ?? trimmed
        }
        return requested
    }

    private func canonicalTagRecords(_ records: [TagRecord]) -> [String: TagRecord] {
        records.sorted(by: Self.sortTagsForIdentity).reduce(into: [:]) { result, tag in
            result[tag.canonicalName] = result[tag.canonicalName] ?? tag
        }
    }

    private func retireRemovedMemberships(
        from links: [BookTagRecord],
        for bookID: UUID,
        requested: [String: String],
        tags: [TagRecord],
        at date: Date
    ) -> [BookTagRecord] {
        var changed: [BookTagRecord] = []
        for link in links where link.bookID == bookID && link.deletedAt == nil {
            guard let tag = tags.first(where: { $0.id == link.tagID }),
                  requested[tag.canonicalName] == nil
            else {
                continue
            }
            link.deletedAt = date
            link.updatedAt = date
            changed.append(link)
        }
        return changed
    }

    private func upsertTag(
        canonicalName: String,
        displayName: String,
        existing: TagRecord?,
        state: inout TagMutationState,
        at date: Date
    ) -> TagRecord {
        if let existing {
            if existing.deletedAt != nil {
                existing.deletedAt = nil
                existing.updatedAt = date
                state.changed.append(existing)
            }
            return existing
        }
        let tag = TagRecord(
            id: UUID(),
            canonicalName: canonicalName,
            displayName: displayName,
            createdAt: date
        )
        context.insert(tag)
        state.records.append(tag)
        state.changed.append(tag)
        return tag
    }

    private func upsertMembership(
        bookID: UUID,
        tagID: UUID,
        allLinks: inout [BookTagRecord],
        changedLinks: inout [BookTagRecord],
        at date: Date
    ) {
        let matching = allLinks
            .filter { $0.bookID == bookID && $0.tagID == tagID }
            .sorted(by: Self.sortLinksForIdentity)
        guard let retained = matching.first else {
            let link = BookTagRecord(id: UUID(), bookID: bookID, tagID: tagID, createdAt: date)
            context.insert(link)
            allLinks.append(link)
            changedLinks.append(link)
            return
        }
        if retained.deletedAt != nil {
            retained.deletedAt = nil
            retained.updatedAt = date
            changedLinks.append(retained)
        }
        for duplicate in matching.dropFirst() where duplicate.deletedAt == nil {
            duplicate.deletedAt = date
            duplicate.updatedAt = date
            changedLinks.append(duplicate)
        }
    }

    private func retireOrphanedTags(
        _ tagRecords: [TagRecord],
        activeLinks: [BookTagRecord],
        at date: Date
    ) -> [TagRecord] {
        let activeTagIDs = Set(activeLinks.lazy.filter { $0.deletedAt == nil }.map(\.tagID))
        var retired: [TagRecord] = []
        for tag in tagRecords where tag.deletedAt == nil && !activeTagIDs.contains(tag.id) {
            tag.deletedAt = date
            tag.updatedAt = date
            retired.append(tag)
        }
        return retired
    }

    private func queueTags(_ records: [TagRecord], at date: Date) throws {
        for record in records {
            try syncJournal.queue(.tag(canonicalName: record.canonicalName), action: .save, at: date)
        }
    }

    private func queueMemberships(
        _ records: [BookTagRecord],
        bookContentHash: String,
        tagRecords: [TagRecord],
        at date: Date
    ) throws {
        let canonicalNamesByID = Dictionary(
            tagRecords.map { ($0.id, $0.canonicalName) },
            uniquingKeysWith: { first, _ in first }
        )
        for record in records {
            guard let canonicalName = canonicalNamesByID[record.tagID] else {
                continue
            }
            try syncJournal.queue(
                .bookTag(contentHash: bookContentHash, canonicalTagName: canonicalName),
                action: .save,
                at: date
            )
        }
    }

    static func isSyncable(_ record: BookRecord) -> Bool {
        URL(fileURLWithPath: record.fileRelativePath).pathExtension.lowercased() == "epub"
    }

    private static func sortTagsForIdentity(_ lhs: TagRecord, _ rhs: TagRecord) -> Bool {
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func sortLinksForIdentity(_ lhs: BookTagRecord, _ rhs: BookTagRecord) -> Bool {
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

private struct TagMutationState {
    var records: [TagRecord]
    var changed: [TagRecord]
}
