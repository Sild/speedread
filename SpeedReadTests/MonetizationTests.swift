import Foundation
@testable import SpeedRead
import Testing

private final class MonetizationTestBundleToken {}

@Suite("Monetization")
@MainActor
struct MonetizationTests {
    @Test("Free and Pro feature boundaries are explicit")
    func featurePolicy() {
        let free = ProAccessPolicy(hasProAccess: false)
        let pro = ProAccessPolicy(hasProAccess: true)

        #expect(ProFeature.allCases == [.unlimitedLibrary, .privateCloudSync])
        #expect(ProFeature.allCases.allSatisfy { !free.allows($0) })
        #expect(ProFeature.allCases.allSatisfy { pro.allows($0) })
        #expect(free.canAddBook(toLibraryCount: 0))
        #expect(free.canAddBook(toLibraryCount: 2))
        #expect(!free.canAddBook(toLibraryCount: 3))
        #expect(pro.canAddBook(toLibraryCount: 3))
        #expect(pro.canAddBook(toLibraryCount: 500))
    }

    @Test("Every product grants the same Pro access with reviewed prices")
    func purchasePaths() async {
        for product in ProProduct.allCases {
            let manager = PurchaseManager(testingMode: .free)
            await manager.start()
            #expect(manager.isReady)
            #expect(!manager.hasProAccess)
            #expect(manager.displayPrice(for: product) == product.testDisplayPrice)

            await manager.purchase(product)
            #expect(manager.hasProAccess)
            if product == .lifetime {
                #expect(manager.entitlement == .lifetime)
            } else {
                #expect(manager.entitlement == .subscription(product))
            }
        }
        let annual = PurchaseManager(testingMode: .free)
        await annual.start()
        #expect(annual.annualMonthlyEquivalent() == "$2.50")
    }

    @Test("Restore and reinstall recover Pro access")
    func restoreAndReinstall() async {
        let restored = PurchaseManager(testingMode: .free)
        await restored.start()
        await restored.restore()
        #expect(restored.entitlement == .lifetime)

        let reinstalled = PurchaseManager(testingMode: .annual)
        await reinstalled.start()
        #expect(reinstalled.entitlement == .subscription(.annual))
        #expect(reinstalled.hasProAccess)
    }

    @Test("Pending, cancelled, and unverified purchases never grant access")
    func incompletePurchaseStates() async {
        for mode in [
            PurchaseManager.TestingMode.pending,
            .cancelled,
            .verificationFailure
        ] {
            let manager = PurchaseManager(testingMode: mode)
            await manager.start()
            await manager.purchase(.annual)
            #expect(manager.entitlement == .free)
        }
    }

    @Test("Entitlement resolution rejects expired, revoked, and upgraded transactions")
    func entitlementResolution() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let activeAnnual = EntitlementRecord(
            product: .annual,
            expirationDate: now.addingTimeInterval(60),
            revocationDate: nil,
            isUpgraded: false
        )
        #expect(PurchaseManager.resolveEntitlement(from: [activeAnnual], now: now) == .subscription(.annual))

        let expired = EntitlementRecord(
            product: .annual,
            expirationDate: now,
            revocationDate: nil,
            isUpgraded: false
        )
        let revoked = EntitlementRecord(
            product: .lifetime,
            expirationDate: nil,
            revocationDate: now,
            isUpgraded: false
        )
        let upgraded = EntitlementRecord(
            product: .monthly,
            expirationDate: now.addingTimeInterval(60),
            revocationDate: nil,
            isUpgraded: true
        )
        #expect(PurchaseManager.resolveEntitlement(from: [expired, revoked, upgraded], now: now) == .free)

