import SwiftData

enum SpeedReadSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            BookRecord.self,
            TagRecord.self,
            BookTagRecord.self
        ]
    }
}

enum SpeedReadSchemaV2: VersionedSchema {
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

enum SpeedReadMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [SpeedReadSchemaV1.self, SpeedReadSchemaV2.self]
    }

    static var stages: [MigrationStage] {
        [
            .lightweight(fromVersion: SpeedReadSchemaV1.self, toVersion: SpeedReadSchemaV2.self)
        ]
    }
}
