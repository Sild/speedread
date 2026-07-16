import Foundation
import SwiftData

enum LibrarySyncStoreError: Error, Equatable, Sendable {
    case invalidBookStatus(String)
    case invalidPublicationLayout(String)
    case missingBook(String)
    case missingTag(String)
    case unsupportedMediaType(String)
}

enum RemoteAssetDisposition: Equatable, Sendable {
    case download
    case delete
}

struct RemoteBookCleanup: Equatable, Sendable {
    let contentHash: String
    let relativePaths: [String]
}

@MainActor
extension SwiftDataBookRepository {
    func cloudSyncState() throws -> CloudSyncStateSnapshot {
        try syncJournal.syncState()
    }

    func saveCloudSyncEngineState(
        _ data: Data?,
        accountRecordName: String?,
        at date: Date
    ) throws {
        try syncJournal.saveEngineState(data, accountRecordName: accountRecordName, at: date)
        try context.save()
    }

    func pendingCloudChanges() throws -> [CloudRecordStateSnapshot] {
        try syncJournal.snapshots().filter { $0.pendingAction != nil }
    }

    func hasPendingCloudWork() throws -> Bool {
        try syncJournal.snapshots().contains {
            $0.pendingAction != nil || $0.deferredRecordData != nil || $0.needsAssetDownload
        }
    }

    func pendingRemoteAssetDownloads() throws -> [LibrarySyncRecordKey] {
        try syncJournal.snapshots().compactMap { snapshot in
            guard snapshot.key.kind == .bookAsset, snapshot.needsAssetDownload else {
                return nil
            }
            return snapshot.key
        }
    }

    func syncRecord(for key: LibrarySyncRecordKey) throws -> LibrarySyncRecord? {
        switch key.kind {
        case .book:
            guard let book = try bookRecord(for: key) else {
                return nil
            }
            return try .book(syncedBook(book))
        case .bookAsset:
            guard let book = try bookRecord(for: key), book.deletedAt == nil else {
                return nil
            }
            return .bookAsset(
                SyncedBookAsset(contentHash: book.contentHash, fileByteCount: book.fileByteCount)
            )
        case .tag:
            guard let tag = try tagRecord(for: key) else {
                return nil
            }
            return .tag(syncedTag(tag))
        case .bookTag:
            guard let membership = try membershipRecord(for: key) else {
                return nil
            }
            return .bookTag(membership)
        }
    }

    @discardableResult
    func applyRemoteRecord(
        _ remote: LibrarySyncRecord,
        systemFieldsData: Data,
        accountRecordName: String?,
        at date: Date
    ) throws -> Bool {
        let needsUpload: Bool
        switch remote {
        case let .book(book):
            guard book.mediaType == PublicationFormat.epub.defaultMediaType else {
                throw LibrarySyncStoreError.unsupportedMediaType(book.mediaType)
            }
            needsUpload = try applyRemoteBook(book)
        case .bookAsset:
            needsUpload = false
        case let .tag(tag):
            needsUpload = try applyRemoteTag(tag)
        case let .bookTag(membership):
            needsUpload = try applyRemoteMembership(membership)
        }
        try syncJournal.storeRemoteState(
            for: remote.key,
            systemFieldsData: systemFieldsData,
            accountRecordName: accountRecordName,
            needsUpload: needsUpload,
            at: date
        )
        try context.save()
        return needsUpload
    }

    func markCloudRecordSent(
        _ key: LibrarySyncRecordKey,
        mutationID: String?,
        systemFieldsData: Data?,
        accountRecordName: String?,
        at date: Date
    ) throws {
        try syncJournal.markSent(
            key,
            mutationID: mutationID,
            systemFieldsData: systemFieldsData,
            accountRecordName: accountRecordName,
            at: date
        )
        try context.save()
    }

    func prepareRemoteAsset(
        _ asset: SyncedBookAsset,
        systemFieldsData: Data,
        accountRecordName: String?,
        at date: Date
    ) throws -> RemoteAssetDisposition {
        let book = try context.fetch(FetchDescriptor<BookRecord>())
            .first { $0.contentHash == asset.contentHash }
        let disposition: RemoteAssetDisposition = book?.deletedAt == nil ? .download : .delete
        try syncJournal.storeRemoteAssetState(
            for: asset.key,
            systemFieldsData: systemFieldsData,
            accountRecordName: accountRecordName,
            disposition: disposition,
            at: date
        )
        try context.save()
        return disposition
    }

