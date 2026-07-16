import CloudKit
import Foundation

enum CloudKitSyncCoordinatorError: Error, Equatable, Sendable {
    case missingAsset
    case assetByteCountMismatch(expected: Int64, actual: Int64)
}

actor CloudKitSyncCoordinator: CKSyncEngineDelegate {
    let repository: SwiftDataBookRepository
    let fileStore: any BookFileStore
    let publicationService: any PublicationService
    let statusModel: CloudSyncStatusModel
    let container: CKContainer

    var engine: CKSyncEngine?
    var accountRecordName: String?
    var pendingAccountChange: (previous: String, current: String)?
    var inFlightMutations: [String: String] = [:]

    init(
        repository: SwiftDataBookRepository,
        fileStore: any BookFileStore,
        publicationService: any PublicationService,
        statusModel: CloudSyncStatusModel,
        container: CKContainer = CKContainer(identifier: "iCloud.com.sild.fastreader")
    ) {
        self.repository = repository
        self.fileStore = fileStore
        self.publicationService = publicationService
        self.statusModel = statusModel
        self.container = container
    }

    func start() async {
        await statusModel.update(.syncing)
        do {
            let storedState = try await repository.cloudSyncState()
            let accountStatus = try await container.accountStatus()
            guard accountStatus == .available else {
                await statusModel.update(.localOnly)
                return
            }
            let currentAccount = try await container.userRecordID().recordName
            let previousAccount = storedState.accountRecordName
            if let previousAccount, previousAccount != currentAccount {
                pendingAccountChange = (previousAccount, currentAccount)
                await statusModel.update(
                    .accountChange(
                        previousAccount: previousAccount,
                        currentAccount: currentAccount
                    )
                )
                return
            }

            pendingAccountChange = nil
            accountRecordName = currentAccount
            try await configureEngine(stateData: storedState.engineStateData)
            try await repository.saveCloudSyncEngineState(
                storedState.engineStateData,
                accountRecordName: currentAccount,
                at: .now
            )
            try await synchronize()
        } catch {
            await report(error)
        }
    }

    func stop() async {
        if let engine {
            await engine.cancelOperations()
        }
        engine = nil
        inFlightMutations.removeAll()
    }

    func retry() async {
        if engine == nil {
            await start()
            return
        }
        do {
            try await synchronize()
        } catch {
            await report(error)
        }
    }

    func sendQueuedLocalChanges() async {
        do {
            try await ContinuousClock().sleep(for: .milliseconds(350))
            try Task.checkCancellation()
            guard pendingAccountChange == nil, let engine else {
                return
            }
            await statusModel.update(.syncing)
            try await enqueueDurableChanges(in: engine)
            try await engine.sendChanges()
        } catch is CancellationError {
            return
        } catch {
            await report(error)
        }
    }

    func confirmUseWithNewAccount() async {
        guard let change = pendingAccountChange else {
            return
        }
        do {
            guard try await container.accountStatus() == .available else {
                await statusModel.update(.localOnly)
                return
            }
            let currentAccount = try await container.userRecordID().recordName
            guard currentAccount == change.current else {
                pendingAccountChange = nil
                await start()
                return
            }

            await stop()
            let now = Date.now
            try await repository.resetCloudStateForAccount(currentAccount, at: now)
            accountRecordName = currentAccount
            pendingAccountChange = nil
            try await configureEngine(stateData: nil)
            try await synchronize()
        } catch {
            await report(error)
        }
    }

    func enqueueDurableChanges(in engine: CKSyncEngine) async throws {
        let pending: [CKSyncEngine.PendingRecordZoneChange] = try await repository
            .pendingCloudChanges()
            .compactMap { snapshot in
                guard let action = snapshot.pendingAction else {
                    return nil
                }
                let id = CloudKitRecordCodec.recordID(for: snapshot.key)
                switch action {
                case .save:
                    return CKSyncEngine.PendingRecordZoneChange.saveRecord(id)
                case .delete:
                    return CKSyncEngine.PendingRecordZoneChange.deleteRecord(id)
                }
            }
        engine.state.add(pendingRecordZoneChanges: pending)
    }

    func recordToSave(for id: CKRecord.ID, syncEngine: CKSyncEngine) async -> CKRecord? {
        guard pendingAccountChange == nil, engine === syncEngine else {
            return nil
        }
        do {
            let snapshots = try await repository.pendingCloudChanges()
            guard let snapshot = snapshots.first(where: { $0.key.recordName == id.recordName }),
                  let value = try await repository.syncRecord(for: snapshot.key)
            else {
                return nil
            }
            let assetURL: URL?
            if case let .bookAsset(asset) = value {
                guard let book = try await repository.book(contentHash: asset.contentHash) else {
                    return nil
                }
                assetURL = try await fileStore.fileURL(relativePath: book.fileRelativePath)
            } else {
                assetURL = nil
            }
            return try CloudKitRecordCodec.makeRecord(
                from: value,
                systemFieldsData: snapshot.systemFieldsData,
                assetURL: assetURL
            )
        } catch {
            await report(error)
            return nil
        }
    }

    func report(_ error: any Error) async {
        if let cloudError = error as? CKError {
            switch cloudError.code {
            case .networkFailure, .networkUnavailable, .requestRateLimited,
                 .serviceUnavailable, .zoneBusy, .operationCancelled:
                await statusModel.update(.retryableError)
            case .notAuthenticated:
                await statusModel.update(.localOnly)
            default:
                await statusModel.update(.unavailable)
            }
        } else {
            await statusModel.update(.retryableError)
        }
    }

    private func configureEngine(stateData: Data?) async throws {
        let serialization: CKSyncEngine.State.Serialization? = if let stateData {
            try JSONDecoder().decode(
                CKSyncEngine.State.Serialization.self,
                from: stateData
            )
        } else {
            nil
        }
        var configuration = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase,
            stateSerialization: serialization,
            delegate: self
        )
        configuration.automaticallySync = true
        configuration.subscriptionID = "FastReaderLibraryChanges"
        let engine = CKSyncEngine(configuration)
        self.engine = engine
        engine.state.add(
            pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: CloudKitRecordCodec.zoneID))]
        )
        try await enqueueDurableChanges(in: engine)
    }

    private func synchronize() async throws {
        guard pendingAccountChange == nil, let engine else {
            return
        }
        await statusModel.update(.syncing)
        if try await repository.applyDeferredRemoteMemberships(at: .now) {
            await statusModel.libraryDidChange()
        }
        await retryPendingAssetDownloads()
        try await enqueueDurableChanges(in: engine)
        try await engine.fetchChanges()
        try await enqueueDurableChanges(in: engine)
        try await engine.sendChanges()
        if try await repository.hasPendingCloudWork() == false {
            await statusModel.update(.upToDate(.now))
        }
    }
}
