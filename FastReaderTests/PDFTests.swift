@testable import FastReader
import Foundation
@preconcurrency import PDFKit
import Testing
import UIKit

private final class PDFTestBundleToken {}

private enum PDFTestError: Error {
    case missingFixture(String)
}

@Suite("PDF support")
@MainActor
struct PDFTests {
    @Test("PDF metadata, cover, outline, and fixed layout are preserved")
    func metadataAndNativeSession() async throws {
        let service = ReadiumPublicationService()
        let url = try fixture("pdf-metadata-outline")
        let metadata = try await service.inspectPublication(at: url)

        #expect(metadata.format == .pdf)
        #expect(metadata.title == "Native PDF Fixture")
        #expect(metadata.authorsDisplay == "FastReader Tests")
        #expect(metadata.mediaType == "application/pdf")
        #expect(metadata.layout == .fixed)
        let coverData = try #require(metadata.coverPNGData)
        let cover = try #require(UIImage(data: coverData))
        #expect(max(cover.size.width, cover.size.height) <= 1200)

        let session = try await service.makeRegularReaderSession(
            at: url,
            initialLocatorJSON: nil,
            highlightLocatorJSON: nil,
            preferences: RegularReaderPreferences()
        )
        #expect(session.outline.map(\.title) == ["Chapter One", "Chapter Two"])
        #expect(session.viewController.view != nil)
        session.apply(RegularReaderPreferences(theme: .dark, scroll: true))

        let preferences = RegularReaderSession.pdfPreferences(
            RegularReaderPreferences(scroll: true)
        )
        #expect(preferences.fit == .page)
        #expect(preferences.scroll == true)
        #expect(preferences.scrollAxis == .vertical)
    }

    @Test("Actual PDF format wins over a misleading EPUB filename")
    func actualFormatValidation() async throws {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appending(path: "misnamed-\(UUID().uuidString).epub")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try FileManager.default.copyItem(at: fixture("pdf-cyrillic"), to: temporaryURL)

        let metadata = try await ReadiumPublicationService().inspectPublication(at: temporaryURL)
        #expect(metadata.format == .pdf)
        #expect(metadata.mediaType == "application/pdf")
    }

    @Test("PDF import uses filename fallback and content-addressed PDF storage")
    func importAndDuplicateRepair() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = InMemoryBookRepository()
        let fileStore = try ApplicationSupportBookFileStore(rootURL: root)
        let coordinator = ImportCoordinator(
            repository: repository,
            fileStore: fileStore,
            publicationService: ReadiumPublicationService()
        )

        let first = try await coordinator.importFile(at: fixture("pdf-missing-metadata"))
        guard case let .imported(bookID) = first,
              let book = try repository.book(id: bookID)
        else {
            Issue.record("Expected PDF import")
            return
        }
        #expect(book.title == "pdf-missing-metadata")
        #expect(book.mediaType == "application/pdf")
        #expect(book.layout == .fixed)
        #expect(book.fileRelativePath == "Books/\(book.contentHash).pdf")

