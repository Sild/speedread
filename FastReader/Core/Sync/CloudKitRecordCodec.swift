import CloudKit
import Foundation

struct DecodedCloudRecord: Sendable {
    let record: LibrarySyncRecord
    let assetURL: URL?
}

enum CloudKitRecordCodecError: Error, Equatable, Sendable {
    case invalidSystemFields
    case mismatchedRecordIdentity
    case unsupportedRecordType(String)
    case missingField(String)
    case invalidField(String)
}

enum CloudKitRecordCodec {
    static let zoneID = CKRecordZone.ID(
        zoneName: "FastReaderLibrary",
        ownerName: CKCurrentUserDefaultName
    )

    static func recordID(for key: LibrarySyncRecordKey) -> CKRecord.ID {
        CKRecord.ID(recordName: key.recordName, zoneID: zoneID)
    }

    static func makeRecord(
        from value: LibrarySyncRecord,
        systemFieldsData: Data?,
        assetURL: URL? = nil
    ) throws -> CKRecord {
        let record: CKRecord
        if let systemFieldsData {
            record = try decodeSystemFields(systemFieldsData)
            guard record.recordID == recordID(for: value.key),
                  record.recordType == value.key.kind.rawValue
            else {
                throw CloudKitRecordCodecError.mismatchedRecordIdentity
            }
        } else {
            record = CKRecord(
                recordType: value.key.kind.rawValue,
                recordID: recordID(for: value.key)
            )
        }

        switch value {
        case let .book(book):
            encode(book, into: record)
        case let .bookAsset(asset):
            guard let assetURL else {
                throw CloudKitRecordCodecError.missingField(Field.asset)
            }
            encode(asset, assetURL: assetURL, into: record)
        case let .tag(tag):
            encode(tag, into: record)
        case let .bookTag(membership):
            encode(membership, into: record)
        }
        return record
    }

    static func decode(_ record: CKRecord) throws -> DecodedCloudRecord {
        guard let kind = LibrarySyncRecordKind(rawValue: record.recordType) else {
            throw CloudKitRecordCodecError.unsupportedRecordType(record.recordType)
        }
        let decoded: DecodedCloudRecord
        switch kind {
        case .book:
            decoded = try DecodedCloudRecord(record: .book(decodeBook(record)), assetURL: nil)
        case .bookAsset:
            let asset: CKAsset = try required(Field.asset, from: record)
            decoded = try DecodedCloudRecord(
                record: .bookAsset(decodeAsset(record)),
                assetURL: asset.fileURL
            )
        case .tag:
            decoded = try DecodedCloudRecord(record: .tag(decodeTag(record)), assetURL: nil)
        case .bookTag:
            decoded = try DecodedCloudRecord(
                record: .bookTag(decodeMembership(record)),
                assetURL: nil
            )
        }
        guard decoded.record.key.recordName == record.recordID.recordName,
              record.recordID.zoneID == zoneID
        else {
            throw CloudKitRecordCodecError.mismatchedRecordIdentity
        }
        return decoded
    }

