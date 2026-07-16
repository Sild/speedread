import SwiftData

enum FastReaderSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            BookRecord.self,
            TagRecord.self,
            BookTagRecord.self
        ]
    }
}

enum FastReaderSchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            BookRecord.self,
            TagRecord.self,
            BookTagRecord.self,
            CloudSyncStateRecord.self,
            CloudRecordStateRecord.self
        ]
    }
}

enum FastReaderMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [FastReaderSchemaV1.self, FastReaderSchemaV2.self]
    }

    static var stages: [MigrationStage] {
        [
            .lightweight(fromVersion: FastReaderSchemaV1.self, toVersion: FastReaderSchemaV2.self)
        ]
    }
}
