import Foundation
import SwiftData

struct CloudRecordStateSnapshot: Equatable, Sendable {
    let key: LibrarySyncRecordKey
    let systemFieldsData: Data?
    let pendingAction: CloudPendingAction?
    let mutationID: String?
    let accountRecordName: String?
    let deferredRecordData: Data?
    let needsAssetDownload: Bool
}

struct CloudSyncStateSnapshot: Equatable, Sendable {
    let accountRecordName: String?
    let engineStateData: Data?
}

@MainActor
final class CloudSyncJournal {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func queue(_ key: LibrarySyncRecordKey, action: CloudPendingAction, at date: Date) throws {
        let state: CloudRecordStateRecord
        if let existing = try recordState(for: key) {
            state = existing
        } else {
            state = CloudRecordStateRecord(key: key, updatedAt: date)
            context.insert(state)
        }
        state.recordTypeRawValue = key.kind.rawValue
        state.pendingAction = action
        state.mutationID = UUID().uuidString
        state.updatedAt = date
    }

    func snapshots() throws -> [CloudRecordStateSnapshot] {
        try context.fetch(FetchDescriptor<CloudRecordStateRecord>())
            .compactMap { record in
                guard let key = record.key else {
                    return nil
                }
                return CloudRecordStateSnapshot(
                    key: key,
                    systemFieldsData: record.systemFieldsData,
                    pendingAction: record.pendingAction,
                    mutationID: record.mutationID,
                    accountRecordName: record.accountRecordName,
                    deferredRecordData: record.deferredRecordData,
                    needsAssetDownload: record.needsAssetDownload
                )
            }
            .sorted { $0.key.recordName < $1.key.recordName }
    }

    func storeRemoteState(
        for key: LibrarySyncRecordKey,
        systemFieldsData: Data,
        accountRecordName: String?,
        needsUpload: Bool,
        at date: Date
    ) throws {
        let state: CloudRecordStateRecord
        if let existing = try recordState(for: key) {
            state = existing
        } else {
            state = CloudRecordStateRecord(key: key, updatedAt: date)
            context.insert(state)
        }
        state.recordTypeRawValue = key.kind.rawValue
        state.systemFieldsData = systemFieldsData
        state.accountRecordName = accountRecordName
        state.deferredRecordData = nil
        state.needsAssetDownload = false
        state.updatedAt = date
        if needsUpload {
            state.pendingAction = .save
            state.mutationID = UUID().uuidString
        } else {
            state.pendingAction = nil
            state.mutationID = nil
        }
    }

    func storeDeferredRecord(
        for key: LibrarySyncRecordKey,
        payloadData: Data,
        systemFieldsData: Data,
        accountRecordName: String?,
        at date: Date
    ) throws {
        let state: CloudRecordStateRecord
        if let existing = try recordState(for: key) {
            state = existing
        } else {
            state = CloudRecordStateRecord(key: key, updatedAt: date)
            context.insert(state)
        }
        state.recordTypeRawValue = key.kind.rawValue
        state.systemFieldsData = systemFieldsData
        state.pendingAction = nil
        state.mutationID = nil
        state.accountRecordName = accountRecordName
        state.deferredRecordData = payloadData
        state.needsAssetDownload = false
        state.updatedAt = date
    }

    func storeRemoteAssetState(
        for key: LibrarySyncRecordKey,
        systemFieldsData: Data,
        accountRecordName: String?,
        disposition: RemoteAssetDisposition,
        at date: Date
    ) throws {
        let state: CloudRecordStateRecord
        if let existing = try recordState(for: key) {
            state = existing
        } else {
            state = CloudRecordStateRecord(key: key, updatedAt: date)
            context.insert(state)
        }
        state.recordTypeRawValue = key.kind.rawValue
        state.systemFieldsData = systemFieldsData
        switch disposition {
        case .delete:
            state.pendingAction = .delete
            state.mutationID = UUID().uuidString
            state.needsAssetDownload = false
        case .deferUntilBook, .download:
            state.pendingAction = nil
            state.mutationID = nil
            state.needsAssetDownload = true
        }
        state.accountRecordName = accountRecordName
        state.deferredRecordData = nil
        state.updatedAt = date
    }

    func markAssetDownloaded(_ key: LibrarySyncRecordKey, at date: Date) throws {
        guard let state = try recordState(for: key) else {
            return
        }
        state.needsAssetDownload = false
        state.updatedAt = date
    }

    func markSent(
        _ key: LibrarySyncRecordKey,
        mutationID: String?,
        systemFieldsData: Data?,
        accountRecordName: String?,
        at date: Date
    ) throws {
        guard let state = try recordState(for: key) else {
            return
        }
        state.systemFieldsData = systemFieldsData
        state.accountRecordName = accountRecordName
        state.deferredRecordData = nil
        state.needsAssetDownload = false
        state.updatedAt = date
        guard state.mutationID == mutationID else {
            return
        }
        state.pendingAction = nil
        state.mutationID = nil
    }

    func removeState(for key: LibrarySyncRecordKey) throws {
        guard let state = try recordState(for: key) else {
            return
        }
        context.delete(state)
    }

    func syncState() throws -> CloudSyncStateSnapshot {
        guard let state = try context.fetch(FetchDescriptor<CloudSyncStateRecord>()).first else {
            return CloudSyncStateSnapshot(accountRecordName: nil, engineStateData: nil)
        }
        return CloudSyncStateSnapshot(
            accountRecordName: state.accountRecordName,
            engineStateData: state.engineStateData
        )
    }

    func saveEngineState(
        _ data: Data?,
        accountRecordName: String?,
        at date: Date
    ) throws {
        let state: CloudSyncStateRecord
        if let existing = try context.fetch(FetchDescriptor<CloudSyncStateRecord>()).first {
            state = existing
        } else {
            state = CloudSyncStateRecord(updatedAt: date)
            context.insert(state)
        }
        state.engineStateData = data
        state.accountRecordName = accountRecordName
        state.updatedAt = date
    }

    func resetSystemFields(accountRecordName: String?, at date: Date) throws {
        for state in try context.fetch(FetchDescriptor<CloudRecordStateRecord>()) {
            state.systemFieldsData = nil
            state.pendingAction = nil
            state.mutationID = nil
            state.accountRecordName = accountRecordName
            state.deferredRecordData = nil
            state.needsAssetDownload = false
            state.updatedAt = date
        }
        try saveEngineState(nil, accountRecordName: accountRecordName, at: date)
    }

    func recordState(for key: LibrarySyncRecordKey) throws -> CloudRecordStateRecord? {
        try context.fetch(FetchDescriptor<CloudRecordStateRecord>())
            .first { $0.recordName == key.recordName }
    }
}
