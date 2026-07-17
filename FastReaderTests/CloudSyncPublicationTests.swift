@testable import FastReader
import Foundation
import Testing

@Suite("Private iCloud publication sync persistence")
@MainActor
struct CloudSyncPublicationTests {
    @Test("EPUB and PDF mutations queue durable records")
    func publicationOutbox() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let repository = SwiftDataBookRepository(modelContainer: container)
        let epub = try repository.insert(
            importedPublication(hash: "epub-hash", extension: "epub"),
            importedAt: date(1)
        )
        let afterEPUB = try repository.syncJournal.snapshots()

        #expect(afterEPUB.count == 2)
        #expect(afterEPUB.map(\.key.kind).sorted(by: { $0.rawValue < $1.rawValue }) == [.book, .bookAsset])
        #expect(afterEPUB.allSatisfy { $0.pendingAction == .save })

        let pdf = try repository.insert(
            importedPublication(hash: "pdf-hash", extension: "pdf"),
            importedAt: date(2)
        )
        try repository.setTags(["Synced PDF"], for: pdf.id, at: date(3))

        let afterPDF = try repository.syncJournal.snapshots()
        #expect(afterPDF.count == 6)
        #expect(afterPDF.first { $0.key == .book(contentHash: "pdf-hash") }?.pendingAction == .save)
        #expect(afterPDF.first { $0.key == .bookAsset(contentHash: "pdf-hash") }?.pendingAction == .save)
        #expect(afterPDF.first { $0.key.kind == .tag }?.pendingAction == .save)
        #expect(afterPDF.first { $0.key.kind == .bookTag }?.pendingAction == .save)

        try repository.setStatus(.reading, for: epub.id, at: date(4))
        let bookState = try #require(
            repository.syncJournal.snapshots().first { $0.key.kind == .book }
        )
        #expect(bookState.pendingAction == .save)
        #expect(bookState.mutationID != afterEPUB.first { $0.key.kind == .book }?.mutationID)
    }

    @Test("Startup backfills existing local PDFs exactly once")
    func existingPDFBackfill() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let repository = SwiftDataBookRepository(modelContainer: container)
        let pdf = try repository.insert(
            importedPublication(hash: "legacy-pdf", extension: "pdf"),
            importedAt: date(1)
        )
        try repository.setTags(["Reference"], for: pdf.id, at: date(2))
        for snapshot in try repository.syncJournal.snapshots() {
            try repository.syncJournal.removeState(for: snapshot.key)
        }
        try container.mainContext.save()

        try repository.queueUnsyncedLocalPublications(at: date(3))
        let firstBackfill = try repository.syncJournal.snapshots()
        try repository.queueUnsyncedLocalPublications(at: date(4))

        #expect(firstBackfill.count == 4)
        #expect(firstBackfill.contains { $0.key == .book(contentHash: "legacy-pdf") })
        #expect(firstBackfill.contains { $0.key == .bookAsset(contentHash: "legacy-pdf") })
        #expect(firstBackfill.contains { $0.key == .tag(canonicalName: "reference") })
        #expect(
            firstBackfill.contains {
                $0.key == .bookTag(contentHash: "legacy-pdf", canonicalTagName: "reference")
            }
        )
        #expect(try repository.syncJournal.snapshots() == firstBackfill)
    }

    @Test("Queued EPUB and PDF assets resolve to upload records")
    func publicationAssetRecordResolution() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let repository = SwiftDataBookRepository(modelContainer: container)
        _ = try repository.insert(
            importedPublication(hash: "asset-hash", extension: "epub"),
            importedAt: date(1)
        )
        _ = try repository.insert(
            importedPublication(hash: "pdf-asset-hash", extension: "pdf"),
            importedAt: date(2)
        )

        let record = try repository.syncRecord(
            for: .bookAsset(contentHash: "asset-hash")
        )
        #expect(
            record == .bookAsset(
                SyncedBookAsset(contentHash: "asset-hash", fileByteCount: 42)
            )
        )
        let pdfRecord = try repository.syncRecord(
            for: .bookAsset(contentHash: "pdf-asset-hash")
        )
        #expect(
            pdfRecord == .bookAsset(
                SyncedBookAsset(contentHash: "pdf-asset-hash", fileByteCount: 42)
            )
        )
    }

    @Test("Remote PDF metadata creates the format-correct local path")
    func remotePDFMetadata() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let repository = SwiftDataBookRepository(modelContainer: container)
        let remote = syncedBook(
            contentHash: "remote-pdf",
            format: .pdf,
            title: "Remote PDF",
            status: .reading,
            progression: 0.3,
            timestamps: SyncedBookTimestamps(
                metadata: date(10),
                status: date(11),
                position: date(12)
            )
        )

        _ = try repository.applyRemoteRecord(
            .book(remote),
            systemFieldsData: Data([1]),
            accountRecordName: "account",
            at: date(13)
        )

        let storedBook = try repository.book(contentHash: "remote-pdf")
        let book = try #require(storedBook)
        #expect(book.fileRelativePath == "Books/remote-pdf.pdf")
        #expect(book.mediaType == PublicationFormat.pdf.defaultMediaType)
        #expect(book.layout == .fixed)
    }
}
