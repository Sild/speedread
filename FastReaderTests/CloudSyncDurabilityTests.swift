@testable import FastReader
import Foundation
import SwiftData
import Testing

@Suite("Private iCloud sync durability")
@MainActor
struct CloudSyncDurabilityTests {
    @Test("Saved EPUB and PDF mutations wake sync")
    func localMutationSignals() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let repository = SwiftDataBookRepository(modelContainer: container)
        var signals = 0
        repository.setCloudMutationHandler {
            signals += 1
        }

        let epub = try repository.insert(
            importedPublication(hash: "signal-epub", extension: "epub"),
            importedAt: date(1)
        )
        let pdf = try repository.insert(
            importedPublication(hash: "signal-pdf", extension: "pdf"),
            importedAt: date(2)
        )
        try repository.setStatus(.reading, for: epub.id, at: date(3))
        try repository.setStatus(.reading, for: pdf.id, at: date(4))

        #expect(signals == 4)
    }

    @Test("An asset received before its PDF book remains durable and resumes")
    func deferredPDFAsset() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let repository = SwiftDataBookRepository(modelContainer: container)
        let pendingAsset = SyncedBookAsset(contentHash: "pending-asset", fileByteCount: 42)

        let pendingDisposition = try repository.prepareRemoteAsset(
            pendingAsset,
            systemFieldsData: Data([1]),
            accountRecordName: "account",
            at: date(1)
        )
        #expect(pendingDisposition == .deferUntilBook)
        #expect(try repository.pendingRemoteAssetDownloads() == [pendingAsset.key])

        _ = try repository.applyRemoteRecord(
            .book(
                syncedBook(
                    contentHash: pendingAsset.contentHash,
                    format: .pdf,
                    title: "Remote PDF",
                    status: .new,
                    progression: 0,
                    timestamps: SyncedBookTimestamps(
                        metadata: date(2),
                        status: date(2),
                        position: date(2)
                    )
                )
            ),
            systemFieldsData: Data([2]),
            accountRecordName: "account",
            at: date(2)
        )
        let resumedDisposition = try repository.prepareRemoteAsset(
            pendingAsset,
            systemFieldsData: Data([3]),
            accountRecordName: "account",
            at: date(3)
        )
        #expect(resumedDisposition == .download(.pdf))

        try repository.markRemoteAssetDownloaded(pendingAsset.key, at: date(4))
        #expect(try repository.pendingRemoteAssetDownloads().isEmpty)
    }

    @Test("A tombstoned book requests remote asset deletion")
    func tombstonedBookAsset() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let repository = SwiftDataBookRepository(modelContainer: container)
        let book = try repository.insert(
            importedPublication(hash: "deleted-asset", extension: "epub"),
            importedAt: date(3)
        )
        _ = try repository.delete(bookID: book.id, at: date(4))
        let deletedAsset = SyncedBookAsset(contentHash: book.contentHash, fileByteCount: 42)
        let deletedDisposition = try repository.prepareRemoteAsset(
            deletedAsset,
            systemFieldsData: Data([4]),
            accountRecordName: "account",
            at: date(5)
        )
        let deletedState = try #require(
            repository.syncJournal.snapshots().first { $0.key == deletedAsset.key }
        )

        #expect(deletedDisposition == .delete)
        #expect(deletedState.pendingAction == .delete)
        #expect(!deletedState.needsAssetDownload)
    }

    @Test("Out-of-order memberships wait durably for their book and tag")
    func deferredMembershipDependencies() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let repository = SwiftDataBookRepository(modelContainer: container)
        let membership = SyncedBookTag(
            bookContentHash: "deferred-book",
            canonicalTagName: "deferred-tag",
            createdAt: date(1),
            updatedAt: date(2),
            deletedAt: nil
        )
        try repository.deferRemoteMembership(
            membership,
            systemFieldsData: Data([3]),
            accountRecordName: "account",
            at: date(3)
        )

        #expect(try repository.applyDeferredRemoteMemberships(at: date(4)) == false)
        try insertRemoteDependencies(for: membership, into: repository)

        #expect(try repository.applyDeferredRemoteMemberships(at: date(6)))
        let links = try container.mainContext.fetch(FetchDescriptor<BookTagRecord>())
        let state = try #require(
            repository.syncJournal.snapshots().first { $0.key == membership.key }
        )
        #expect(links.count == 1)
        #expect(state.deferredRecordData == nil)
    }

    private func insertRemoteDependencies(
        for membership: SyncedBookTag,
        into repository: SwiftDataBookRepository
    ) throws {
        _ = try repository.applyRemoteRecord(
            .book(
                syncedBook(
                    contentHash: membership.bookContentHash,
                    title: "Deferred book",
                    status: .new,
                    progression: 0,
                    timestamps: SyncedBookTimestamps(
                        metadata: date(5),
                        status: date(5),
                        position: date(5)
                    )
                )
            ),
            systemFieldsData: Data([4]),
            accountRecordName: "account",
            at: date(5)
        )
        _ = try repository.applyRemoteRecord(
            .tag(
                SyncedTag(
                    canonicalName: membership.canonicalTagName,
                    displayName: "Deferred Tag",
                    createdAt: date(1),
                    updatedAt: date(5),
                    deletedAt: nil
                )
            ),
            systemFieldsData: Data([5]),
            accountRecordName: "account",
            at: date(5)
        )
    }
}
