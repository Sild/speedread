import Foundation
import SwiftData

@Model
final class BookRecord {
    var id: UUID
    var contentHash: String
    var title: String
    var authorsDisplay: String
    var mediaType: String
    var layoutRawValue: String
    var fileRelativePath: String
    var coverRelativePath: String?
    var fileByteCount: Int64
    var importedAt: Date
    var lastOpenedAt: Date?
    var progress: Double
    var locatorJSON: String?
    var speedElementID: String?
    var speedTokenOffset: Int?
    var statusRawValue: String
    var metadataUpdatedAt: Date
    var positionUpdatedAt: Date
    var statusUpdatedAt: Date
    var deletedAt: Date?

    init(
        id: UUID,
        contentHash: String,
        title: String,
        authorsDisplay: String,
        mediaType: String,
        layout: PublicationLayout,
        fileRelativePath: String,
        coverRelativePath: String?,
        fileByteCount: Int64,
        importedAt: Date,
        status: BookStatus = .new
    ) {
        self.id = id
        self.contentHash = contentHash
        self.title = title
        self.authorsDisplay = authorsDisplay
        self.mediaType = mediaType
        layoutRawValue = layout.rawValue
        self.fileRelativePath = fileRelativePath
        self.coverRelativePath = coverRelativePath
        self.fileByteCount = fileByteCount
        self.importedAt = importedAt
        progress = 0
        statusRawValue = status.rawValue
        metadataUpdatedAt = importedAt
        positionUpdatedAt = importedAt
        statusUpdatedAt = importedAt
    }
}
