import Foundation

struct Book: Identifiable, Equatable, Sendable {
    let id: UUID
    let contentHash: String
    let title: String
    let authorsDisplay: String
    let mediaType: String
    let layout: PublicationLayout
    let fileRelativePath: String
    let progress: Double
    let status: BookStatus
    let tags: [Tag]
    let importedAt: Date
    let lastOpenedAt: Date?
    let coverRelativePath: String?
}

struct ImportedPublication: Equatable, Sendable {
    let contentHash: String
    let title: String
    let authorsDisplay: String
    let mediaType: String
    let layout: PublicationLayout
    let fileRelativePath: String
    let coverRelativePath: String?
    let fileByteCount: Int64
}

struct PublicationMetadataSnapshot: Equatable, Sendable {
    let format: PublicationFormat
    let title: String?
    let authorsDisplay: String
    let mediaType: String
    let layout: PublicationLayout
    let coverPNGData: Data?
}

struct Tag: Identifiable, Equatable, Hashable, Sendable {
    let id: UUID
    let canonicalName: String
    let displayName: String
}
