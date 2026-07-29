import Foundation

enum ProFeature: CaseIterable, Equatable, Sendable {
    case unlimitedLibrary
    case privateCloudSync
}

struct ProAccessPolicy: Equatable, Sendable {
    static let freeLibraryLimit = 3

    let hasProAccess: Bool

    func allows(_: ProFeature) -> Bool {
        hasProAccess
    }

    func canAddBook(toLibraryCount count: Int) -> Bool {
        hasProAccess || count < Self.freeLibraryLimit
    }
}

enum ProAccessError: Error, Equatable, Sendable {
    case freeLibraryLimit
}
