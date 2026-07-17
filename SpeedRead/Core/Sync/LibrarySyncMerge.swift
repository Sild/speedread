import Foundation

struct LibrarySyncMergeResult<Value: Equatable & Sendable>: Equatable, Sendable {
    let value: Value
    let needsUpload: Bool
}

enum LibrarySyncMerge {
    static func book(
        local: SyncedBook,
        remote: SyncedBook
    ) -> LibrarySyncMergeResult<SyncedBook>? {
        guard local.contentHash == remote.contentHash else {
            return nil
        }

        let metadata = choose(
            local: BookMetadata(book: local),
            remote: BookMetadata(book: remote),
            localDate: local.metadataUpdatedAt,
            remoteDate: remote.metadataUpdatedAt,
            fingerprint: \BookMetadata.fingerprint
        )
        let status = choose(
            local: BookStatusGroup(book: local),
            remote: BookStatusGroup(book: remote),
            localDate: local.statusUpdatedAt,
            remoteDate: remote.statusUpdatedAt,
            fingerprint: \BookStatusGroup.fingerprint
        )
        let position = choose(
            local: local.position,
            remote: remote.position,
            localDate: local.position.updatedAt,
            remoteDate: remote.position.updatedAt,
            fingerprint: \SyncedBookPosition.fingerprint
        )
        let merged = SyncedBook(
            contentHash: local.contentHash,
            title: metadata.title,
            authorsDisplay: metadata.authorsDisplay,
            mediaType: metadata.mediaType,
            layout: metadata.layout,
            fileByteCount: metadata.fileByteCount,
            importedAt: metadata.importedAt,
            metadataUpdatedAt: metadata.updatedAt,
            deletedAt: metadata.deletedAt,
            status: status.status,
            statusUpdatedAt: status.updatedAt,
            position: position
        )
        return LibrarySyncMergeResult(value: merged, needsUpload: merged != remote)
    }

    static func tag(
        local: SyncedTag,
        remote: SyncedTag
    ) -> LibrarySyncMergeResult<SyncedTag>? {
        guard local.canonicalName == remote.canonicalName else {
            return nil
        }
        let selected = choose(
            local: local,
            remote: remote,
            localDate: local.updatedAt,
            remoteDate: remote.updatedAt,
            fingerprint: \SyncedTag.fingerprint
        )
        let merged = SyncedTag(
            canonicalName: selected.canonicalName,
            displayName: selected.displayName,
            createdAt: min(local.createdAt, remote.createdAt),
            updatedAt: selected.updatedAt,
            deletedAt: selected.deletedAt
        )
        return LibrarySyncMergeResult(value: merged, needsUpload: merged != remote)
    }

    static func bookTag(
        local: SyncedBookTag,
        remote: SyncedBookTag
    ) -> LibrarySyncMergeResult<SyncedBookTag>? {
        guard local.bookContentHash == remote.bookContentHash,
              local.canonicalTagName == remote.canonicalTagName
        else {
            return nil
        }
        let selected = choose(
            local: local,
            remote: remote,
            localDate: local.updatedAt,
            remoteDate: remote.updatedAt,
            fingerprint: \SyncedBookTag.fingerprint
        )
        let merged = SyncedBookTag(
            bookContentHash: local.bookContentHash,
            canonicalTagName: local.canonicalTagName,
            createdAt: min(local.createdAt, remote.createdAt),
            updatedAt: selected.updatedAt,
            deletedAt: selected.deletedAt
        )
        return LibrarySyncMergeResult(value: merged, needsUpload: merged != remote)
    }

    private static func choose<Value: Equatable>(
        local: Value,
        remote: Value,
        localDate: Date,
        remoteDate: Date,
        fingerprint: (Value) -> String
    ) -> Value {
        if localDate != remoteDate {
            return localDate > remoteDate ? local : remote
        }
        return fingerprint(local) < fingerprint(remote) ? remote : local
    }
}

private struct BookMetadata: Codable, Equatable {
    let title: String
    let authorsDisplay: String
    let mediaType: String
    let layout: PublicationLayout
    let fileByteCount: Int64
    let importedAt: Date
    let updatedAt: Date
    let deletedAt: Date?

    init(book: SyncedBook) {
        title = book.title
        authorsDisplay = book.authorsDisplay
        mediaType = book.mediaType
        layout = book.layout
        fileByteCount = book.fileByteCount
        importedAt = book.importedAt
        updatedAt = book.metadataUpdatedAt
        deletedAt = book.deletedAt
    }

    var fingerprint: String {
        [
            title,
            authorsDisplay,
            mediaType,
            layout.rawValue,
            String(fileByteCount),
            importedAt.syncFingerprint,
            deletedAt?.syncFingerprint ?? ""
        ].joined(separator: "\u{1F}")
    }
}

private struct BookStatusGroup: Codable, Equatable {
    let status: BookStatus
    let updatedAt: Date

    init(book: SyncedBook) {
        status = book.status
        updatedAt = book.statusUpdatedAt
    }

    var fingerprint: String {
        status.rawValue
    }
}

private extension SyncedBookPosition {
    var fingerprint: String {
        [
            locatorJSON ?? "",
            String(totalProgression),
            speedElementID ?? "",
            speedTokenOffset.map(String.init) ?? ""
        ].joined(separator: "\u{1F}")
    }
}

private extension SyncedTag {
    var fingerprint: String {
        [
            canonicalName,
            displayName,
            createdAt.syncFingerprint,
            deletedAt?.syncFingerprint ?? ""
        ].joined(separator: "\u{1F}")
    }
}

private extension SyncedBookTag {
    var fingerprint: String {
        [
            bookContentHash,
            canonicalTagName,
            createdAt.syncFingerprint,
            deletedAt?.syncFingerprint ?? ""
        ].joined(separator: "\u{1F}")
    }
}

private extension Date {
    var syncFingerprint: String {
        String(timeIntervalSinceReferenceDate)
    }
}
