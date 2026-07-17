import SwiftUI

struct RootView: View {
    let repository: any BookRepository
    let progressStore: any ReadingProgressStore
    let fileStore: any BookFileStore
    let publicationService: any PublicationService
    let importCoordinator: ImportCoordinator
    let purchaseManager: PurchaseManager
    let cloudSyncStatus: CloudSyncStatusModel
    let cloudSyncCoordinator: CloudKitSyncCoordinator?

    var body: some View {
        NavigationStack {
            LibraryView(
                repository: repository,
                progressStore: progressStore,
                fileStore: fileStore,
                publicationService: publicationService,
                importCoordinator: importCoordinator,
                purchaseManager: purchaseManager,
                cloudSyncStatus: cloudSyncStatus,
                cloudSyncCoordinator: cloudSyncCoordinator
            )
        }
        .tint(SpeedReadPalette.focus)
    }
}
