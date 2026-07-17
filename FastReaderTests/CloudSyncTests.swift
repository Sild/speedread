import CloudKit
@testable import FastReader
import Foundation
import SwiftData
import Testing

@Suite("Private iCloud sync")
@MainActor
struct CloudSyncTests {
    @Test("Wire identities are deterministic across local UUIDs")
    func deterministicRecordIdentities() {
        let first = LibrarySyncRecordKey.tag(canonicalName: "science fiction")
        let second = LibrarySyncRecordKey.tag(canonicalName: "science fiction")

        #expect(first == second)
        #expect(first.recordName.hasPrefix("tag-"))
        #expect(
            LibrarySyncRecordKey.bookTag(
                contentHash: "ABC123",
                canonicalTagName: "science fiction"
            ).recordName.hasPrefix("membership-abc123-")
        )
    }

    @Test("Book conflict groups merge independently")
    func independentBookConflictGroups() throws {
        let local = syncedBook(
            title: "Local metadata",
            status: .reading,
            progression: 0.2,
            timestamps: SyncedBookTimestamps(
                metadata: date(40),
                status: date(10),
                position: date(50)
            )
        )
        let remote = syncedBook(
            title: "Remote metadata",
            status: .done,
            progression: 0.9,
            timestamps: SyncedBookTimestamps(
                metadata: date(30),
                status: date(60),
                position: date(20)
            )
        )

        let result = try #require(LibrarySyncMerge.book(local: local, remote: remote))
        let reverse = try #require(LibrarySyncMerge.book(local: remote, remote: local))

        #expect(result.value.title == "Local metadata")
        #expect(result.value.status == .done)
        #expect(result.value.position.totalProgression == 0.2)
        #expect(result.needsUpload)
        #expect(reverse.value == result.value)
    }

    @Test("A newer membership tombstone wins")
    func membershipTombstoneWins() throws {
        let local = SyncedBookTag(
            bookContentHash: "book-hash",
            canonicalTagName: "favorite",
            createdAt: date(1),
            updatedAt: date(20),
            deletedAt: date(20)
        )
        let remote = SyncedBookTag(
            bookContentHash: "book-hash",
            canonicalTagName: "favorite",
            createdAt: date(2),
            updatedAt: date(10),
            deletedAt: nil
        )

        let result = try #require(LibrarySyncMerge.bookTag(local: local, remote: remote))

        #expect(result.value.deletedAt == date(20))
        #expect(result.needsUpload)
    }

    @Test("CloudKit encoding round-trips app-owned fields and deterministic identity")
    func cloudKitCodecRoundTrip() throws {
        let source = syncedBook(
            title: "Encoded",
            status: .reading,
            progression: 0.35,
            timestamps: SyncedBookTimestamps(
                metadata: date(20),
                status: date(30),
                position: date(40)
            )
        )
        let record = try CloudKitRecordCodec.makeRecord(
            from: .book(source),
            systemFieldsData: nil
        )
        let systemFields = CloudKitRecordCodec.encodeSystemFields(record)
        let updated = try CloudKitRecordCodec.makeRecord(
            from: .book(source),
            systemFieldsData: systemFields
        )
        let decoded = try CloudKitRecordCodec.decode(updated)

        #expect(decoded.record == .book(source))
        #expect(updated.recordID == CloudKitRecordCodec.recordID(for: source.key))
        #expect(decoded.assetURL == nil)
    }

    @Test("Downloaded publication staging preserves format, verifies bytes, and removes rejects")
    func downloadedAssetVerification() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "FastReaderCloudAssetTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fileStore = try ApplicationSupportBookFileStore(rootURL: root)
        let bundle = Bundle(for: CloudSyncTestBundleToken.self)
        let source = try #require(bundle.url(forResource: "epub3-cyrillic", withExtension: "epub"))
        let initialStage = try await fileStore.stage(sourceURL: source)
        let hash = try await fileStore.contentHash(of: initialStage)
        await fileStore.discard(stagedFile: initialStage)

        let downloaded = try await fileStore.stageDownloadedAsset(
            sourceURL: source,
            expectedContentHash: hash,
            format: .epub
        )
        #expect(try Data(contentsOf: downloaded.url) == Data(contentsOf: source))
        #expect(downloaded.url.pathExtension == "epub")
        await fileStore.discard(stagedFile: downloaded)

        let pdfSource = try #require(bundle.url(forResource: "pdf-cyrillic", withExtension: "pdf"))
        let pdfInitialStage = try await fileStore.stage(sourceURL: pdfSource)
        let pdfHash = try await fileStore.contentHash(of: pdfInitialStage)
        await fileStore.discard(stagedFile: pdfInitialStage)
        let downloadedPDF = try await fileStore.stageDownloadedAsset(
            sourceURL: pdfSource,
            expectedContentHash: pdfHash,
            format: .pdf
        )
        #expect(try Data(contentsOf: downloadedPDF.url) == Data(contentsOf: pdfSource))
        #expect(downloadedPDF.url.pathExtension == "pdf")
        await fileStore.discard(stagedFile: downloadedPDF)

        await #expect(
            throws: BookFileStoreError.contentHashMismatch(expected: "wrong", actual: hash)
        ) {
            _ = try await fileStore.stageDownloadedAsset(
                sourceURL: source,
                expectedContentHash: "wrong",
                format: .epub
            )
        }
        let staging = root.appending(path: "Staging", directoryHint: .isDirectory)
        #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
    }
}

