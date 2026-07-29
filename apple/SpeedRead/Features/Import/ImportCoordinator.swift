import Foundation
import Observation

enum ImportOutcome: Equatable, Sendable {
    case imported(UUID)
    case duplicate(UUID)
    case repaired(UUID)
}

struct ImportFailure: Error, Equatable, Sendable {
    let message: String
    let offersPro: Bool

    init(message: String, offersPro: Bool = false) {
        self.message = message
        self.offersPro = offersPro
    }
}

@MainActor
@Observable
final class ImportCoordinator {
    private(set) var isImporting = false
    private(set) var revision = 0
    var failure: ImportFailure?

    private let repository: any BookRepository
    private let fileStore: any BookFileStore
    private let publicationService: any PublicationService
    private let purchaseManager: PurchaseManager

    init(
        repository: any BookRepository,
        fileStore: any BookFileStore,
        publicationService: any PublicationService,
        purchaseManager: PurchaseManager
    ) {
        self.repository = repository
        self.fileStore = fileStore
        self.publicationService = publicationService
        self.purchaseManager = purchaseManager
    }

    func importFiles(at urls: [URL]) async {
        guard !urls.isEmpty else {
            return
        }
        isImporting = true
        failure = nil
        defer {
            isImporting = false
        }

        var changedLibrary = false
        do {
            for url in urls {
                let outcome = try await importFile(at: url)
                switch outcome {
                case .imported, .repaired:
                    changedLibrary = true
                case .duplicate:
                    break
                }
            }
        } catch {
            failure = Self.failure(for: error)
        }
        if changedLibrary {
            revision += 1
        }
    }

    func importFile(at sourceURL: URL) async throws -> ImportOutcome {
        let stagedFile = try await fileStore.stage(sourceURL: sourceURL)
        do {
            let hash = try await fileStore.contentHash(of: stagedFile)
            if let existing = try repository.book(contentHash: hash) {
                if await fileStore.fileExists(relativePath: existing.fileRelativePath) {
                    await fileStore.discard(stagedFile: stagedFile)
                    return .duplicate(existing.id)
                }
                try await fileStore.repair(stagedFile: stagedFile, relativePath: existing.fileRelativePath)
                return .repaired(existing.id)
            }

            let libraryCount = try repository.books(matching: LibraryFilter()).count
            guard purchaseManager.accessPolicy.canAddBook(toLibraryCount: libraryCount) else {
                throw ProAccessError.freeLibraryLimit
            }

            let metadata = try await publicationService.inspectPublication(at: stagedFile.url)
            let storedFiles = try await fileStore.commit(
                stagedFile: stagedFile,
                contentHash: hash,
                format: metadata.format,
                coverPNGData: metadata.coverPNGData
            )
            let imported = ImportedPublication(
                contentHash: hash,
                title: Self.title(metadata.title, fallbackFilename: stagedFile.originalFilename),
                authorsDisplay: metadata.authorsDisplay,
                mediaType: metadata.mediaType,
                layout: metadata.layout,
                fileRelativePath: storedFiles.fileRelativePath,
                coverRelativePath: storedFiles.coverRelativePath,
                fileByteCount: stagedFile.byteCount
            )
            do {
                let book = try repository.insert(imported, importedAt: .now)
                return .imported(book.id)
            } catch {
                var rollbackPaths: [String] = []
                if storedFiles.createdBookFile {
                    rollbackPaths.append(storedFiles.fileRelativePath)
                }
                if storedFiles.createdCoverFile, let coverPath = storedFiles.coverRelativePath {
                    rollbackPaths.append(coverPath)
                }
                try? await fileStore.remove(relativePaths: rollbackPaths)
                throw error
            }
        } catch {
            await fileStore.discard(stagedFile: stagedFile)
            throw error
        }
    }

    func delete(bookID: UUID) async {
        do {
            let book = try repository.delete(bookID: bookID, at: .now)
            var paths = [book.fileRelativePath]
            if let coverPath = book.coverRelativePath {
                paths.append(coverPath)
            }
            try await fileStore.remove(relativePaths: paths)
            try await fileStore.removeDerivedData(contentHash: book.contentHash)
            revision += 1
        } catch {
            failure = ImportFailure(message: Self.message(for: error))
        }
    }

    func dismissFailure() {
        failure = nil
    }

    func reportPickerFailure(_: any Error) {
        failure = ImportFailure(message: String(localized: "import.error.access"))
    }

    private static func title(_ metadataTitle: String?, fallbackFilename: String) -> String {
        let trimmedTitle = metadataTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedTitle.isEmpty {
            return trimmedTitle
        }
        return URL(fileURLWithPath: fallbackFilename).deletingPathExtension().lastPathComponent
    }

    private static func failure(for error: any Error) -> ImportFailure {
        if error as? ProAccessError == .freeLibraryLimit {
            return ImportFailure(
                message: String(localized: "import.error.freeLimit"),
                offersPro: true
            )
        }
        return ImportFailure(message: message(for: error))
    }

    private static func message(for error: any Error) -> String {
        switch error {
        case BookFileStoreError.unsupportedFile:
            String(localized: "import.error.unsupportedFile")
        case PublicationServiceError.protectedPublication:
            String(localized: "import.error.protected")
        case PublicationServiceError.unsupportedFormat:
            String(localized: "import.error.unsupportedFormat")
        case PublicationServiceError.unreadable, PublicationServiceError.invalidURL:
            String(localized: "import.error.unreadable")
        default:
            String(localized: "import.error.generic")
        }
    }
}
