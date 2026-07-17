import CryptoKit
import Foundation

enum LibrarySyncRecordKind: String, Codable, CaseIterable, Sendable {
    case book = "Book"
    case bookAsset = "BookAsset"
    case tag = "Tag"
    case bookTag = "BookTag"
}

struct LibrarySyncRecordKey: Codable, Equatable, Hashable, Sendable {
    let kind: LibrarySyncRecordKind
    let recordName: String

    init?(recordType: String, recordName: String) {
        guard let kind = LibrarySyncRecordKind(rawValue: recordType),
              Self.hasExpectedPrefix(recordName, for: kind)
        else {
            return nil
        }
        self.kind = kind
        self.recordName = recordName
    }

    init(kind: LibrarySyncRecordKind, recordName: String) {
        self.kind = kind
        self.recordName = recordName
    }

    static func book(contentHash: String) -> LibrarySyncRecordKey {
        LibrarySyncRecordKey(kind: .book, recordName: "book-\(contentHash.lowercased())")
    }

    static func bookAsset(contentHash: String) -> LibrarySyncRecordKey {
        LibrarySyncRecordKey(kind: .bookAsset, recordName: "asset-\(contentHash.lowercased())")
    }

    static func tag(canonicalName: String) -> LibrarySyncRecordKey {
        LibrarySyncRecordKey(kind: .tag, recordName: "tag-\(digest(canonicalName))")
    }

    static func bookTag(contentHash: String, canonicalTagName: String) -> LibrarySyncRecordKey {
        LibrarySyncRecordKey(
            kind: .bookTag,
            recordName: "membership-\(contentHash.lowercased())-\(digest(canonicalTagName))"
        )
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func hasExpectedPrefix(_ recordName: String, for kind: LibrarySyncRecordKind) -> Bool {
        switch kind {
        case .book:
            recordName.hasPrefix("book-")
        case .bookAsset:
            recordName.hasPrefix("asset-")
        case .tag:
            recordName.hasPrefix("tag-")
        case .bookTag:
            recordName.hasPrefix("membership-")
        }
    }
}

struct SyncedBookPosition: Codable, Equatable, Sendable {
    let locatorJSON: String?
    let totalProgression: Double
    let speedElementID: String?
    let speedTokenOffset: Int?
    let updatedAt: Date
}

struct SyncedBook: Codable, Equatable, Sendable {
    let contentHash: String
    let title: String
    let authorsDisplay: String
    let mediaType: String
    let layout: PublicationLayout
    let fileByteCount: Int64
    let importedAt: Date
    let metadataUpdatedAt: Date
    let deletedAt: Date?
    let status: BookStatus
    let statusUpdatedAt: Date
    let position: SyncedBookPosition

    var key: LibrarySyncRecordKey {
        .book(contentHash: contentHash)
    }
}

struct SyncedBookAsset: Codable, Equatable, Sendable {
    let contentHash: String
    let fileByteCount: Int64

    var key: LibrarySyncRecordKey {
        .bookAsset(contentHash: contentHash)
    }
}

struct SyncedTag: Codable, Equatable, Sendable {
    let canonicalName: String
    let displayName: String
    let createdAt: Date
    let updatedAt: Date
    let deletedAt: Date?

    var key: LibrarySyncRecordKey {
        .tag(canonicalName: canonicalName)
    }
}

struct SyncedBookTag: Codable, Equatable, Sendable {
    let bookContentHash: String
    let canonicalTagName: String
    let createdAt: Date
    let updatedAt: Date
    let deletedAt: Date?

    var key: LibrarySyncRecordKey {
        .bookTag(contentHash: bookContentHash, canonicalTagName: canonicalTagName)
    }
}

enum LibrarySyncRecord: Equatable, Sendable {
    case book(SyncedBook)
    case bookAsset(SyncedBookAsset)
    case tag(SyncedTag)
    case bookTag(SyncedBookTag)

    var key: LibrarySyncRecordKey {
        switch self {
        case let .book(book):
            book.key
        case let .bookAsset(asset):
            asset.key
        case let .tag(tag):
            tag.key
        case let .bookTag(membership):
            membership.key
        }
    }
}