@Suite("Private iCloud sync persistence")
@MainActor
struct CloudSyncPersistenceTests {
    @Test("Retained tags reuse their logical membership without a new mutation")
    func membershipIdentityIsStable() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let repository = SwiftDataBookRepository(modelContainer: container)
        let book = try repository.insert(
            importedPublication(hash: "tagged-hash", extension: "epub"),
            importedAt: date(1)
        )
        try repository.setTags(["Favorite"], for: book.id, at: date(2))
        let firstLinks = try container.mainContext.fetch(FetchDescriptor<BookTagRecord>())
        let firstMembership = try #require(
            repository.syncJournal.snapshots().first { $0.key.kind == .bookTag }
        )

        try repository.setTags([" favorite "], for: book.id, at: date(3))

        let secondLinks = try container.mainContext.fetch(FetchDescriptor<BookTagRecord>())
        let secondMembership = try #require(
            repository.syncJournal.snapshots().first { $0.key.kind == .bookTag }
        )
        #expect(firstLinks.count == 1)
        #expect(secondLinks.count == 1)
        #expect(firstLinks.first?.id == secondLinks.first?.id)
        #expect(firstMembership == secondMembership)
    }

    @Test("Deleting a PDF tombstones metadata and deletes only its immutable asset")
    func pdfDeletionJournal() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let repository = SwiftDataBookRepository(modelContainer: container)
        let book = try repository.insert(
            importedPublication(hash: "delete-hash", extension: "pdf"),
            importedAt: date(1)
        )
        try repository.setTags(["Archive"], for: book.id, at: date(2))

        _ = try repository.delete(bookID: book.id, at: date(3))

        let states = try repository.syncJournal.snapshots()
        #expect(states.first { $0.key.kind == .book }?.pendingAction == .save)
        #expect(states.first { $0.key.kind == .bookAsset }?.pendingAction == .delete)
        #expect(states.first { $0.key.kind == .tag }?.pendingAction == .save)
        #expect(states.first { $0.key.kind == .bookTag }?.pendingAction == .save)
    }

    @Test("Reimport clears the tombstone without duplicating the local book")
    func reimportTombstone() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let repository = SwiftDataBookRepository(modelContainer: container)
        let first = try repository.insert(
            importedPublication(hash: "reimport-hash", extension: "epub"),
            importedAt: date(1)
        )
        _ = try repository.delete(bookID: first.id, at: date(2))

        let reimported = try repository.insert(
            importedPublication(hash: "reimport-hash", extension: "epub"),
            importedAt: date(3)
        )

        let records = try container.mainContext.fetch(FetchDescriptor<BookRecord>())
        let assetState = try repository.syncJournal.snapshots()
            .first { $0.key.kind == .bookAsset }
        #expect(records.count == 1)
        #expect(reimported.id == first.id)
        #expect(records.first?.deletedAt == nil)
        #expect(assetState?.pendingAction == .save)
    }

    @Test("A completed send cannot clear a newer local mutation")
    func inFlightMutationSafety() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let repository = SwiftDataBookRepository(modelContainer: container)
        let book = try repository.insert(
            importedPublication(hash: "mutation-hash", extension: "epub"),
            importedAt: date(1)
        )
        let first = try #require(
            repository.pendingCloudChanges().first { $0.key.kind == .book }
        )
        try repository.setStatus(.reading, for: book.id, at: date(2))
        let second = try #require(
            repository.pendingCloudChanges().first { $0.key.kind == .book }
        )

        try repository.markCloudRecordSent(
            first.key,
            mutationID: first.mutationID,
            systemFieldsData: Data([1]),
            accountRecordName: "account",
            at: date(3)
        )
        let afterStaleSend = try repository.pendingCloudChanges()
        #expect(afterStaleSend.first { $0.key == first.key }?.mutationID == second.mutationID)

        try repository.markCloudRecordSent(
            second.key,
            mutationID: second.mutationID,
            systemFieldsData: Data([2]),
            accountRecordName: "account",
            at: date(4)
        )
        let afterCurrentSend = try repository.pendingCloudChanges()
        #expect(!afterCurrentSend.contains { $0.key == second.key })
    }

    @Test("Account reset reconstructs EPUB and PDF records with their tags")
    func accountResetIncludesSupportedPublications() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let repository = SwiftDataBookRepository(modelContainer: container)
        let epub = try repository.insert(
            importedPublication(hash: "account-epub", extension: "epub"),
            importedAt: date(1)
        )
        let pdf = try repository.insert(
            importedPublication(hash: "account-pdf", extension: "pdf"),
            importedAt: date(2)
        )
        try repository.setTags(["Cloud Tag"], for: epub.id, at: date(3))
        try repository.setTags(["Cloud PDF"], for: pdf.id, at: date(4))
        for snapshot in try repository.pendingCloudChanges() {
            try repository.markCloudRecordSent(
                snapshot.key,
                mutationID: snapshot.mutationID,
                systemFieldsData: nil,
                accountRecordName: "old",
                at: date(5)
            )
        }
        let orphanAsset = SyncedBookAsset(contentHash: "old-account-only", fileByteCount: 42)
        _ = try repository.prepareRemoteAsset(
            orphanAsset,
            systemFieldsData: Data([9]),
            accountRecordName: "old",
            at: date(5)
        )

        try repository.resetCloudStateForAccount("new", at: date(6))

        let pendingKeys = try repository.pendingCloudChanges().map(\.key)
        #expect(pendingKeys.contains(.tag(canonicalName: "cloud tag")))
        #expect(pendingKeys.contains(.tag(canonicalName: "cloud pdf")))
        #expect(pendingKeys.contains(.book(contentHash: "account-pdf")))
        #expect(pendingKeys.contains(.bookAsset(contentHash: "account-pdf")))
        let orphanState = try #require(
            repository.syncJournal.snapshots().first { $0.key == orphanAsset.key }
        )
        #expect(orphanState.pendingAction == nil)
        #expect(!orphanState.needsAssetDownload)
    }

    @Test("Remote merge preserves device-local relationship UUIDs")
    func remoteMergePreservesLocalIDs() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let repository = SwiftDataBookRepository(modelContainer: container)
        let book = try repository.insert(
            importedPublication(hash: "local-id-hash", extension: "epub"),
            importedAt: date(1)
        )
        try repository.setTags(["Favorite"], for: book.id, at: date(2))
        let originalTag = try #require(container.mainContext.fetch(FetchDescriptor<TagRecord>()).first)
        let originalLink = try #require(
            container.mainContext.fetch(FetchDescriptor<BookTagRecord>()).first
        )

        try applyRemoteIdentityUpdates(to: repository)

        let mergedBook = try #require(
            container.mainContext.fetch(FetchDescriptor<BookRecord>()).first
        )
        let mergedTag = try #require(
            container.mainContext.fetch(FetchDescriptor<TagRecord>()).first
        )
        let mergedLink = try #require(
            container.mainContext.fetch(FetchDescriptor<BookTagRecord>()).first
        )
        #expect(mergedBook.id == book.id)
        #expect(mergedTag.id == originalTag.id)
        #expect(mergedLink.id == originalLink.id)
        #expect(mergedBook.title == "Remote title")
        #expect(mergedTag.displayName == "Remote Favorite")
    }
}