        try await fileStore.remove(relativePaths: [book.fileRelativePath])
        let second = try await coordinator.importFile(at: fixture("pdf-missing-metadata"))
        #expect(second == .repaired(bookID))
        #expect(await fileStore.fileExists(relativePath: book.fileRelativePath))
    }

    @Test("Password-locked PDF is classified as protected")
    func passwordLocked() async throws {
        var received: PublicationServiceError?
        do {
            _ = try await ReadiumPublicationService().inspectPublication(
                at: fixture("pdf-password-locked")
            )
        } catch let error as PublicationServiceError {
            received = error
        }
        #expect(received == .protectedPublication)
    }

    @Test("Copy-restricted PDF remains readable but rejects speed extraction")
    func copyRestriction() async throws {
        let url = try fixture("pdf-copy-restricted")
        let document = try #require(PDFDocument(url: url))
        #expect(!document.allowsCopying)

        let service = ReadiumPublicationService()
        _ = try await service.inspectPublication(at: url)
        let session = try await service.makeRegularReaderSession(
            at: url,
            initialLocatorJSON: nil,
            highlightLocatorJSON: nil,
            preferences: RegularReaderPreferences()
        )
        #expect(session.viewController.view != nil)

        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileStore = try ApplicationSupportBookFileStore(rootURL: root)
        let extractor = try PDFPageTextExtractor(
            fileURL: url,
            contentHash: "copy-restricted",
            fileStore: fileStore
        )
        await #expect(throws: SpeedContentError.copyRestricted) {
            _ = try await extractor.text(forPage: 0)
        }
    }

    @Test("Embedded Cyrillic and clear two-column prose retain source order")
    func embeddedTextLayouts() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileStore = try ApplicationSupportBookFileStore(rootURL: root)

        let cyrillic = try PDFPageTextExtractor(
            fileURL: fixture("pdf-cyrillic"),
            contentHash: "cyrillic",
            fileStore: fileStore
        )
        let cyrillicText = try await cyrillic.text(forPage: 0)
        #expect(cyrillicText.source == .embedded)
        #expect(cyrillicText.text.contains("Скорочтение"))

        let columns = try PDFPageTextExtractor(
            fileURL: fixture("pdf-two-column"),
            contentHash: "columns",
            fileStore: fileStore
        )
        let columnText = try await columns.text(forPage: 0)
        #expect(columnText.source == .embedded)
        let left = try #require(columnText.text.range(of: "Left column"))
        let right = try #require(columnText.text.range(of: "Right column"))
        #expect(left.lowerBound < right.lowerBound)
    }

    @Test("Image-only PDF uses local OCR and caches its page text")
    func imageOnlyOCRAndCacheHit() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileStore = try ApplicationSupportBookFileStore(rootURL: root)
        let extractor = try PDFPageTextExtractor(
            fileURL: fixture("pdf-image-only"),
            contentHash: "image-only",
            fileStore: fileStore
        )

        let first = try await extractor.text(forPage: 0)
        #expect(first.source == .ocr)
        #expect(first.text.localizedCaseInsensitiveContains("optical character recognition"))
        let cachePath = "image-only/pdf-text-v2/page-0.json"
        let cached = try #require(try await fileStore.derivedData(relativePath: cachePath))
        let second = try await extractor.text(forPage: 0)
        #expect(second == first)
        #expect(try await fileStore.derivedData(relativePath: cachePath) == cached)
    }

    @Test("Ambiguous layout failure is cached and does not silently skip")
    func ambiguousLayoutFailureCache() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileStore = try ApplicationSupportBookFileStore(rootURL: root)
        let extractor = try PDFPageTextExtractor(
            fileURL: fixture("pdf-ambiguous-layout"),
            contentHash: "ambiguous",
            fileStore: fileStore
        )

        await #expect(throws: SpeedContentError.lowConfidence(page: 1)) {
            _ = try await extractor.text(forPage: 0)
        }
        let path = "ambiguous/pdf-text-v2/page-0.json"
        let cached = try #require(try await fileStore.derivedData(relativePath: path))
        await #expect(throws: SpeedContentError.lowConfidence(page: 1)) {
            _ = try await extractor.text(forPage: 0)
        }
        #expect(try await fileStore.derivedData(relativePath: path) == cached)
    }

    @Test("PDF speed provider preserves page locators across navigation and seek")
    func speedPageRoundTrip() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileStore = try ApplicationSupportBookFileStore(rootURL: root)
        let service = ReadiumPublicationService()
        let provider = try await service.makeSpeedContentProvider(
            at: fixture("pdf-metadata-outline"),
            contentHash: "round-trip",
            fileStore: fileStore
        )

        let first = try #require(try await provider.start(at: nil))
        #expect(first.id == "pdf-text-v2:1:0")
        let second = try #require(try await provider.next())
        #expect(second.id == "pdf-text-v2:2:0")
        let previous = try #require(try await provider.previous())
        #expect(previous.id == first.id)
        let sought = try #require(try await provider.seek(toTotalProgression: 1))
        #expect(sought.id == second.id)

        let session = try await service.makeRegularReaderSession(
            at: fixture("pdf-metadata-outline"),
            initialLocatorJSON: second.locatorJSON,
            highlightLocatorJSON: nil,
            preferences: RegularReaderPreferences(scroll: true)
        )
        #expect(session.currentPosition()?.locatorJSON == second.locatorJSON)
    }

    @Test("Versioned cache namespace is isolated and deletion removes all derived data")
    func cacheVersionAndDeletion() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = InMemoryBookRepository()
        let fileStore = try ApplicationSupportBookFileStore(rootURL: root)
        let coordinator = ImportCoordinator(
            repository: repository,
            fileStore: fileStore,
            publicationService: ReadiumPublicationService()
        )
        let outcome = try await coordinator.importFile(at: fixture("pdf-cyrillic"))
        guard case let .imported(bookID) = outcome,
              let book = try repository.book(id: bookID)
        else {
            Issue.record("Expected imported PDF")
            return
        }
        try await fileStore.writeDerivedData(
            Data("old".utf8),
            relativePath: "\(book.contentHash)/pdf-text-v1/page-0.json"
        )
        let extractor = try await PDFPageTextExtractor(
            fileURL: fileStore.fileURL(relativePath: book.fileRelativePath),
            contentHash: book.contentHash,
            fileStore: fileStore
        )
        _ = try await extractor.text(forPage: 0)
        #expect(
            try await fileStore.derivedData(
                relativePath: "\(book.contentHash)/pdf-text-v2/page-0.json"
            ) != nil
        )

        await coordinator.delete(bookID: bookID)
        #expect(coordinator.failure == nil)
        #expect(
            try await fileStore.derivedData(
                relativePath: "\(book.contentHash)/pdf-text-v1/page-0.json"
            ) == nil
        )
        #expect(
            try await fileStore.derivedData(
                relativePath: "\(book.contentHash)/pdf-text-v2/page-0.json"
            ) == nil
        )
    }

    @Test("Malformed PDF rolls back staging and persistent files")
    func malformedRollback() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = InMemoryBookRepository()
        let fileStore = try ApplicationSupportBookFileStore(rootURL: root)
        let coordinator = ImportCoordinator(
            repository: repository,
            fileStore: fileStore,
            publicationService: ReadiumPublicationService()
        )

        await #expect(throws: (any Error).self) {
            _ = try await coordinator.importFile(at: fixture("pdf-malformed"))
        }
        #expect(try repository.books(matching: LibraryFilter()).isEmpty)
        #expect(try children(root.appending(path: "Staging")).isEmpty)
        #expect(try children(root.appending(path: "Books")).isEmpty)
        #expect(try children(root.appending(path: "Covers")).isEmpty)
    }

    @Test("PDF completion distinguishes paging from final-page scrolling")
    func completionRules() {
        #expect(ReaderEndDetection.hasReachedPDFEnd(
            currentPage: 5,
            pageCount: 5,
            isScrolling: false,
            visibleBottom: nil,
            contentHeight: nil
        ))
        #expect(!ReaderEndDetection.hasReachedPDFEnd(
            currentPage: 5,
            pageCount: 5,
            isScrolling: true,
            visibleBottom: 700,
            contentHeight: 1000
        ))
        #expect(ReaderEndDetection.hasReachedPDFEnd(
            currentPage: 5,
            pageCount: 5,
            isScrolling: true,
            visibleBottom: 999.5,
            contentHeight: 1000
        ))
        #expect(!ReaderEndDetection.hasReachedPDFEnd(
            currentPage: 4,
            pageCount: 5,
            isScrolling: false,
            visibleBottom: nil,
            contentHeight: nil
        ))
    }

    @Test("PDF page text is segmented on grapheme-safe bounded whitespace")
    func boundedSegmentation() {
        let text = String(repeating: "слово ", count: 20001)
        let segments = PDFSpeedContentProvider.split(text)

        #expect(segments.count == 2)
        #expect(segments.allSatisfy { $0.count <= 100_000 })
        #expect(segments.joined(separator: " ").split(whereSeparator: \.isWhitespace).count == 20001)
    }
}

