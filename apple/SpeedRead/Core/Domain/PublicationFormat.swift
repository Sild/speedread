import Foundation

enum PublicationFormat: String, Codable, Sendable {
    case epub
    case pdf

    init?(pathExtension: String) {
        switch pathExtension.lowercased() {
        case "epub":
            self = .epub
        case "pdf":
            self = .pdf
        default:
            return nil
        }
    }

    init?(mediaType: String) {
        switch mediaType.lowercased() {
        case PublicationFormat.epub.defaultMediaType:
            self = .epub
        case PublicationFormat.pdf.defaultMediaType:
            self = .pdf
        default:
            return nil
        }
    }

    var fileExtension: String {
        rawValue
    }

    var defaultMediaType: String {
        switch self {
        case .epub:
            "application/epub+zip"
        case .pdf:
            "application/pdf"
        }
    }

    var layout: PublicationLayout {
        switch self {
        case .epub:
            .reflowable
        case .pdf:
            .fixed
        }
    }
}
