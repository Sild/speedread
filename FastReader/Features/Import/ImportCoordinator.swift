import Foundation
import Observation

enum ImportOutcome: Equatable, Sendable {
    case imported(UUID)
    case duplicate(UUID)
    case repaired(UUID)
}

struct ImportFailure: Error, Equatable, Sendable {
    let message: String
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

    init(
        repository: any BookRepository,
        fileStore: any BookFileStore,
        publicationService: any PublicationService
    ) {
        self.repository = repository
        self.fileStore = fileStore
        self.publicationService = publicationService
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

        do {
            for url in urls {
                _ = try await importFile(at: url)
            }
            revision += 1
        } catch {
            failure = ImportFailure(message: Self.message(for: error))
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

            let metadata = try await publicationService.inspectEPUB(at: stagedFile.url)
            let storedFiles = try await fileStore.commit(
                stagedFile: stagedFile,
                contentHash: hash,
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
