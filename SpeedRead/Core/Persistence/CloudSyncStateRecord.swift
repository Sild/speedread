import Foundation
import SwiftData

@Model
final class CloudSyncStateRecord {
    var id: String
    var accountRecordName: String?
    var engineStateData: Data?
    var updatedAt: Date

    init(
        id: String = "private",
        accountRecordName: String? = nil,
        engineStateData: Data? = nil,
        updatedAt: Date
    ) {
        self.id = id
        self.accountRecordName = accountRecordName
        self.engineStateData = engineStateData
        self.updatedAt = updatedAt
    }
}