    static func encodeSystemFields(_ record: CKRecord) -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        return archiver.encodedData
    }

    private static func decodeSystemFields(_ data: Data) throws -> CKRecord {
        let unarchiver: NSKeyedUnarchiver
        do {
            unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
        } catch {
            throw CloudKitRecordCodecError.invalidSystemFields
        }
        unarchiver.requiresSecureCoding = true
        defer {
            unarchiver.finishDecoding()
        }
        guard let record = CKRecord(coder: unarchiver) else {
            throw CloudKitRecordCodecError.invalidSystemFields
        }
        return record
    }

    private static func encode(_ book: SyncedBook, into record: CKRecord) {
        record[Field.contentHash] = book.contentHash
        record[Field.title] = book.title
        record[Field.authorsDisplay] = book.authorsDisplay
        record[Field.mediaType] = book.mediaType
        record[Field.layout] = book.layout.rawValue
        record[Field.fileByteCount] = NSNumber(value: book.fileByteCount)
        record[Field.importedAt] = book.importedAt
        record[Field.metadataUpdatedAt] = book.metadataUpdatedAt
        record[Field.deletedAt] = book.deletedAt
        record[Field.status] = book.status.rawValue
        record[Field.statusUpdatedAt] = book.statusUpdatedAt
        record[Field.locatorJSON] = book.position.locatorJSON
        record[Field.totalProgression] = NSNumber(value: book.position.totalProgression)
        record[Field.speedElementID] = book.position.speedElementID
        record[Field.speedTokenOffset] = book.position.speedTokenOffset.map(NSNumber.init(value:))
        record[Field.positionUpdatedAt] = book.position.updatedAt
    }

    private static func encode(
        _ asset: SyncedBookAsset,
        assetURL: URL,
        into record: CKRecord
    ) {
        record[Field.contentHash] = asset.contentHash
        record[Field.fileByteCount] = NSNumber(value: asset.fileByteCount)
        record[Field.asset] = CKAsset(fileURL: assetURL)
    }

    private static func encode(_ tag: SyncedTag, into record: CKRecord) {
        record[Field.canonicalName] = tag.canonicalName
        record[Field.displayName] = tag.displayName
        record[Field.createdAt] = tag.createdAt
        record[Field.updatedAt] = tag.updatedAt
        record[Field.deletedAt] = tag.deletedAt
    }

    private static func encode(_ membership: SyncedBookTag, into record: CKRecord) {
        record[Field.contentHash] = membership.bookContentHash
        record[Field.canonicalName] = membership.canonicalTagName
        record[Field.createdAt] = membership.createdAt
        record[Field.updatedAt] = membership.updatedAt
        record[Field.deletedAt] = membership.deletedAt
    }

    private static func decodeBook(_ record: CKRecord) throws -> SyncedBook {
        let statusRawValue: String = try required(Field.status, from: record)
        guard let status = BookStatus(rawValue: statusRawValue) else {
            throw CloudKitRecordCodecError.invalidField(Field.status)
        }
        let layoutRawValue: String = try required(Field.layout, from: record)
        guard let layout = PublicationLayout(rawValue: layoutRawValue) else {
            throw CloudKitRecordCodecError.invalidField(Field.layout)
        }
        let progression: NSNumber = try required(Field.totalProgression, from: record)
        let byteCount: NSNumber = try required(Field.fileByteCount, from: record)
        let tokenOffset: NSNumber? = record[Field.speedTokenOffset]
        return try SyncedBook(
            contentHash: required(Field.contentHash, from: record),
            title: required(Field.title, from: record),
            authorsDisplay: required(Field.authorsDisplay, from: record),
            mediaType: required(Field.mediaType, from: record),
            layout: layout,
            fileByteCount: byteCount.int64Value,
            importedAt: required(Field.importedAt, from: record),
            metadataUpdatedAt: required(Field.metadataUpdatedAt, from: record),
            deletedAt: record[Field.deletedAt],
            status: status,
            statusUpdatedAt: required(Field.statusUpdatedAt, from: record),
            position: SyncedBookPosition(
                locatorJSON: record[Field.locatorJSON],
                totalProgression: progression.doubleValue,
                speedElementID: record[Field.speedElementID],
                speedTokenOffset: tokenOffset?.intValue,
                updatedAt: required(Field.positionUpdatedAt, from: record)
            )
        )
    }

    private static func decodeAsset(_ record: CKRecord) throws -> SyncedBookAsset {
        let byteCount: NSNumber = try required(Field.fileByteCount, from: record)
        return try SyncedBookAsset(
            contentHash: required(Field.contentHash, from: record),
            fileByteCount: byteCount.int64Value
        )
    }

    private static func decodeTag(_ record: CKRecord) throws -> SyncedTag {
        try SyncedTag(
            canonicalName: required(Field.canonicalName, from: record),
            displayName: required(Field.displayName, from: record),
            createdAt: required(Field.createdAt, from: record),
            updatedAt: required(Field.updatedAt, from: record),
            deletedAt: record[Field.deletedAt]
        )
    }

    private static func decodeMembership(_ record: CKRecord) throws -> SyncedBookTag {
        try SyncedBookTag(
            bookContentHash: required(Field.contentHash, from: record),
            canonicalTagName: required(Field.canonicalName, from: record),
            createdAt: required(Field.createdAt, from: record),
            updatedAt: required(Field.updatedAt, from: record),
            deletedAt: record[Field.deletedAt]
        )
    }

    private static func required<Value: CKRecordValueProtocol>(
        _ field: String,
        from record: CKRecord
    ) throws -> Value {
        guard let value: Value = record[field] else {
            throw CloudKitRecordCodecError.missingField(field)
        }
        return value
    }
}

private enum Field {
    static let asset = "asset"
    static let authorsDisplay = "authorsDisplay"
    static let canonicalName = "canonicalName"
    static let contentHash = "contentHash"
    static let createdAt = "createdAt"
    static let deletedAt = "deletedAt"
    static let displayName = "displayName"
    static let fileByteCount = "fileByteCount"
    static let importedAt = "importedAt"
    static let layout = "layout"
    static let locatorJSON = "locatorJSON"
    static let mediaType = "mediaType"
    static let metadataUpdatedAt = "metadataUpdatedAt"
    static let positionUpdatedAt = "positionUpdatedAt"
    static let speedElementID = "speedElementID"
    static let speedTokenOffset = "speedTokenOffset"
    static let status = "status"
    static let statusUpdatedAt = "statusUpdatedAt"
    static let title = "title"
    static let totalProgression = "totalProgression"
    static let updatedAt = "updatedAt"
}
