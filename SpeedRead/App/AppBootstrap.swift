import Observation
import SwiftData
import SwiftUI
import UIKit

@MainActor
@Observable
final class AppBootstrap {
    enum State {
        case ready(AppDependencies)
        case failure
    }

    private(set) var state: State
    private let isUITesting: Bool
    private let seedsLargeLibrary: Bool
    private let seedsFilterLibrary: Bool

    init(
        isUITesting: Bool = ProcessInfo.processInfo.arguments.contains("-ui-testing"),
        seedsLargeLibrary: Bool = ProcessInfo.processInfo.arguments.contains("-ui-testing-large-library"),
        seedsFilterLibrary: Bool = ProcessInfo.processInfo.arguments.contains("-ui-testing-filter-library")
    ) {
        self.isUITesting = isUITesting
        self.seedsLargeLibrary = seedsLargeLibrary
        self.seedsFilterLibrary = seedsFilterLibrary
        if isUITesting {
            ReaderModePreferenceStore().removeAll()
        }
        state = Self.makeState(
            isUITesting: isUITesting,
            seedsLargeLibrary: seedsLargeLibrary,
            seedsFilterLibrary: seedsFilterLibrary
        )
    }

    func retry() {
        state = Self.makeState(
            isUITesting: isUITesting,
            seedsLargeLibrary: seedsLargeLibrary,
            seedsFilterLibrary: seedsFilterLibrary
        )
    }

    private static func makeState(
        isUITesting: Bool,
        seedsLargeLibrary: Bool,
        seedsFilterLibrary: Bool
    ) -> State {
        do {
            let container = try PersistenceController.makeContainer(inMemory: isUITesting)
            if seedsLargeLibrary {
                try seedLargeLibrary(in: container)
            } else if seedsFilterLibrary {
                try seedFilterLibrary(in: container)
            }
            let cloudSyncStatus = CloudSyncStatusModel()
            let repository = SwiftDataBookRepository(modelContainer: container)
            repository.setCloudMutationHandler {
                cloudSyncStatus.localMutationDidQueue()
            }
            let bookRepository = makeBookRepository(isUITesting: isUITesting, repository: repository)
            let fileStore = try makeFileStore(
                isUITesting: isUITesting,
                seedsCovers: seedsFilterLibrary && testsCardAlignment
            )
            let publicationService = ReadiumPublicationService()
            let purchaseManager = makePurchaseManager(isUITesting: isUITesting)
            let importCoordinator = ImportCoordinator(
                repository: bookRepository,
                fileStore: fileStore,
                publicationService: publicationService,
                purchaseManager: purchaseManager
            )
            let cloudSyncCoordinator = isUITesting || Self.isRunningTests
                ? nil
                : CloudKitSyncCoordinator(
                    repository: repository,
                    fileStore: fileStore,
                    publicationService: publicationService,
                    statusModel: cloudSyncStatus
                )
            return .ready(
                AppDependencies(
                    modelContainer: container,
                    bookRepository: bookRepository,
                    readingProgressStore: repository,
                    bookFileStore: fileStore,
                    publicationService: publicationService,
                    importCoordinator: importCoordinator,
                    purchaseManager: purchaseManager,
                    cloudSyncStatus: cloudSyncStatus,
                    cloudSyncCoordinator: cloudSyncCoordinator
                )
            )
        } catch {
            return .failure
        }
    }

    private static var uiTestingFileRoot: URL {
        FileManager.default.temporaryDirectory.appending(
            path: "SpeedRead-UITesting-\(ProcessInfo.processInfo.processIdentifier)",
            directoryHint: .isDirectory
        )
    }

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    private static var testsCardAlignment: Bool {
        ProcessInfo.processInfo.arguments.contains("-ui-testing-card-alignment")
    }

    private static func makePurchaseManager(isUITesting: Bool) -> PurchaseManager {
        guard isUITesting else {
            return PurchaseManager()
        }
        let testsFreeAccess = ProcessInfo.processInfo.arguments.contains("-ui-testing-free")
        return PurchaseManager(testingMode: testsFreeAccess ? .free : .lifetime)
    }

    private static func makeFileStore(
        isUITesting: Bool,
        seedsCovers: Bool
    ) throws -> ApplicationSupportBookFileStore {
        let rootURL = isUITesting ? uiTestingFileRoot : nil
        let fileStore = try ApplicationSupportBookFileStore(rootURL: rootURL)
        if seedsCovers, let rootURL {
            try seedFilterLibraryCovers(at: rootURL)
        }
        return fileStore
    }

