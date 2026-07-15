import Foundation

enum ReaderTheme: String, CaseIterable, Identifiable, Sendable {
    case system
    case paper
    case dark
    case sepia

    var id: Self {
        self
    }
}

enum ReaderFont: String, CaseIterable, Identifiable, Sendable {
    case publisher
    case serif
    case sansSerif
    case openDyslexic

    var id: Self {
        self
    }
}

struct RegularReaderPreferences: Equatable, Sendable {
    var theme: ReaderTheme = .system
    var font: ReaderFont = .publisher
    var fontScale = 1.0
    var pageMargins = 1.0
    var scroll = false
    var prefersDarkSystemTheme = false
}

struct ReaderOutlineItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let depth: Int
}

struct ReaderPositionSnapshot: Equatable, Sendable {
    let locatorJSON: String
    let totalProgression: Double
    let reachedPublicationEnd: Bool
    let sectionTitle: String?
    let preservesSpeedCursor: Bool
}

enum ReaderEndDetection {
    static func hasReachedEnd(
        finalResourceIsVisible: Bool,
        finalResourceProgressionUpperBound: Double?
    ) -> Bool {
        finalResourceIsVisible && (finalResourceProgressionUpperBound ?? 0) >= 1
    }

    static func hasReachedPDFEnd(
        currentPage: Int?,
        pageCount: Int,
        isScrolling: Bool,
        visibleBottom: Double?,
        contentHeight: Double?
    ) -> Bool {
        guard pageCount > 0, currentPage == pageCount else {
            return false
        }
        guard isScrolling else {
            return true
        }
        guard let visibleBottom, let contentHeight else {
            return false
        }
        return visibleBottom >= contentHeight - 1
    }
}
