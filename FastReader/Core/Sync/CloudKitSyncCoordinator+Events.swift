import CloudKit
import Foundation

extension CloudKitSyncCoordinator {
    func handleAccountChange(
        _ event: CKSyncEngine.Event.AccountChange,
        syncEngine _: CKSyncEngine
    ) async {
        switch event.changeType {
        case let .signIn(currentUser):
            let current = currentUser.recordName
            do {
                let stored = try await repository.cloudSyncState().accountRecordName
                if let stored, stored != current {
                    await stop()
                    pendingAccountChange = (stored, current)
                    await statusModel.update(
                        .accountChange(previousAccount: stored, currentAccount: current)
                    )
                } else {
                    pendingAccountChange = nil
                    accountRecordName = current
                    await statusModel.update(.syncing)
                }
            } catch {
                await report(error)
            }
        case .signOut:
            await stop()
            await statusModel.update(.localOnly)
        case let .switchAccounts(previousUser, currentUser):
            await stop()
            let previous = previousUser.recordName
            let current = currentUser.recordName
            pendingAccountChange = (previous, current)
            await statusModel.update(
                .accountChange(previousAccount: previous, currentAccount: current)
            )
        @unknown default:
            await statusModel.update(.unavailable)
        }
    }

    func handleFetchedDatabaseChanges(
        _ event: CKSyncEngine.Event.FetchedDatabaseChanges,
        syncEngine: CKSyncEngine
    ) async throws {
        guard event.deletions.contains(where: { $0.zoneID == CloudKitRecordCodec.zoneID }) else {
            return
        }
        let now = Date.now
        try await repository.resetCloudStateForAccount(accountRecordName, at: now)
        syncEngine.state.add(
            pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: CloudKitRecordCodec.zoneID))]
        )
        try await enqueueDurableChanges(in: syncEngine)
    }

    func handleFetchedRecordChanges(
        _ event: CKSyncEngine.Event.FetchedRecordZoneChanges,
        syncEngine: CKSyncEngine
    ) async throws {
        guard pendingAccountChange == nil else {
            return
        }
        let modifications = event.modifications
            .map(\.record)
            .sorted { Self.fetchPriority($0.recordType) < Self.fetchPriority($1.recordType) }
        for record in modifications {
            do {
                try await applyFetched(record, syncEngine: syncEngine)
            } catch {
                await report(error)
            }
        }
        for deletion in event.deletions {
            do {
                try await applyFetchedDeletion(
                    recordType: deletion.recordType,
                    recordID: deletion.recordID
                )
            } catch {
                await report(error)
            }
        }
        _ = try await repository.applyDeferredRemoteMemberships(at: .now)
        await statusModel.libraryDidChange()
        try await enqueueDurableChanges(in: syncEngine)
    }

    func handleSentDatabaseChanges(
        _ event: CKSyncEngine.Event.SentDatabaseChanges
    ) async throws {
        if let failure = event.failedZoneSaves.first {
            throw failure.error
        }
        if let failure = event.failedZoneDeletes.values.first {
            throw failure
        }
    }

    func handleSentRecordChanges(
        _ event: CKSyncEngine.Event.SentRecordZoneChanges,
        syncEngine: CKSyncEngine
    ) async throws {
        for record in event.savedRecords {
            guard let key = LibrarySyncRecordKey(
                recordType: record.recordType,
                recordName: record.recordID.recordName
            ) else {
                continue
            }
            try await repository.markCloudRecordSent(
                key,
                mutationID: inFlightMutations.removeValue(forKey: key.recordName),
                systemFieldsData: CloudKitRecordCodec.encodeSystemFields(record),
                accountRecordName: accountRecordName,
                at: .now
            )
        }
        for id in event.deletedRecordIDs {
            guard let key = Self.key(forRecordName: id.recordName) else {
                continue
            }
            try await repository.markCloudRecordSent(
                key,
                mutationID: inFlightMutations.removeValue(forKey: key.recordName),
                systemFieldsData: nil,
                accountRecordName: accountRecordName,
                at: .now
            )
        }
        for failure in event.failedRecordSaves {
            try await handleSaveFailure(failure, syncEngine: syncEngine)
        }
        for (id, error) in event.failedRecordDeletes {
            if error.code == .unknownItem, let key = Self.key(forRecordName: id.recordName) {
                try await repository.markCloudRecordSent(
                    key,
                    mutationID: inFlightMutations.removeValue(forKey: key.recordName),
                    systemFieldsData: nil,
                    accountRecordName: accountRecordName,
                    at: .now
                )
            } else {
                await report(error)
            }
        }
        try await enqueueDurableChanges(in: syncEngine)
    }

    private func applyFetchedDeletion(
        recordType: String,
        recordID: CKRecord.ID
    ) async throws {
        guard let key = LibrarySyncRecordKey(
            recordType: recordType,
            recordName: recordID.recordName
        ) else {
            return
        }
        if key.kind == .bookAsset {
            let hash = String(key.recordName.dropFirst("asset-".count))
            if try await repository.shouldRemoveDownloadedEPUB(contentHash: hash) {
                try await fileStore.remove(relativePaths: [
                    "Books/\(hash).epub",
                    "Covers/\(hash).png"
                ])
                try await fileStore.removeDerivedData(contentHash: hash)
            }
        }
        try await repository.markRemoteRecordDeleted(key)
        try await repository.requeueCloudRecordIfPresent(key, at: .now)
    }

    private func applyFetched(_ record: CKRecord, syncEngine: CKSyncEngine) async throws {
        let decoded = try CloudKitRecordCodec.decode(record)
        if case let .bookAsset(asset) = decoded.record {
            try await applyFetchedAsset(asset, decoded: decoded, record: record)
            return
        }
        let systemFieldsData = CloudKitRecordCodec.encodeSystemFields(record)
        let needsUpload: Bool
        do {
            needsUpload = try await repository.applyRemoteRecord(
                decoded.record,
                systemFieldsData: systemFieldsData,
                accountRecordName: accountRecordName,
                at: .now
            )
        } catch let storeError as LibrarySyncStoreError {
            switch storeError {
            case .missingBook, .missingTag:
                break
            default:
                throw storeError
            }
            guard case let .bookTag(membership) = decoded.record else {
                throw storeError
            }
            try await repository.deferRemoteMembership(
                membership,
                systemFieldsData: systemFieldsData,
                accountRecordName: accountRecordName,
                at: .now
            )
            return
        }
        if case let .book(book) = decoded.record {
            if let cleanup = try await repository.reconcileAssetForDeletedBook(
                contentHash: book.contentHash,
                at: .now
            ) {
                try await removeDownloadedEPUB(cleanup)
            } else {
                try await attachExistingAssetOrReportDownload(for: book)
            }
        }
        if needsUpload {
            syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
        }
    }

    private func applyFetchedAsset(
        _ asset: SyncedBookAsset,
        decoded: DecodedCloudRecord,
        record: CKRecord
    ) async throws {
        let disposition = try await repository.prepareRemoteAsset(
            asset,
            systemFieldsData: CloudKitRecordCodec.encodeSystemFields(record),
            accountRecordName: accountRecordName,
            at: .now
        )
        if disposition == .delete {
            if let cleanup = try await repository.reconcileAssetForDeletedBook(
                contentHash: asset.contentHash,
                at: .now
            ) {
                try await removeDownloadedEPUB(cleanup)
            }
            return
        }
        let stored = try await downloadAsset(asset, assetURL: decoded.assetURL)
        do {
            try await repository.attachDownloadedEPUB(
                contentHash: asset.contentHash,
                fileRelativePath: stored.fileRelativePath,
                coverRelativePath: stored.coverRelativePath
            )
            try await repository.markRemoteAssetDownloaded(asset.key, at: .now)
        } catch {
            try await rollback(stored)
            throw error
        }
    }

    private func attachExistingAssetOrReportDownload(for book: SyncedBook) async throws {
        let filePath = "Books/\(book.contentHash).epub"
        if await fileStore.fileExists(relativePath: filePath) {
            let coverPath = "Covers/\(book.contentHash).png"
            try await repository.attachDownloadedEPUB(
                contentHash: book.contentHash,
                fileRelativePath: filePath,
                coverRelativePath: fileStore.fileExists(relativePath: coverPath) ? coverPath : nil
            )
        } else {
            await statusModel.update(.downloading(book.title))
        }
    }

    private func downloadAsset(
        _ asset: SyncedBookAsset,
        assetURL: URL?
    ) async throws -> StoredPublicationFiles {
        guard let assetURL else {
            throw CloudKitSyncCoordinatorError.missingAsset
        }
        await statusModel.update(.downloading(asset.contentHash))
        let staged = try await fileStore.stageEPUBAsset(
            sourceURL: assetURL,
            expectedContentHash: asset.contentHash
        )
        do {
            guard staged.byteCount == asset.fileByteCount else {
                throw CloudKitSyncCoordinatorError.assetByteCountMismatch(
                    expected: asset.fileByteCount,
                    actual: staged.byteCount
                )
            }
            let metadata = try await publicationService.inspectPublication(at: staged.url)
            guard metadata.format == .epub else {
                throw PublicationServiceError.unsupportedFormat
            }
            return try await fileStore.commit(
                stagedFile: staged,
                contentHash: asset.contentHash,
                format: .epub,
                coverPNGData: metadata.coverPNGData
            )
        } catch {
            await fileStore.discard(stagedFile: staged)
            throw error
        }
    }

    private func rollback(_ stored: StoredPublicationFiles) async throws {
        var paths: [String] = []
        if stored.createdBookFile {
            paths.append(stored.fileRelativePath)
        }
        if stored.createdCoverFile, let cover = stored.coverRelativePath {
            paths.append(cover)
        }
        try await fileStore.remove(relativePaths: paths)
    }

    private func removeDownloadedEPUB(_ cleanup: RemoteBookCleanup) async throws {
        try await fileStore.remove(relativePaths: Array(Set(cleanup.relativePaths)))
        try await fileStore.removeDerivedData(contentHash: cleanup.contentHash)
    }

    func retryPendingAssetDownloads() async {
        guard pendingAccountChange == nil else {
            return
        }
        let keys: [LibrarySyncRecordKey]
        do {
            keys = try await repository.pendingRemoteAssetDownloads()
        } catch {
            await report(error)
            return
        }
        for key in keys {
            do {
                let record = try await container.privateCloudDatabase.record(
                    for: CloudKitRecordCodec.recordID(for: key)
                )
                let decoded = try CloudKitRecordCodec.decode(record)
                guard case let .bookAsset(asset) = decoded.record else {
                    throw CloudKitRecordCodecError.mismatchedRecordIdentity
                }
                try await applyFetchedAsset(asset, decoded: decoded, record: record)
            } catch {
                await report(error)
            }
        }
    }

    private func handleSaveFailure(
        _ failure: CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave,
        syncEngine: CKSyncEngine
    ) async throws {
        let id = failure.record.recordID
        guard let key = LibrarySyncRecordKey(
            recordType: failure.record.recordType,
            recordName: id.recordName
        ) else {
            return
        }
        let serverRecord = failure.error.serverRecord
        if failure.error.code == .serverRecordChanged, let serverRecord {
            if key.kind == .bookAsset {
                try await repository.markCloudRecordSent(
                    key,
                    mutationID: nil,
                    systemFieldsData: CloudKitRecordCodec.encodeSystemFields(serverRecord),
                    accountRecordName: accountRecordName,
                    at: .now
                )
            } else {
                _ = try await repository.applyRemoteRecord(
                    CloudKitRecordCodec.decode(serverRecord).record,
                    systemFieldsData: CloudKitRecordCodec.encodeSystemFields(serverRecord),
                    accountRecordName: accountRecordName,
                    at: .now
                )
            }
            syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(id)])
        } else {
            await report(failure.error)
        }
    }

    private static func fetchPriority(_ recordType: String) -> Int {
        switch LibrarySyncRecordKind(rawValue: recordType) {
        case .bookAsset:
            0
        case .book:
            1
        case .tag:
            2
        case .bookTag:
            3
        case nil:
            4
        }
    }

    private static func key(forRecordName recordName: String) -> LibrarySyncRecordKey? {
        for kind in LibrarySyncRecordKind.allCases {
            if let key = LibrarySyncRecordKey(recordType: kind.rawValue, recordName: recordName) {
                return key
            }
        }
        return nil
    }
}
