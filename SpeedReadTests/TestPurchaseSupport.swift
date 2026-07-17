@testable import SpeedRead

@MainActor
extension ImportCoordinator {
    convenience init(
        repository: any BookRepository,
        fileStore: any BookFileStore,
        publicationService: any PublicationService
    ) {
        self.init(
            repository: repository,
            fileStore: fileStore,
            publicationService: publicationService,
            purchaseManager: PurchaseManager(testingMode: .lifetime)
        )
    }
}