struct SyncedBookTimestamps {
    let metadata: Date
    let status: Date
    let position: Date
}

func syncedBook(
    contentHash: String = "shared-hash",
    format: PublicationFormat = .epub,
    title: String,
    status: BookStatus,
    progression: Double,
    timestamps: SyncedBookTimestamps
) -> SyncedBook {
    SyncedBook(
        contentHash: contentHash,
        title: title,
        authorsDisplay: "Author",
        mediaType: format.defaultMediaType,
        layout: format.layout,
        fileByteCount: 42,
        importedAt: date(1),
        metadataUpdatedAt: timestamps.metadata,
        deletedAt: nil,
        status: status,
        statusUpdatedAt: timestamps.status,
        position: SyncedBookPosition(
            locatorJSON: "{\"href\":\"chapter.xhtml\"}",
            totalProgression: progression,
            speedElementID: nil,
            speedTokenOffset: nil,
            updatedAt: timestamps.position
        )
    )
}

func importedPublication(hash: String, extension pathExtension: String) -> ImportedPublication {
    ImportedPublication(
        contentHash: hash,
        title: hash,
        authorsDisplay: "Author",
        mediaType: pathExtension == "epub" ? "application/epub+zip" : "application/pdf",
        layout: pathExtension == "epub" ? .reflowable : .fixed,
        fileRelativePath: "Books/\(hash).\(pathExtension)",
        coverRelativePath: nil,
        fileByteCount: 42
    )
}

