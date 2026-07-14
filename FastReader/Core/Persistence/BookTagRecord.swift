import Foundation
import SwiftData

@Model
final class BookTagRecord {
    var id: UUID
    var bookID: UUID
    var tagID: UUID
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    init(id: UUID, bookID: UUID, tagID: UUID, createdAt: Date) {
        self.id = id
        self.bookID = bookID
        self.tagID = tagID
        self.createdAt = createdAt
        updatedAt = createdAt
    }
}
