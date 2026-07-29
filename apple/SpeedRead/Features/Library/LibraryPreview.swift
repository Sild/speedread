import Foundation
import SwiftUI

#Preview {
    let repository = InMemoryBookRepository()
    if let fileStore = try? ApplicationSupportBookFileStore(
        rootURL: FileManager.default.temporaryDirectory.appending(path: "SpeedReadPreview")
    ) {
        let purchaseManager = PurchaseManager(testingMode: .lifetime)
        let coordinator = ImportCoordinator(
            repository: repository,
            fileStore: fileStore,
            publicationService: ReadiumPublicationService(),
            purchaseManager: purchaseManager
        )
        RootView(
            repository: repository,
            progressStore: repository,
            fileStore: fileStore,
            publicationService: ReadiumPublicationService(),
            importCoordinator: coordinator,
            purchaseManager: purchaseManager,
            cloudSyncStatus: CloudSyncStatusModel(),
            cloudSyncCoordinator: nil
        )
    }
}
