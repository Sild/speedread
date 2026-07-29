import Foundation
import Observation

enum CloudSyncStatus: Equatable, Sendable {
    case localOnly
    case syncing
    case upToDate(Date)
    case downloading(String)
    case accountChange(previousAccount: String, currentAccount: String)
    case retryableError
    case unavailable
}

@MainActor
@Observable
final class CloudSyncStatusModel {
    private(set) var status: CloudSyncStatus = .localOnly
    private(set) var libraryRevision = 0
    private(set) var localMutationRevision = 0

    func update(_ status: CloudSyncStatus) {
        self.status = status
    }

    func libraryDidChange() {
        libraryRevision += 1
    }

    func localMutationDidQueue() {
        localMutationRevision += 1
    }
}
