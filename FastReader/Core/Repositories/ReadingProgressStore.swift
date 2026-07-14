import Foundation

@MainActor
protocol ReadingProgressStore: AnyObject {
    func readingPosition(for bookID: UUID) throws -> ReadingPosition?
    func markOpened(bookID: UUID, at date: Date) throws
    func saveReadingPosition(
        _ position: ReadingPosition,
        for bookID: UUID,
        reachedPublicationEnd: Bool
    ) throws
}
