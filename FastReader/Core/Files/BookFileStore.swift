import CryptoKit
import Foundation

struct StagedBookFile: Sendable {
    let url: URL
    let originalFilename: String
    let byteCount: Int64
}

struct StoredPublicationFiles: Sendable {
    let fileRelativePath: String
    let coverRelativePath: String?
    let createdBookFile: Bool
    let createdCoverFile: Bool
}

enum BookFileStoreError: Error, Equatable, Sendable {
    case unsupportedFile
    case inaccessibleSource
    case invalidRelativePath
}

protocol BookFileStore: Sendable {
    func stage(sourceURL: URL) async throws -> StagedBookFile
    func contentHash(of stagedFile: StagedBookFile) async throws -> String
    func commit(
        stagedFile: StagedBookFile,
        contentHash: String,
        coverPNGData: Data?
    ) async throws -> StoredPublicationFiles
    func repair(stagedFile: StagedBookFile, relativePath: String) async throws
    func fileExists(relativePath: String) async -> Bool
    func fileURL(relativePath: String) async throws -> URL
    func data(relativePath: String) async throws -> Data
    func remove(relativePaths: [String]) async throws
    func discard(stagedFile: StagedBookFile) async
}

actor ApplicationSupportBookFileStore: BookFileStore {
    private let fileManager: FileManager
    private let rootURL: URL
    private let stagingURL: URL
    private let booksURL: URL
    private let coversURL: URL

    init(rootURL: URL? = nil, fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        if let rootURL {
            self.rootURL = rootURL
        } else {
            guard let applicationSupport = fileManager
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first
            else {
                throw BookFileStoreError.inaccessibleSource
            }
            self.rootURL = applicationSupport.appending(path: "FastReader", directoryHint: .isDirectory)
        }
        stagingURL = self.rootURL.appending(path: "Staging", directoryHint: .isDirectory)
        booksURL = self.rootURL.appending(path: "Books", directoryHint: .isDirectory)
        coversURL = self.rootURL.appending(path: "Covers", directoryHint: .isDirectory)

        try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: booksURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: coversURL, withIntermediateDirectories: true)
        try Self.removeChildren(of: stagingURL, fileManager: fileManager)
    }

    func stage(sourceURL: URL) throws -> StagedBookFile {
        guard sourceURL.pathExtension.caseInsensitiveCompare("epub") == .orderedSame else {
            throw BookFileStoreError.unsupportedFile
        }

        let relinquishAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if relinquishAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let stagedURL = stagingURL
            .appending(path: UUID().uuidString, directoryHint: .notDirectory)
            .appendingPathExtension("epub")
        do {
            try fileManager.copyItem(at: sourceURL, to: stagedURL)
            let values = try stagedURL.resourceValues(forKeys: [.fileSizeKey])
            return StagedBookFile(
                url: stagedURL,
                originalFilename: sourceURL.lastPathComponent,
                byteCount: Int64(values.fileSize ?? 0)
            )
        } catch {
            try? fileManager.removeItem(at: stagedURL)
            throw error
        }
    }

    func contentHash(of stagedFile: StagedBookFile) throws -> String {
        let handle = try FileHandle(forReadingFrom: stagedFile.url)
        defer {
            try? handle.close()
        }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func commit(
        stagedFile: StagedBookFile,
        contentHash: String,
        coverPNGData: Data?
    ) throws -> StoredPublicationFiles {
        let bookRelativePath = "Books/\(contentHash).epub"
        let bookURL = booksURL.appending(path: "\(contentHash).epub", directoryHint: .notDirectory)
        let createdBookFile = !fileManager.fileExists(atPath: bookURL.path)
        if createdBookFile {
            try fileManager.moveItem(at: stagedFile.url, to: bookURL)
        } else {
            try fileManager.removeItem(at: stagedFile.url)
        }

        var coverRelativePath: String?
        var createdCoverFile = false
        if let coverPNGData {
            let coverURL = coversURL.appending(path: "\(contentHash).png", directoryHint: .notDirectory)
            coverRelativePath = "Covers/\(contentHash).png"
            createdCoverFile = !fileManager.fileExists(atPath: coverURL.path)
            if createdCoverFile {
                do {
                    try coverPNGData.write(to: coverURL, options: .atomic)
                } catch {
                    if createdBookFile {
                        try? fileManager.removeItem(at: bookURL)
                    }
                    throw error
                }
            }
        }

        return StoredPublicationFiles(
            fileRelativePath: bookRelativePath,
            coverRelativePath: coverRelativePath,
            createdBookFile: createdBookFile,
            createdCoverFile: createdCoverFile
        )
    }

    func repair(stagedFile: StagedBookFile, relativePath: String) throws {
        let destination = try resolvedURL(relativePath: relativePath)
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: stagedFile.url)
        } else {
            try fileManager.moveItem(at: stagedFile.url, to: destination)
        }
    }

    func fileExists(relativePath: String) -> Bool {
        guard let url = try? resolvedURL(relativePath: relativePath) else {
            return false
        }
        return fileManager.fileExists(atPath: url.path)
    }

    func fileURL(relativePath: String) throws -> URL {
        try resolvedURL(relativePath: relativePath)
    }

    func data(relativePath: String) throws -> Data {
        try Data(contentsOf: resolvedURL(relativePath: relativePath))
    }

    func remove(relativePaths: [String]) throws {
        for relativePath in relativePaths {
            let url = try resolvedURL(relativePath: relativePath)
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }
    }

    func discard(stagedFile: StagedBookFile) {
        try? fileManager.removeItem(at: stagedFile.url)
    }

    private func resolvedURL(relativePath: String) throws -> URL {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.split(separator: "/").contains("..")
        else {
            throw BookFileStoreError.invalidRelativePath
        }
        let url = rootURL.appending(path: relativePath, directoryHint: .notDirectory).standardizedFileURL
        guard url.path.hasPrefix(rootURL.standardizedFileURL.path + "/") else {
            throw BookFileStoreError.invalidRelativePath
        }
        return url
    }

    private static func removeChildren(of directory: URL, fileManager: FileManager) throws {
        for child in try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            try fileManager.removeItem(at: child)
        }
    }
}
