import Foundation
@preconcurrency import PDFKit
@preconcurrency import ReadiumAdapterGCDWebServer
@preconcurrency import ReadiumNavigator
@preconcurrency import ReadiumShared
@preconcurrency import ReadiumStreamer
import UIKit

enum PublicationServiceError: Error, Equatable, Sendable {
    case invalidURL
    case unsupportedFormat
    case unreadable
    case protectedPublication
    case coverExtractionFailed
}

@MainActor
protocol PublicationService: AnyObject, Sendable {
    func inspectPublication(at url: URL) async throws -> PublicationMetadataSnapshot
    func makeRegularReaderSession(
        at url: URL,
        initialLocatorJSON: String?,
        highlightLocatorJSON: String?,
        preferences: RegularReaderPreferences
    ) async throws -> RegularReaderSession
    func makeSpeedContentProvider(
        at url: URL,
        contentHash: String,
        fileStore: any BookFileStore
    ) async throws -> any SpeedContentProviding
}

@MainActor
final class ReadiumPublicationService: PublicationService {
    private let assetRetriever: AssetRetriever
    private let publicationOpener: PublicationOpener
    private let httpServer: HTTPServer

    init() {
        let httpClient = DefaultHTTPClient()
        let assetRetriever = AssetRetriever(httpClient: httpClient)
        self.assetRetriever = assetRetriever
        publicationOpener = PublicationOpener(
            parser: DefaultPublicationParser(
                httpClient: httpClient,
                assetRetriever: assetRetriever,
                pdfFactory: DefaultPDFDocumentFactory()
            )
        )
        httpServer = GCDHTTPServer(assetRetriever: assetRetriever)
    }

    func inspectPublication(at url: URL) async throws -> PublicationMetadataSnapshot {
        let opened = try await openPublication(at: url)
        let publication = opened.publication

        let coverData: Data?
        switch await publication.cover() {
        case let .success(image):
            if opened.format == .pdf {
                coverData = image.flatMap(Self.boundedPDFCover)?.pngData()
            } else {
                coverData = image?.pngData()
            }
        case .failure where opened.format == .pdf:
            coverData = nil
        case .failure:
            throw PublicationServiceError.coverExtractionFailed
        }

        return PublicationMetadataSnapshot(
            format: opened.format,
            title: publication.metadata.title,
            authorsDisplay: publication.metadata.authors.map(\.name).joined(separator: ", "),
            mediaType: opened.asset.format.mediaType?.string ?? opened.format.defaultMediaType,
            layout: opened.format == .pdf
                ? .fixed
                : publication.metadata.layout == .fixed ? .fixed : .reflowable,
            coverPNGData: coverData
        )
    }

    func makeRegularReaderSession(
        at url: URL,
        initialLocatorJSON: String?,
        highlightLocatorJSON: String?,
        preferences: RegularReaderPreferences
    ) async throws -> RegularReaderSession {
        let opened = try await openPublication(at: url)
        return try RegularReaderSession(
            publication: opened.publication,
            format: opened.format,
            initialLocatorJSON: initialLocatorJSON,
            highlightLocatorJSON: highlightLocatorJSON,
            preferences: preferences,
            httpServer: httpServer
        )
    }

    func makeSpeedContentProvider(
        at url: URL,
        contentHash: String,
        fileStore: any BookFileStore
    ) async throws -> any SpeedContentProviding {
        let opened = try await openPublication(at: url)
        switch opened.format {
        case .epub:
            return ReadiumSpeedContentProvider(publication: opened.publication)
        case .pdf:
            return try await PDFSpeedContentProvider(
                fileURL: url,
                publication: opened.publication,
                contentHash: contentHash,
                fileStore: fileStore
            )
        }
    }

    private func openPublication(at url: URL) async throws -> OpenedPublication {
        guard let absoluteURL = url.anyURL.absoluteURL else {
            throw PublicationServiceError.invalidURL
        }
        let sniffedFormat = try Self.sniffedFormat(at: url)
        let asset: Asset
        switch await assetRetriever.retrieve(url: absoluteURL, format: sniffedFormat) {
        case let .success(value):
            asset = value
        case .failure:
            throw PublicationServiceError.unreadable
        }

        let format = try Self.publicationFormat(for: asset, sourceURL: url)

        let publication: Publication
        switch await publicationOpener.open(asset: asset, allowUserInteraction: false) {
        case let .success(value):
            publication = value
        case .failure:
            throw PublicationServiceError.unreadable
        }
        guard !publication.isRestricted else {
            throw PublicationServiceError.protectedPublication
        }

        try Self.validateProtection(of: publication, format: format)
        return OpenedPublication(asset: asset, publication: publication, format: format)
    }

    private static func publicationFormat(
        for asset: Asset,
        sourceURL: URL
    ) throws -> PublicationFormat {
        if asset.format.conformsTo(.epub) {
            return .epub
        }
        guard asset.format.conformsTo(.pdf) else {
            throw PublicationServiceError.unsupportedFormat
        }
        guard let document = PDFDocument(url: sourceURL) else {
            throw PublicationServiceError.unreadable
        }
        guard !document.isLocked else {
            throw PublicationServiceError.protectedPublication
        }
        return .pdf
    }

    private static func validateProtection(
        of publication: Publication,
        format: PublicationFormat
    ) throws {
        guard format == .epub else {
            return
        }
        let permittedObfuscationAlgorithms: Set = [
            "http://www.idpf.org/2008/embedding",
            "http://ns.adobe.com/pdf/enc#RC"
        ]
        let encryptions = (publication.readingOrder + publication.resources)
            .compactMap(\.properties.encryption)
        guard encryptions.allSatisfy({ permittedObfuscationAlgorithms.contains($0.algorithm) }) else {
            throw PublicationServiceError.protectedPublication
        }
    }

    private static func sniffedFormat(at url: URL) throws -> Format {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw PublicationServiceError.unreadable
        }
        defer { try? handle.close() }
        let prefix: Data
        do {
            prefix = try handle.read(upToCount: 1024) ?? Data()
        } catch {
            throw PublicationServiceError.unreadable
        }
        if prefix.range(of: Data("%PDF-".utf8)) != nil {
            return Format(specifications: .pdf, mediaType: .pdf, fileExtension: "pdf")
        }
        let zipSignatures = [
            Data([0x50, 0x4B, 0x03, 0x04]),
            Data([0x50, 0x4B, 0x05, 0x06]),
            Data([0x50, 0x4B, 0x07, 0x08])
        ]
        if zipSignatures.contains(where: { prefix.starts(with: $0) }) {
            return Format(
                specifications: .zip, .epub,
                mediaType: .epub,
                fileExtension: "epub"
            )
        }
        throw PublicationServiceError.unsupportedFormat
    }

    private static func boundedPDFCover(_ image: UIImage) -> UIImage? {
        let maximumDimension: CGFloat = 1200
        let longestDimension = max(image.size.width, image.size.height)
        guard longestDimension > 0 else {
            return nil
        }
        guard longestDimension > maximumDimension else {
            return image
        }
        let scale = maximumDimension / longestDimension
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return UIGraphicsImageRenderer(size: size).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    private struct OpenedPublication {
        let asset: Asset
        let publication: Publication
        let format: PublicationFormat
    }
}