    private static func makeBookRepository(
        isUITesting: Bool,
        repository: SwiftDataBookRepository
    ) -> any BookRepository {
        let failsTagWrites = ProcessInfo.processInfo.arguments.contains("-ui-testing-fail-tag-save")
        return if isUITesting, failsTagWrites {
            UITestTagWriteFailureRepository(base: repository)
        } else {
            repository
        }
    }

    private static func seedLargeLibrary(in container: ModelContainer) throws {
        let context = container.mainContext
        let importedAt = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 1 ... 500 {
            let status = BookStatus.allCases[(index - 1) % BookStatus.allCases.count]
            let record = BookRecord(
                id: UUID(),
                contentHash: String(format: "ui-test-%04d", index),
                title: String(format: "Book %03d", index),
                authorsDisplay: String(format: "Author %02d", index % 25),
                mediaType: "application/epub+zip",
                layout: .reflowable,
                fileRelativePath: String(format: "Books/ui-test-%04d.epub", index),
                coverRelativePath: nil,
                fileByteCount: 1,
                importedAt: importedAt.addingTimeInterval(TimeInterval(-index)),
                status: status
            )
            record.progress = Double(index % 101) / 100
            context.insert(record)
        }
        try context.save()
    }

    private static func seedFilterLibrary(in container: ModelContainer) throws {
        let context = container.mainContext
        let importedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let tagIDs = FilterSeedTagIDs(fiction: UUID(), focus: UUID(), rare: UUID())
        for tag in filterSeedTags(ids: tagIDs) {
            context.insert(
                TagRecord(
                    id: tag.id,
                    canonicalName: tag.canonicalName,
                    displayName: tag.displayName,
                    createdAt: importedAt
                )
            )
        }

        for (index, book) in filterSeedBooks(ids: tagIDs).enumerated() {
            insert(book, index: index, importedAt: importedAt, into: context)
        }
        try context.save()
    }

    private static func seedFilterLibraryCovers(at rootURL: URL) throws {
        let sizes = [
            CGSize(width: 90, height: 160),
            CGSize(width: 160, height: 90),
            CGSize(width: 120, height: 120),
            CGSize(width: 100, height: 150)
        ]
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        for (index, size) in sizes.enumerated() {
            let data = UIGraphicsImageRenderer(size: size, format: format).pngData { context in
                UIColor(
                    red: CGFloat(index + 1) / CGFloat(sizes.count + 1),
                    green: 0.35,
                    blue: 0.25,
                    alpha: 1
                ).setFill()
                context.fill(CGRect(origin: .zero, size: size))
            }
            try data.write(
                to: rootURL.appending(path: "Covers/ui-filter-\(index).png"),
                options: .atomic
            )
        }
    }

    private static func filterSeedTags(ids: FilterSeedTagIDs) -> [FilterSeedTag] {
        [
            FilterSeedTag(id: ids.fiction, canonicalName: "fiction", displayName: "Fiction"),
            FilterSeedTag(id: ids.focus, canonicalName: "focus", displayName: "Focus"),
            FilterSeedTag(id: ids.rare, canonicalName: "rare", displayName: "Rare")
        ]
    }

    private static func filterSeedBooks(ids: FilterSeedTagIDs) -> [FilterSeedBook] {
        [
            FilterSeedBook(
                title: "Alpha Guide",
                status: .reading,
                progress: 0.42,
                tagIDs: [ids.fiction, ids.focus]
            ),
            FilterSeedBook(
                title: "Beta Notes for Focused Readers",
                status: .reading,
                progress: 0.18,
                tagIDs: [ids.fiction]
            ),
            FilterSeedBook(title: "Gamma Story", status: .done, progress: 1, tagIDs: [ids.focus]),
            FilterSeedBook(
                title: "Delta Manual",
                status: .new,
                progress: 0,
                tagIDs: [ids.fiction, ids.focus, ids.rare]
            )
        ]
    }

    private static func insert(
        _ book: FilterSeedBook,
        index: Int,
        importedAt: Date,
        into context: ModelContext
    ) {
        let bookID = UUID()
        let timestamp = importedAt.addingTimeInterval(TimeInterval(-index))
        let format: PublicationFormat = testsCardAlignment && index == 0 ? .pdf : .epub
        let record = BookRecord(
            id: bookID,
            contentHash: "ui-filter-\(index)",
            title: book.title,
            authorsDisplay: testsCardAlignment && index == 0 ? "" : "Fixture Author",
            mediaType: format.defaultMediaType,
            layout: format.layout,
            fileRelativePath: "Books/ui-filter-\(index).\(format.fileExtension)",
            coverRelativePath: testsCardAlignment ? "Covers/ui-filter-\(index).png" : nil,
            fileByteCount: 1,
            importedAt: timestamp,
            status: book.status
        )
        record.progress = book.progress
        context.insert(record)
        for tagID in book.tagIDs {
            context.insert(BookTagRecord(id: UUID(), bookID: bookID, tagID: tagID, createdAt: timestamp))
        }
    }
}

