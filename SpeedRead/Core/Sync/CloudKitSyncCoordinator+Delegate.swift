import CloudKit
import Foundation

extension CloudKitSyncCoordinator {
    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        guard engine === syncEngine else {
            return
        }
        do {
            if try await handleStateEvent(event, syncEngine: syncEngine) {
                return
            }
            if try await handleFetchEvent(event, syncEngine: syncEngine) {
                return
            }
            _ = try await handleSendEvent(event, syncEngine: syncEngine)
        } catch {
            await report(error)
        }
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard pendingAccountChange == nil, engine === syncEngine else {
            return nil
        }
        do {
            let snapshots = try await repository.pendingCloudChanges()
            let snapshotsByName = Dictionary(
                snapshots.map { ($0.key.recordName, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let scoped = syncEngine.state.pendingRecordZoneChanges.filter {
                context.options.scope.contains($0)
            }
            let pending = scoped.filter { change in
                guard context.options.scope.contains(change),
                      let recordID = Self.recordID(for: change),
                      let snapshot = snapshotsByName[recordID.recordName]
                else {
                    return false
                }
                return Self.action(for: change) == snapshot.pendingAction
            }
            let stale = scoped.filter { !pending.contains($0) }
            syncEngine.state.remove(pendingRecordZoneChanges: stale)
            guard !pending.isEmpty else {
                return nil
            }
            rememberInFlightMutations(pending, snapshotsByName: snapshotsByName)
            return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { [weak self] id in
                guard let self else {
                    return nil
                }
                return await recordToSave(for: id, syncEngine: syncEngine)
            }
        } catch {
            await report(error)
            return nil
        }
    }

    private func handleStateEvent(
        _ event: CKSyncEngine.Event,
        syncEngine: CKSyncEngine
    ) async throws -> Bool {
        switch event {
        case let .stateUpdate(update):
            guard pendingAccountChange == nil else {
                return true
            }
            let data = try JSONEncoder().encode(update.stateSerialization)
            try await repository.saveCloudSyncEngineState(
                data,
                accountRecordName: accountRecordName,
                at: .now
            )
            return true
        case let .accountChange(change):
            await handleAccountChange(change, syncEngine: syncEngine)
            return true
        default:
            return false
        }
    }

    private func handleFetchEvent(
        _ event: CKSyncEngine.Event,
        syncEngine: CKSyncEngine
    ) async throws -> Bool {
        switch event {
        case let .fetchedDatabaseChanges(changes):
            try await handleFetchedDatabaseChanges(changes, syncEngine: syncEngine)
        case let .fetchedRecordZoneChanges(changes):
            try await handleFetchedRecordChanges(changes, syncEngine: syncEngine)
        case .willFetchChanges, .willFetchRecordZoneChanges:
            await statusModel.update(.syncing)
        case let .didFetchRecordZoneChanges(event):
            if let error = event.error {
                await report(error)
            }
        case .didFetchChanges:
            try await updateUpToDateStatus()
        default:
            return false
        }
        return true
    }

    private func handleSendEvent(
        _ event: CKSyncEngine.Event,
        syncEngine: CKSyncEngine
    ) async throws -> Bool {
        switch event {
        case let .sentDatabaseChanges(changes):
            try await handleSentDatabaseChanges(changes)
        case let .sentRecordZoneChanges(changes):
            try await handleSentRecordChanges(changes, syncEngine: syncEngine)
        case .willSendChanges:
            await statusModel.update(.syncing)
        case .didSendChanges:
            try await updateUpToDateStatus()
        default:
            return false
        }
        return true
    }

    private func updateUpToDateStatus() async throws {
        if try await repository.hasPendingCloudWork() == false {
            await statusModel.update(.upToDate(.now))
        }
    }

    private func rememberInFlightMutations(
        _ pending: [CKSyncEngine.PendingRecordZoneChange],
        snapshotsByName: [String: CloudRecordStateSnapshot]
    ) {
        for change in pending {
            guard let name = Self.recordID(for: change)?.recordName,
                  let mutationID = snapshotsByName[name]?.mutationID
            else {
                continue
            }
            inFlightMutations[name] = mutationID
        }
    }

    private static func recordID(
        for change: CKSyncEngine.PendingRecordZoneChange
    ) -> CKRecord.ID? {
        switch change {
        case let .saveRecord(id), let .deleteRecord(id):
            id
        @unknown default:
            nil
        }
    }

    private static func action(
        for change: CKSyncEngine.PendingRecordZoneChange
    ) -> CloudPendingAction? {
        switch change {
        case .saveRecord:
            .save
        case .deleteRecord:
            .delete
        @unknown default:
            nil
        }
    }
}