func date(_ seconds: TimeInterval) -> Date {
    Date(timeIntervalSince1970: seconds)
}

@MainActor
private func applyRemoteIdentityUpdates(to repository: SwiftDataBookRepository) throws {
    _ = try repository.applyRemoteRecord(
        .book(
            syncedBook(
                contentHash: "local-id-hash",
                title: "Remote title",
                status: .reading,
                progression: 0.4,
                timestamps: SyncedBookTimestamps(
                    metadata: date(20),
                    status: date(21),
                    position: date(22)
                )
            )
        ),
        systemFieldsData: Data([1]),
        accountRecordName: "account",
        at: date(23)
    )
    _ = try repository.applyRemoteRecord(
        .tag(
            SyncedTag(
                canonicalName: "favorite",
                displayName: "Remote Favorite",
                createdAt: date(1),
                updatedAt: date(20),
                deletedAt: nil
            )
        ),
        systemFieldsData: Data([2]),
        accountRecordName: "account",
        at: date(23)
    )
    _ = try repository.applyRemoteRecord(
        .bookTag(
            SyncedBookTag(
                bookContentHash: "local-id-hash",
                canonicalTagName: "favorite",
                createdAt: date(2),
                updatedAt: date(20),
                deletedAt: nil
            )
        ),
        systemFieldsData: Data([3]),
        accountRecordName: "account",
        at: date(23)
    )
}

private final class CloudSyncTestBundleToken {}