    func markRemoteAssetDownloaded(_ key: LibrarySyncRecordKey, at date: Date) throws {
        try syncJournal.markAssetDownloaded(key, at: date)
        try context.save()
    }

    func deferRemoteMembership(
        _ membership: SyncedBookTag,
        systemFieldsData: Data,
        accountRecordName: String?,
        at date: Date
    ) throws {
        try syncJournal.storeDeferredRecord(
            for: membership.key,
            payloadData: JSONEncoder().encode(membership),
            systemFieldsData: systemFieldsData,
            accountRecordName: accountRecordName,
            at: date
        )
        try context.save()
    }

    @discardableResult
    func applyDeferredRemoteMemberships(at date: Date) throws -> Bool {
        var appliedAny = false
        for snapshot in try syncJournal.snapshots() {
            guard snapshot.key.kind == .bookTag,
                  let payload = snapshot.deferredRecordData,
                  let systemFieldsData = snapshot.systemFieldsData
            else {
                continue
            }
            let membership = try JSONDecoder().decode(SyncedBookTag.self, from: payload)
            do {
                _ = try applyRemoteRecord(
                    .bookTag(membership),
                    systemFieldsData: systemFieldsData,
                    accountRecordName: snapshot.accountRecordName,
                    at: date
                )
                appliedAny = true
            } catch LibrarySyncStoreError.missingBook(_), LibrarySyncStoreError.missingTag(_) {
                continue
            }
        }
        return appliedAny
    }

    func reconcileAssetForDeletedBook(contentHash: String, at date: Date) throws -> RemoteBookCleanup? {
        guard let record = try context.fetch(FetchDescriptor<BookRecord>())
            .first(where: { $0.contentHash == contentHash }),
            record.deletedAt != nil
        else {
            return nil
        }
        try syncJournal.queue(.bookAsset(contentHash: contentHash), action: .delete, at: date)
        try context.save()
        return RemoteBookCleanup(
            contentHash: contentHash,
            relativePaths: [record.fileRelativePath, record.coverRelativePath].compactMap(\.self)
        )
    }

    func markRemoteRecordDeleted(_ key: LibrarySyncRecordKey) throws {
        try syncJournal.removeState(for: key)
        try context.save()
    }

    func requeueCloudRecordIfPresent(_ key: LibrarySyncRecordKey, at date: Date) throws {
        guard try syncRecord(for: key) != nil else {
            return
        }
        try syncJournal.queue(key, action: .save, at: date)
        try context.save()
    }

    func shouldRemoveDownloadedEPUB(contentHash: String) throws -> Bool {
        try context.fetch(FetchDescriptor<BookRecord>())
            .first(where: { $0.contentHash == contentHash })?
            .deletedAt != nil
    }

    func attachDownloadedEPUB(
        contentHash: String,
        fileRelativePath: String,
        coverRelativePath: String?
    ) throws {
        guard let record = try context.fetch(FetchDescriptor<BookRecord>())
            .first(where: { $0.contentHash == contentHash })
        else {
            return
        }
        record.fileRelativePath = fileRelativePath
        record.coverRelativePath = coverRelativePath
        try context.save()
    }

