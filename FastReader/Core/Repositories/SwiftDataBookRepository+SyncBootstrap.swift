import Foundation
import SwiftData

extension SwiftDataBookRepository {
    func queueUnsyncedLocalPublications(at date: Date) throws {
        var queuedKeys = try Set(syncJournal.snapshots().map(\.key))
        let books = try context.fetch(FetchDescriptor<BookRecord>())
        let activeBooks = books.filter { Self.isSyncable($0) && $0.deletedAt == nil }
        let activeBookIDs = Set(activeBooks.map(\.id))

        for record in activeBooks {
            let bookKey = LibrarySyncRecordKey.book(contentHash: record.contentHash)
            if queuedKeys.insert(bookKey).inserted {
                try syncJournal.queue(bookKey, action: .save, at: date)
            }
            let assetKey = LibrarySyncRecordKey.bookAsset(contentHash: record.contentHash)
            if queuedKeys.insert(assetKey).inserted {
                try syncJournal.queue(assetKey, action: .save, at: date)
            }
        }

        let tags = try context.fetch(FetchDescriptor<TagRecord>())
        let tagsByID = Dictionary(
            tags.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let booksByID = Dictionary(
            activeBooks.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let activeMemberships = try context.fetch(FetchDescriptor<BookTagRecord>())
            .filter { activeBookIDs.contains($0.bookID) && $0.deletedAt == nil }

        for membership in activeMemberships {
            guard let book = booksByID[membership.bookID],
                  let tag = tagsByID[membership.tagID],
                  tag.deletedAt == nil
            else {
                continue
            }
            let tagKey = LibrarySyncRecordKey.tag(canonicalName: tag.canonicalName)
            if queuedKeys.insert(tagKey).inserted {
                try syncJournal.queue(tagKey, action: .save, at: date)
            }
            let membershipKey = LibrarySyncRecordKey.bookTag(
                contentHash: book.contentHash,
                canonicalTagName: tag.canonicalName
            )
            if queuedKeys.insert(membershipKey).inserted {
                try syncJournal.queue(membershipKey, action: .save, at: date)
            }
        }
        try context.save()
    }

    func resetCloudStateForAccount(_ accountRecordName: String?, at date: Date) throws {
        try syncJournal.resetSystemFields(accountRecordName: accountRecordName, at: date)
        let books = try context.fetch(FetchDescriptor<BookRecord>())
        let syncableRecords = books.filter(Self.isSyncable)
        for record in syncableRecords {
            try syncJournal.queue(.book(contentHash: record.contentHash), action: .save, at: date)
            if record.deletedAt == nil {
                try syncJournal.queue(.bookAsset(contentHash: record.contentHash), action: .save, at: date)
            }
        }
        let tags = try context.fetch(FetchDescriptor<TagRecord>())
        let syncableBookIDs = Set(syncableRecords.map(\.id))
        let bookHashes = Dictionary(
            books.map { ($0.id, $0.contentHash) },
            uniquingKeysWith: { first, _ in first }
        )
        let tagNames = Dictionary(
            tags.map { ($0.id, $0.canonicalName) },
            uniquingKeysWith: { first, _ in first }
        )
        let memberships = try context.fetch(FetchDescriptor<BookTagRecord>())
            .filter { syncableBookIDs.contains($0.bookID) }
        let syncedTagIDs = Set(memberships.map(\.tagID))
        for tag in tags where syncedTagIDs.contains(tag.id) {
            try syncJournal.queue(.tag(canonicalName: tag.canonicalName), action: .save, at: date)
        }
        for membership in memberships {
            guard let hash = bookHashes[membership.bookID],
                  let tagName = tagNames[membership.tagID]
            else {
                continue
            }
            try syncJournal.queue(
                .bookTag(contentHash: hash, canonicalTagName: tagName),
                action: .save,
                at: date
            )
        }
        try context.save()
    }
}
