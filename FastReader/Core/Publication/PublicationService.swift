import Foundation
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
protocol PublicationService: AnyObject {
    func inspectEPUB(at url: URL) async throws -> PublicationMetadataSnapshot
    func makeRegularReaderSession(
        at url: URL,
        initialLocatorJSON: String?,
        highlightLocatorJSON: String?,
        preferences: RegularReaderPreferences
    ) async throws -> RegularReaderSession
    func makeSpeedContentProvider(at url: URL) async throws -> any SpeedContentProviding
}

@MainActor
final class ReadiumPublicationService: PublicationService {
    private let assetRetriever: AssetRetriever
    private let publicationOpener: PublicationOpener

    init() {
        let assetRetriever = AssetRetriever(httpClient: DefaultHTTPClient())
        self.assetRetriever = assetRetriever
        publicationOpener = PublicationOpener(parser: EPUBParser())
    }

    func inspectEPUB(at url: URL) async throws -> PublicationMetadataSnapshot {
        let opened = try await openEPUB(at: url)
        let publication = opened.publication

        let coverData: Data?
        switch await publication.cover() {
        case let .success(image):
            coverData = image?.pngData()
        case .failure:
            throw PublicationServiceError.coverExtractionFailed
        }

        return PublicationMetadataSnapshot(
            title: publication.metadata.title,
            authorsDisplay: publication.metadata.authors.map(\.name).joined(separator: ", "),
            mediaType: opened.asset.format.mediaType?.string ?? "application/epub+zip",
            layout: publication.metadata.layout == .fixed ? .fixed : .reflowable,
            coverPNGData: coverData
        )
    }

    func makeRegularReaderSession(
        at url: URL,
        initialLocatorJSON: String?,
        highlightLocatorJSON: String?,
        preferences: RegularReaderPreferences
    ) async throws -> RegularReaderSession {
        let opened = try await openEPUB(at: url)
        return try RegularReaderSession(
            publication: opened.publication,
            initialLocatorJSON: initialLocatorJSON,
            highlightLocatorJSON: highlightLocatorJSON,
            preferences: preferences
        )
    }

    func makeSpeedContentProvider(at url: URL) async throws -> any SpeedContentProviding {
        let opened = try await openEPUB(at: url)
        return ReadiumSpeedContentProvider(publication: opened.publication)
    }

    private func openEPUB(at url: URL) async throws -> (asset: Asset, publication: Publication) {
        guard let absoluteURL = url.anyURL.absoluteURL else {
            throw PublicationServiceError.invalidURL
        }
        let asset: Asset
        switch await assetRetriever.retrieve(url: absoluteURL) {
        case let .success(value):
            asset = value
        case .failure:
            throw PublicationServiceError.unreadable
        }
        guard asset.format.conformsTo(.epub) else {
            throw PublicationServiceError.unsupportedFormat
        }

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
        let permittedObfuscationAlgorithms: Set = [
            "http://www.idpf.org/2008/embedding",
            "http://ns.adobe.com/pdf/enc#RC"
        ]
        let encryptions = (publication.readingOrder + publication.resources)
            .compactMap(\.properties.encryption)
        guard encryptions.allSatisfy({ permittedObfuscationAlgorithms.contains($0.algorithm) }) else {
            throw PublicationServiceError.protectedPublication
        }
        return (asset, publication)
    }
}
