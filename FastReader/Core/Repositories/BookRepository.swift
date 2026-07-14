import Foundation

@MainActor
protocol BookRepository: AnyObject {
    func books(matching filter: LibraryFilter) throws -> [Book]
    func book(id: UUID) throws -> Book?
    func book(contentHash: String) throws -> Book?
    func tags() throws -> [Tag]
    func insert(_ publication: ImportedPublication, importedAt: Date) throws -> Book
    func setStatus(_ status: BookStatus, for bookID: UUID, at date: Date) throws
    func setTags(_ displayNames: [String], for bookID: UUID, at date: Date) throws
    func delete(bookID: UUID, at date: Date) throws -> Book
}

enum BookRepositoryError: Error, Equatable, Sendable {
    case invalidStatus(String)
    case invalidLayout(String)
    case missingBook(UUID)
    case duplicateContent(String)
    case emptyTag
}