    func resetCloudStateForAccount(_ accountRecordName: String?, at date: Date) throws {
        try syncJournal.resetSystemFields(accountRecordName: accountRecordName, at: date)
        let epubRecords = try context.fetch(FetchDescriptor<BookRecord>())
            .filter { $0.fileRelativePath.lowercased().hasSuffix(".epub") }
        for record in epubRecords {
            try syncJournal.queue(.book(contentHash: record.contentHash), action: .save, at: date)
            if record.deletedAt == nil {
                try syncJournal.queue(.bookAsset(contentHash: record.contentHash), action: .save, at: date)
            }
        }
        let books = try context.fetch(FetchDescriptor<BookRecord>())
        let tags = try context.fetch(FetchDescriptor<TagRecord>())
        let epubBookIDs = Set(
            books.lazy
                .filter { $0.fileRelativePath.lowercased().hasSuffix(".epub") }
                .map(\.id)
        )
        let bookHashes = Dictionary(
            books.map { ($0.id, $0.contentHash) },
            uniquingKeysWith: { first, _ in first }
        )
        let tagNames = Dictionary(
            tags.map { ($0.id, $0.canonicalName) },
            uniquingKeysWith: { first, _ in first }
        )
        let memberships = try context.fetch(FetchDescriptor<BookTagRecord>())
            .filter { epubBookIDs.contains($0.bookID) }
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

    private func applyRemoteBook(_ remote: SyncedBook) throws -> Bool {
        let records = try context.fetch(FetchDescriptor<BookRecord>())
        if let record = records.first(where: { $0.contentHash == remote.contentHash }) {
            let local = try syncedBook(record)
            guard let result = LibrarySyncMerge.book(local: local, remote: remote) else {
                return false
            }
            apply(result.value, to: record)
            return result.needsUpload
        }

        let record = BookRecord(
            id: UUID(),
            contentHash: remote.contentHash,
            title: remote.title,
            authorsDisplay: remote.authorsDisplay,
            mediaType: remote.mediaType,
            layout: remote.layout,
            fileRelativePath: "Books/\(remote.contentHash).epub",
            coverRelativePath: nil,
            fileByteCount: remote.fileByteCount,
            importedAt: remote.importedAt,
            status: remote.status
        )
        apply(remote, to: record)
        context.insert(record)
        return false
    }

    private func applyRemoteTag(_ remote: SyncedTag) throws -> Bool {
        let tags = try context.fetch(FetchDescriptor<TagRecord>())
        if let record = tags.first(where: { $0.canonicalName == remote.canonicalName }) {
            let result = LibrarySyncMerge.tag(local: syncedTag(record), remote: remote)
            guard let result else {
                return false
            }
            apply(result.value, to: record)
            return result.needsUpload
        }

        let record = TagRecord(
            id: UUID(),
            canonicalName: remote.canonicalName,
            displayName: remote.displayName,
            createdAt: remote.createdAt
        )
        apply(remote, to: record)
        context.insert(record)
        return false
    }

    private func applyRemoteMembership(_ remote: SyncedBookTag) throws -> Bool {
        let books = try context.fetch(FetchDescriptor<BookRecord>())
        guard let book = books.first(where: { $0.contentHash == remote.bookContentHash }) else {
            throw LibrarySyncStoreError.missingBook(remote.bookContentHash)
        }
        let tags = try context.fetch(FetchDescriptor<TagRecord>())
        guard let tag = tags.first(where: { $0.canonicalName == remote.canonicalTagName }) else {
            throw LibrarySyncStoreError.missingTag(remote.canonicalTagName)
        }
        let links = try context.fetch(FetchDescriptor<BookTagRecord>())
        if let record = links.first(where: { $0.bookID == book.id && $0.tagID == tag.id }) {
            let local = SyncedBookTag(
                bookContentHash: book.contentHash,
                canonicalTagName: tag.canonicalName,
                createdAt: record.createdAt,
                updatedAt: record.updatedAt,
                deletedAt: record.deletedAt
            )
            guard let result = LibrarySyncMerge.bookTag(local: local, remote: remote) else {
                return false
            }
            apply(result.value, to: record, bookID: book.id, tagID: tag.id)
            return result.needsUpload
        }

        let record = BookTagRecord(
            id: UUID(),
            bookID: book.id,
            tagID: tag.id,
            createdAt: remote.createdAt
        )
        apply(remote, to: record, bookID: book.id, tagID: tag.id)
        context.insert(record)
        return false
    }

    private func bookRecord(for key: LibrarySyncRecordKey) throws -> BookRecord? {
        try context.fetch(FetchDescriptor<BookRecord>())
            .first { LibrarySyncRecordKey.book(contentHash: $0.contentHash) == key }
    }

    private func tagRecord(for key: LibrarySyncRecordKey) throws -> TagRecord? {
        try context.fetch(FetchDescriptor<TagRecord>())
            .first { LibrarySyncRecordKey.tag(canonicalName: $0.canonicalName) == key }
    }

    private func membershipRecord(for key: LibrarySyncRecordKey) throws -> SyncedBookTag? {
        let books = try context.fetch(FetchDescriptor<BookRecord>())
        let tags = try context.fetch(FetchDescriptor<TagRecord>())
        let bookHashes = Dictionary(
            books.map { ($0.id, $0.contentHash) },
            uniquingKeysWith: { first, _ in first }
        )
        let tagNames = Dictionary(
            tags.map { ($0.id, $0.canonicalName) },
            uniquingKeysWith: { first, _ in first }
        )
        return try context.fetch(FetchDescriptor<BookTagRecord>())
            .compactMap { membership -> SyncedBookTag? in
                guard let hash = bookHashes[membership.bookID],
                      let tagName = tagNames[membership.tagID]
                else {
                    return nil
                }
                return SyncedBookTag(
                    bookContentHash: hash,
                    canonicalTagName: tagName,
                    createdAt: membership.createdAt,
                    updatedAt: membership.updatedAt,
                    deletedAt: membership.deletedAt
                )
            }
            .first { $0.key == key }
    }

    private func syncedBook(_ record: BookRecord) throws -> SyncedBook {
        guard let status = BookStatus(rawValue: record.statusRawValue) else {
            throw LibrarySyncStoreError.invalidBookStatus(record.statusRawValue)
        }
        guard let layout = PublicationLayout(rawValue: record.layoutRawValue) else {
            throw LibrarySyncStoreError.invalidPublicationLayout(record.layoutRawValue)
        }
        return SyncedBook(
            contentHash: record.contentHash,
            title: record.title,
            authorsDisplay: record.authorsDisplay,
            mediaType: record.mediaType,
            layout: layout,
            fileByteCount: record.fileByteCount,
            importedAt: record.importedAt,
            metadataUpdatedAt: record.metadataUpdatedAt,
            deletedAt: record.deletedAt,
            status: status,
            statusUpdatedAt: record.statusUpdatedAt,
            position: SyncedBookPosition(
                locatorJSON: record.locatorJSON,
                totalProgression: record.progress,
                speedElementID: record.speedElementID,
                speedTokenOffset: record.speedTokenOffset,
                updatedAt: record.positionUpdatedAt
            )
        )
    }

    private func syncedTag(_ record: TagRecord) -> SyncedTag {
        SyncedTag(
            canonicalName: record.canonicalName,
            displayName: record.displayName,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt,
            deletedAt: record.deletedAt
        )
    }

    private func apply(_ value: SyncedBook, to record: BookRecord) {
        record.contentHash = value.contentHash
        record.title = value.title
        record.authorsDisplay = value.authorsDisplay
        record.mediaType = value.mediaType
        record.layoutRawValue = value.layout.rawValue
        record.fileByteCount = value.fileByteCount
        record.importedAt = value.importedAt
        record.metadataUpdatedAt = value.metadataUpdatedAt
        record.deletedAt = value.deletedAt
        record.statusRawValue = value.status.rawValue
        record.statusUpdatedAt = value.statusUpdatedAt
        record.locatorJSON = value.position.locatorJSON
        record.progress = value.position.totalProgression
        record.speedElementID = value.position.speedElementID
        record.speedTokenOffset = value.position.speedTokenOffset
        record.positionUpdatedAt = value.position.updatedAt
    }

    private func apply(_ value: SyncedTag, to record: TagRecord) {
        record.canonicalName = value.canonicalName
        record.displayName = value.displayName
        record.createdAt = value.createdAt
        record.updatedAt = value.updatedAt
        record.deletedAt = value.deletedAt
    }

    private func apply(
        _ value: SyncedBookTag,
        to record: BookTagRecord,
        bookID: UUID,
        tagID: UUID
    ) {
        record.bookID = bookID
        record.tagID = tagID
        record.createdAt = value.createdAt
        record.updatedAt = value.updatedAt
        record.deletedAt = value.deletedAt
    }
}
