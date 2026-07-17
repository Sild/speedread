import Foundation
import SwiftUI

enum ReaderMode: String, Equatable {
    case regular
    case speed
}

struct ReaderModePreferenceStore {
    private static let keyPrefix = "reader.lastMode."

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func mode(for contentHash: String) -> ReaderMode {
        guard let rawValue = defaults.string(forKey: Self.storageKey(for: contentHash)),
              let mode = ReaderMode(rawValue: rawValue)
        else {
            return .regular
        }
        return mode
    }

    func set(_ mode: ReaderMode, for contentHash: String) {
        defaults.set(mode.rawValue, forKey: Self.storageKey(for: contentHash))
    }

    func removeAll() {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Self.keyPrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    static func storageKey(for contentHash: String) -> String {
        keyPrefix + contentHash
    }
}

struct ReaderBackButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .frame(width: 52, height: 52)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("reader.back")
        .accessibilityIdentifier("reader.back")
    }
}

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
