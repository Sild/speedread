import Foundation
import SwiftData

@Model
final class TagRecord {
    var id: UUID
    var canonicalName: String
    var displayName: String
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    init(id: UUID, canonicalName: String, displayName: String, createdAt: Date) {
        self.id = id
        self.canonicalName = canonicalName
        self.displayName = displayName
        self.createdAt = createdAt
        updatedAt = createdAt
    }
}
