import CoreGraphics
import Foundation
@preconcurrency import PDFKit
import Vision

actor PDFPageTextExtractor {
    static let cacheVersion = 2

    private static let maximumRenderedDimension = 2048.0
    private static let minimumEmbeddedCharacters = 20
    private static let minimumOCRAverageConfidence: Float = 0.80
    private static let minimumOCRLineConfidence: Float = 0.50

    private let document: PDFDocument
    private let contentHash: String
    private let fileStore: any BookFileStore

    init(
        fileURL: URL,
        contentHash: String,
        fileStore: any BookFileStore
    ) throws {
        guard let document = PDFDocument(url: fileURL) else {
            throw SpeedContentError.extractionFailed
        }
        self.document = document
        self.contentHash = contentHash
        self.fileStore = fileStore
    }

    func text(forPage index: Int) async throws -> PDFPageText {
        guard document.pageCount > 0, document.pageCount > index, index >= 0 else {
            throw SpeedContentError.unavailable
        }
        try Task.checkCancellation()

        if let cached = try await cachedEntry(forPage: index) {
            return try cached.result.value(pageNumber: index + 1)
        }

        let result = extract(pageAt: index)
        try Task.checkCancellation()
        let entry = PDFPageCacheEntry(
            version: Self.cacheVersion,
            pageIndex: index,
            result: result
        )
        let data = try JSONEncoder().encode(entry)
        try await fileStore.writeDerivedData(data, relativePath: cachePath(forPage: index))
        try Task.checkCancellation()
        return try result.value(pageNumber: index + 1)
    }

    func prepare(page index: Int) async {
        guard index >= 0, index < document.pageCount else {
            return
        }
        _ = try? await text(forPage: index)
    }

    private func cachedEntry(forPage index: Int) async throws -> PDFPageCacheEntry? {
        guard let data = try await fileStore.derivedData(relativePath: cachePath(forPage: index)) else {
            return nil
        }
        guard let entry = try? JSONDecoder().decode(PDFPageCacheEntry.self, from: data) else {
            return nil
        }
        guard entry.version == Self.cacheVersion, entry.pageIndex == index else {
            return nil
        }
        return entry
    }

    private func cachePath(forPage index: Int) -> String {
        "\(contentHash)/pdf-text-v\(Self.cacheVersion)/page-\(index).json"
    }

    private func extract(pageAt index: Int) -> PDFPageCacheResult {
        guard !document.isLocked else {
            return .failure(.protectedDocument)
        }
        guard document.allowsCopying else {
            return .failure(.copyRestricted)
        }
        guard let page = document.page(at: index) else {
            return .failure(.extractionFailed)
        }

        if let embeddedLines = embeddedLines(from: page) {
            if Self.characterCount(in: embeddedLines) >= Self.minimumEmbeddedCharacters {
                return Self.normalizedResult(lines: embeddedLines, source: .embedded)
            }
        }

        do {
            let lines = try ocrLines(from: page)
            return Self.normalizedResult(lines: lines, source: .ocr)
        } catch {
            return .failure(.ocrFailed)
        }
    }

    private func embeddedLines(from page: PDFPage) -> [PDFTextLine]? {
        let pageBounds = page.bounds(for: .cropBox)
        guard pageBounds.width > 0, pageBounds.height > 0,
              let selection = page.selection(for: pageBounds)
        else {
            return nil
        }
        return selection.selectionsByLine().compactMap { selection in
            guard let text = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty
            else {
                return nil
            }
            return PDFTextLine(
                text: text,
                rect: Self.normalizedRect(
                    selection.bounds(for: page),
                    within: pageBounds
                ),
                confidence: 1
            )
        }
    }

    private func ocrLines(from page: PDFPage) throws -> [PDFTextLine] {
        let bounds = page.bounds(for: .cropBox)
        guard bounds.width > 0, bounds.height > 0 else {
            throw SpeedContentError.extractionFailed
        }
        let scale = min(
            Self.maximumRenderedDimension / max(bounds.width, bounds.height),
            4
        )
        let image = page.thumbnail(
            of: CGSize(width: bounds.width * scale, height: bounds.height * scale),
            for: .cropBox
        )
        guard let cgImage = image.cgImage else {
            throw SpeedContentError.extractionFailed
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        let observations = (request.results ?? []).compactMap { observation -> PDFTextLine? in
            guard let candidate = observation.topCandidates(1).first else {
                return nil
            }
            let box = observation.boundingBox
            return PDFTextLine(
                text: candidate.string,
                rect: NormalizedRect(
                    left: box.minX,
                    top: 1 - box.maxY,
                    width: box.width,
                    height: box.height
                ),
                confidence: candidate.confidence
            )
        }
        return PDFTextLayout.assembleOCRLines(observations)
    }

    private static func normalizedResult(
        lines: [PDFTextLine],
        source: PDFPageText.Source
    ) -> PDFPageCacheResult {
        let substantive = lines.filter { characterCount(in: [$0]) >= 3 }
        guard !substantive.isEmpty else {
            return .failure(.unsupportedText)
        }
        if source == .ocr {
            let totalCharacters = substantive.reduce(0) { $0 + characterCount(in: [$1]) }
            let weightedConfidence = substantive.reduce(Float.zero) { partial, line in
                partial + line.confidence * Float(characterCount(in: [line]))
            } / Float(max(totalCharacters, 1))
            guard weightedConfidence >= minimumOCRAverageConfidence,
                  substantive.allSatisfy({ $0.confidence >= minimumOCRLineConfidence })
            else {
                return .failure(.lowConfidence)
            }
        }

        let normalizedLines = lines.map {
            PDFTextLine(
                text: $0.text.precomposedStringWithCanonicalMapping,
                rect: $0.rect,
                confidence: $0.confidence
            )
        }
        guard supportsSpeedReadScripts(normalizedLines.map(\.text).joined(separator: " ")) else {
            return .failure(.unsupportedText)
        }
        guard let ordered = PDFTextLayout.orderedLines(normalizedLines),
              !PDFTextLayout.isTableLike(ordered)
        else {
            return .failure(.lowConfidence)
        }
        let text = PDFTextLayout.join(ordered)
        guard characterCount(in: text) >= minimumEmbeddedCharacters else {
            return .failure(.unsupportedText)
        }
        return .text(PDFPageText(text: text, source: source))
    }

    private static func normalizedRect(_ rect: CGRect, within bounds: CGRect) -> NormalizedRect {
        NormalizedRect(
            left: (rect.minX - bounds.minX) / bounds.width,
            top: (bounds.maxY - rect.maxY) / bounds.height,
            width: rect.width / bounds.width,
            height: rect.height / bounds.height
        )
    }

    private static func characterCount(in lines: [PDFTextLine]) -> Int {
        characterCount(in: lines.map(\.text).joined())
    }

    private static func characterCount(in text: String) -> Int {
        text.unicodeScalars.count { CharacterSet.alphanumerics.contains($0) }
    }

    private static func supportsSpeedReadScripts(_ text: String) -> Bool {
        var supportedLetters = 0
        var unsupportedLetters = 0
        for scalar in text.unicodeScalars where CharacterSet.letters.contains(scalar) {
            switch scalar.value {
            case 0x0041 ... 0x024F, 0x0400 ... 0x052F:
                supportedLetters += 1
            default:
                unsupportedLetters += 1
            }
        }
        guard supportedLetters > 0 else {
            return false
        }
        return Double(unsupportedLetters) / Double(supportedLetters + unsupportedLetters) <= 0.10
    }
}

struct PDFPageText: Equatable, Sendable, Codable {
    enum Source: String, Equatable, Sendable, Codable {
        case embedded
        case ocr
    }

    let text: String
    let source: Source
}

private struct PDFPageCacheEntry: Codable {
    let version: Int
    let pageIndex: Int
    let result: PDFPageCacheResult
}

private enum PDFPageCacheResult: Codable {
    case text(PDFPageText)
    case failure(PDFPageFailure)

    func value(pageNumber: Int) throws -> PDFPageText {
        switch self {
        case let .text(value):
            value
        case let .failure(failure):
            throw failure.speedError(pageNumber: pageNumber)
        }
    }
}

private enum PDFPageFailure: String, Codable {
    case protectedDocument
    case copyRestricted
    case lowConfidence
    case unsupportedText
    case ocrFailed
    case extractionFailed

    func speedError(pageNumber: Int) -> SpeedContentError {
        switch self {
        case .protectedDocument, .extractionFailed:
            .extractionFailed
        case .copyRestricted:
            .copyRestricted
        case .lowConfidence:
            .lowConfidence(page: pageNumber)
        case .unsupportedText:
            .unsupportedText(page: pageNumber)
        case .ocrFailed:
            .ocrFailed(page: pageNumber)
        }
    }
}
