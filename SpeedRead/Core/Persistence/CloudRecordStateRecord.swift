import Foundation
import SwiftData

enum CloudPendingAction: String, Codable, Sendable {
    case save
    case delete
}

@Model
final class CloudRecordStateRecord {
    var recordName: String
    var recordTypeRawValue: String
    var systemFieldsData: Data?
    var pendingActionRawValue: String?
    var mutationID: String?
    var accountRecordName: String?
    var deferredRecordData: Data?
    var needsAssetDownload: Bool
    var updatedAt: Date

    init(
        key: LibrarySyncRecordKey,
        pendingAction: CloudPendingAction? = nil,
        mutationID: String? = nil,
        updatedAt: Date
    ) {
        recordName = key.recordName
        recordTypeRawValue = key.kind.rawValue
        pendingActionRawValue = pendingAction?.rawValue
        self.mutationID = mutationID
        needsAssetDownload = false
        self.updatedAt = updatedAt
    }

    var key: LibrarySyncRecordKey? {
        guard let kind = LibrarySyncRecordKind(rawValue: recordTypeRawValue) else {
            return nil
        }
        return LibrarySyncRecordKey(kind: kind, recordName: recordName)
    }

    var pendingAction: CloudPendingAction? {
        get {
            pendingActionRawValue.flatMap(CloudPendingAction.init(rawValue:))
        }
        set {
            pendingActionRawValue = newValue?.rawValue
        }
    }
}
