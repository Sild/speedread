import Foundation
import SwiftData

enum PersistenceController {
    static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let applicationSupportURLs = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )
        if !inMemory, let applicationSupport = applicationSupportURLs.first {
            try FileManager.default.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
        }
        let schema = Schema(versionedSchema: FastReaderSchemaV2.self)
        let configuration = ModelConfiguration(
            "FastReader",
            schema: schema,
            isStoredInMemoryOnly: inMemory,
            allowsSave: true,
            groupContainer: .automatic,
            cloudKitDatabase: .none
        )

        return try ModelContainer(
            for: schema,
            migrationPlan: FastReaderMigrationPlan.self,
            configurations: configuration
        )
    }
}