        let lifetime = EntitlementRecord(
            product: .lifetime,
            expirationDate: nil,
            revocationDate: nil,
            isUpgraded: false
        )
        #expect(PurchaseManager.resolveEntitlement(from: [activeAnnual, lifetime], now: now) == .lifetime)
    }

    @Test("Refund requests use the newest active subscription transaction")
    func refundTransactionSelection() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let olderMonthly = EntitlementRecord(
            product: .monthly,
            transactionID: 11,
            purchaseDate: now.addingTimeInterval(-60),
            expirationDate: now.addingTimeInterval(60),
            revocationDate: nil,
            isUpgraded: false
        )
        let newerAnnual = EntitlementRecord(
            product: .annual,
            transactionID: 22,
            purchaseDate: now.addingTimeInterval(-30),
            expirationDate: now.addingTimeInterval(120),
            revocationDate: nil,
            isUpgraded: false
        )
        let revoked = EntitlementRecord(
            product: .annual,
            transactionID: 33,
            purchaseDate: now,
            expirationDate: now.addingTimeInterval(120),
            revocationDate: now,
            isUpgraded: false
        )

        #expect(
            PurchaseManager.refundTransactionID(
                from: [olderMonthly, revoked, newerAnnual],
                now: now
            ) == 22
        )
        #expect(PurchaseManager.refundTransactionID(from: [revoked], now: now) == nil)
    }

    @Test("A product loading failure does not erase cached Pro access")
    func offlineEntitlement() async {
        let manager = PurchaseManager(testingMode: .offlineAnnual)
        await manager.start()

        #expect(manager.entitlement == .subscription(.annual))
        #expect(manager.hasProAccess)
        #expect(manager.displayPrice(for: .annual) == nil)
    }

    @Test("Free import rejects only a new fourth book and cleans staging")
    func freeImportLimit() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = InMemoryBookRepository()
        try seedBooks(3, in: repository)
        let fileStore = try ApplicationSupportBookFileStore(rootURL: root)
        let purchaseManager = PurchaseManager(testingMode: .free)
        await purchaseManager.start()
        let coordinator = ImportCoordinator(
            repository: repository,
            fileStore: fileStore,
            publicationService: ReadiumPublicationService(),
            purchaseManager: purchaseManager
        )

        await #expect(throws: ProAccessError.freeLibraryLimit) {
            _ = try await coordinator.importFile(at: fixture())
        }
        #expect(try repository.books(matching: LibraryFilter()).count == 3)
        #expect(try children(at: root.appending(path: "Staging")).isEmpty)
        #expect(try children(at: root.appending(path: "Books")).isEmpty)
    }

    @Test("Duplicate repair remains available at the free limit")
    func duplicateRepairAtLimit() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = InMemoryBookRepository()
        let fileStore = try ApplicationSupportBookFileStore(rootURL: root)
        let proManager = PurchaseManager(testingMode: .lifetime)
        await proManager.start()
        let proCoordinator = ImportCoordinator(
            repository: repository,
            fileStore: fileStore,
            publicationService: ReadiumPublicationService(),
            purchaseManager: proManager
        )
        let first = try await proCoordinator.importFile(at: fixture())
        let importedBookID = try #require(importedID(from: first))
        try seedBooks(2, in: repository)
        let storedBook = try repository.book(id: importedBookID)
        let book = try #require(storedBook)
        try await fileStore.remove(relativePaths: [book.fileRelativePath])

        let freeManager = PurchaseManager(testingMode: .free)
        await freeManager.start()
        let freeCoordinator = ImportCoordinator(
            repository: repository,
            fileStore: fileStore,
            publicationService: ReadiumPublicationService(),
            purchaseManager: freeManager
        )
        let outcome = try await freeCoordinator.importFile(at: fixture())

        #expect(outcome == .repaired(importedBookID))
        #expect(try repository.books(matching: LibraryFilter()).count == 3)
        #expect(await fileStore.fileExists(relativePath: book.fileRelativePath))
    }

    @Test("Deleting a free book immediately frees an import slot")
    func deletionFreesSlot() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = InMemoryBookRepository()
        try seedBooks(3, in: repository)
        let firstBook = try #require(repository.books(matching: LibraryFilter()).first)
        _ = try repository.delete(bookID: firstBook.id, at: .now)
        let purchaseManager = PurchaseManager(testingMode: .free)
        await purchaseManager.start()
        let coordinator = try ImportCoordinator(
            repository: repository,
            fileStore: ApplicationSupportBookFileStore(rootURL: root),
            publicationService: ReadiumPublicationService(),
            purchaseManager: purchaseManager
        )

        let outcome = try await coordinator.importFile(at: fixture())
        #expect(importedID(from: outcome) != nil)
        #expect(try repository.books(matching: LibraryFilter()).count == 3)
    }

    private func seedBooks(_ count: Int, in repository: InMemoryBookRepository) throws {
        for index in 0 ..< count {
            _ = try repository.insert(
                ImportedPublication(
                    contentHash: "seed-\(index)-\(UUID().uuidString)",
                    title: "Seed \(index)",
                    authorsDisplay: "",
                    mediaType: PublicationFormat.epub.defaultMediaType,
                    layout: .reflowable,
                    fileRelativePath: "Books/seed-\(index).epub",
                    coverRelativePath: nil,
                    fileByteCount: 1
                ),
                importedAt: .now
            )
        }
    }

    private func importedID(from outcome: ImportOutcome) -> UUID? {
        if case let .imported(id) = outcome {
            return id
        }
        return nil
    }

    private func fixture() throws -> URL {
        let bundle = Bundle(for: MonetizationTestBundleToken.self)
        guard let url = bundle.url(forResource: "epub3-cyrillic", withExtension: "epub") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return url
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "SpeedReadMonetizationTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private func children(at url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
    }
}