@Suite("PDF OCR layout regression")
struct PDFOCRLayoutTests {
    @Test("Split observations form logical lines before confidence and layout gates")
    func logicalLines() throws {
        let observations = [
            line("Автор", left: 0.10, top: 0.10, width: 0.08, confidence: 1),
            line("этой", left: 0.20, top: 0.10, width: 0.07, confidence: 1),
            line("книги", left: 0.29, top: 0.10, width: 0.08, confidence: 0.3),
            line("Николай", left: 0.39, top: 0.10, width: 0.12, confidence: 1),
            line("Александрович", left: 0.53, top: 0.10, width: 0.18, confidence: 1)
        ]

        let assembled = PDFTextLayout.assembleOCRLines(observations)
        #expect(assembled.count == 1)
        let logicalLine = try #require(assembled.first)
        #expect(logicalLine.text == "Автор этой книги Николай Александрович")
        #expect(logicalLine.confidence > 0.75)
        #expect(logicalLine.rect.left == 0.10)
        #expect(logicalLine.rect.maxX == 0.71)
    }

    @Test("Full-width prose is not rejected by isolated page furniture")
    func singleColumnWithPageFurniture() throws {
        let lines = [
            line("A full width prose line crosses the page center", left: 0.08, top: 0.20, width: 0.84),
            line("Another full width prose line keeps reading order", left: 0.08, top: 0.24, width: 0.84),
            line("A third full width prose line establishes the body", left: 0.08, top: 0.28, width: 0.84),
            line("Left header", left: 0.08, top: 0.08, width: 0.16),
            line("Left note", left: 0.08, top: 0.34, width: 0.16),
            line("Left footer", left: 0.08, top: 0.90, width: 0.16),
            line("Right header", left: 0.76, top: 0.08, width: 0.16),
            line("Right note", left: 0.76, top: 0.34, width: 0.16),
            line("Right footer", left: 0.76, top: 0.90, width: 0.16)
        ]

        let ordered = try #require(PDFTextLayout.orderedLines(lines))
        #expect(ordered.count == lines.count)
        #expect(ordered.map(\.text).contains("A third full width prose line establishes the body"))
    }