private struct FilterSeedTagIDs {
    let fiction: UUID
    let focus: UUID
    let rare: UUID
}

private struct FilterSeedTag {
    let id: UUID
    let canonicalName: String
    let displayName: String
}

private struct FilterSeedBook {
    let title: String
    let status: BookStatus
    let progress: Double
    let tagIDs: [UUID]
}

@MainActor
private final class UITestTagWriteFailureRepository: BookRepository {
    enum Failure: Error {
        case rejected
    }

    private let base: any BookRepository

    init(base: any BookRepository) {
        self.base = base
    }

    func books(matching filter: LibraryFilter) throws -> [Book] {
        try base.books(matching: filter)
    }

    func book(id: UUID) throws -> Book? {
        try base.book(id: id)
    }

    func book(contentHash: String) throws -> Book? {
        try base.book(contentHash: contentHash)
    }

    func tags() throws -> [Tag] {
        try base.tags()
    }

    func insert(_ publication: ImportedPublication, importedAt: Date) throws -> Book {
        try base.insert(publication, importedAt: importedAt)
    }

    func setStatus(_ status: BookStatus, for bookID: UUID, at date: Date) throws {
        try base.setStatus(status, for: bookID, at: date)
    }

    func setTags(_: [String], for _: UUID, at _: Date) throws {
        throw Failure.rejected
    }

    func delete(bookID: UUID, at date: Date) throws -> Book {
        try base.delete(bookID: bookID, at: date)
    }
}

@MainActor
struct AppDependencies {
    let modelContainer: ModelContainer
    let bookRepository: any BookRepository
    let readingProgressStore: any ReadingProgressStore
    let bookFileStore: any BookFileStore
    let publicationService: any PublicationService
    let importCoordinator: ImportCoordinator
    let purchaseManager: PurchaseManager
    let cloudSyncStatus: CloudSyncStatusModel
    let cloudSyncCoordinator: CloudKitSyncCoordinator?
}

struct BootstrapView: View {
    @Environment(\.scenePhase) private var scenePhase

    let bootstrap: AppBootstrap

    var body: some View {
        switch bootstrap.state {
        case let .ready(dependencies):
            Group {
                if dependencies.purchaseManager.isReady {
                    RootView(
                        repository: dependencies.bookRepository,
                        progressStore: dependencies.readingProgressStore,
                        fileStore: dependencies.bookFileStore,
                        publicationService: dependencies.publicationService,
                        importCoordinator: dependencies.importCoordinator,
                        purchaseManager: dependencies.purchaseManager,
                        cloudSyncStatus: dependencies.cloudSyncStatus,
                        cloudSyncCoordinator: dependencies.cloudSyncCoordinator
                    )
                } else {
                    ProgressView("pro.checkingPurchase")
                        .editorialCanvas()
                }
            }
            .modelContainer(dependencies.modelContainer)
            .task {
                await dependencies.purchaseManager.start()
            }
            .task(id: scenePhase) {
                guard scenePhase == .active else {
                    return
                }
                await dependencies.purchaseManager.refreshEntitlement()
            }
            .task(id: dependencies.purchaseManager.hasProAccess) {
                if dependencies.purchaseManager.hasProAccess {
                    await dependencies.cloudSyncCoordinator?.start()
                } else {
                    await dependencies.cloudSyncCoordinator?.stop()
                }
            }
            .task(id: dependencies.cloudSyncStatus.localMutationRevision) {
                guard dependencies.purchaseManager.hasProAccess,
                      dependencies.cloudSyncStatus.localMutationRevision > 0
                else {
                    return
                }
                await dependencies.cloudSyncCoordinator?.sendQueuedLocalChanges()
            }
        case .failure:
            ContentUnavailableView {
                Label("library.startup.error.title", systemImage: "externaldrive.badge.exclamationmark")
            } description: {
                Text("library.startup.error.message")
            } actions: {
                Button("action.retry") {
                    bootstrap.retry()
                }
                .buttonStyle(.borderedProminent)
            }
            .editorialCanvas()
        }
    }
}
