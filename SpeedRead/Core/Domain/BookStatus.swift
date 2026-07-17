import Foundation

enum BookStatus: String, CaseIterable, Codable, Sendable {
    case new
    case reading
    case done
    case canceled

    var localizedName: String {
        switch self {
        case .new:
            String(localized: "status.new")
        case .reading:
            String(localized: "status.reading")
        case .done:
            String(localized: "status.done")
        case .canceled:
            String(localized: "status.canceled")
        }
    }
}

enum BookStatusTransition {
    static func status(
        afterProgress progress: Double,
        reachedPublicationEnd: Bool,
        currentStatus: BookStatus
    ) -> BookStatus {
        switch currentStatus {
        case .canceled, .done:
            currentStatus
        case .new where progress > 0:
            reachedPublicationEnd ? .done : .reading
        case .reading where reachedPublicationEnd:
            .done
        case .new, .reading:
            currentStatus
        }
    }
}