    @Test("Sustained two-column prose keeps column reading order")
    func sustainedTwoColumns() throws {
        let lines = [
            line("Spanning title", left: 0.08, top: 0.08, width: 0.84),
            line("Left one", left: 0.08, top: 0.20, width: 0.32),
            line("Left two", left: 0.08, top: 0.24, width: 0.32),
            line("Left three", left: 0.08, top: 0.28, width: 0.32),
            line("Right one", left: 0.60, top: 0.20, width: 0.32),
            line("Right two", left: 0.60, top: 0.24, width: 0.32),
            line("Right three", left: 0.60, top: 0.28, width: 0.32)
        ]

        let ordered = try #require(PDFTextLayout.orderedLines(lines))
        #expect(
            ordered.map(\.text) == [
                "Spanning title",
                "Left one", "Left two", "Left three",
                "Right one", "Right two", "Right three"
            ]
        )
    }
}

@Suite("PDF prefetch")
@MainActor
struct PDFPrefetchTests {
    @Test("Seeking cancels in-flight adjacent-page OCR prefetch")
    func seekCancelsPrefetch() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileStore = try ApplicationSupportBookFileStore(rootURL: root)
        let provider = try await ReadiumPublicationService().makeSpeedContentProvider(
            at: fixture("pdf-long-scanned"),
            contentHash: "prefetch-cancellation",
            fileStore: fileStore
        )

        _ = try await provider.start(at: nil)
        try await Task.sleep(for: .milliseconds(50))
        _ = try await provider.seek(toTotalProgression: 1)

        #expect(
            try await fileStore.derivedData(
                relativePath: "prefetch-cancellation/pdf-text-v2/page-1.json"
            ) == nil
        )
    }
}

private func fixture(_ name: String) throws -> URL {
    let bundle = Bundle(for: PDFTestBundleToken.self)
    guard let url = bundle.url(forResource: name, withExtension: "pdf") else {
        throw PDFTestError.missingFixture(name)
    }
    return url
}

private func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "FastReaderPDFTests-\(UUID().uuidString)", directoryHint: .isDirectory)
}

private func children(_ url: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
}

private func line(
    _ text: String,
    left: Double,
    top: Double,
    width: Double,
    height: Double = 0.02,
    confidence: Float = 1
) -> PDFTextLine {
    PDFTextLine(
        text: text,
        rect: NormalizedRect(left: left, top: top, width: width, height: height),
        confidence: confidence
    )
}
