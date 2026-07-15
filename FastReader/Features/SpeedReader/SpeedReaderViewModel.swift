import Foundation
import Observation

@MainActor
@Observable
final class SpeedReaderViewModel {
    enum State {
        case loading
        case ready(SpeedReaderSession)
        case unavailable(String)
        case failure(String)
    }

    private(set) var state: State = .loading
    private(set) var progress: Double
    var saveFailureMessage: String?

    private let book: Book
    private let fileStore: any BookFileStore
    private let publicationService: any PublicationService
    private let progressStore: any ReadingProgressStore
    private var pendingPosition: SpeedPositionSnapshot?
    private var saveTask: Task<Void, Never>?

    init(
        book: Book,
        fileStore: any BookFileStore,
        publicationService: any PublicationService,
        progressStore: any ReadingProgressStore
    ) {
        self.book = book
        self.fileStore = fileStore
        self.publicationService = publicationService
        self.progressStore = progressStore
        progress = book.progress
    }

    func load(settings: SpeedReaderSettings) async {
        guard case .loading = state else {
            return
        }
        do {
            guard await fileStore.fileExists(relativePath: book.fileRelativePath) else {
                state = .failure(String(localized: "reader.error.missingFile"))
                return
            }
            let fileURL = try await fileStore.fileURL(relativePath: book.fileRelativePath)
            let savedPosition = try progressStore.readingPosition(for: book.id)
            let provider = try await publicationService.makeSpeedContentProvider(
                at: fileURL,
                contentHash: book.contentHash,
                fileStore: fileStore
            )
            let session = SpeedReaderSession(provider: provider, settings: settings)
            do {
                try await session.start(from: savedPosition)
            } catch let error as SpeedContentError {
                state = .unavailable(error.userMessage)
                return
            }
            session.onPositionChange = { [weak self] snapshot in
                self?.receive(snapshot)
            }
            try progressStore.markOpened(bookID: book.id, at: .now)
            progress = session.progress
            state = .ready(session)
        } catch let error as SpeedContentError {
            state = .unavailable(error.userMessage)
        } catch {
            state = .failure(String(localized: "speed.error.open"))
        }
    }

    func flushPosition() {
        saveTask?.cancel()
        saveTask = nil
        if pendingPosition == nil, case let .ready(session) = state {
            pendingPosition = session.currentPosition()
        }
        persistPendingPosition()
    }

    func stopAndFlush() {
        if case let .ready(session) = state {
            session.stop()
        }
        flushPosition()
    }

    func dismissSaveFailure() {
        saveFailureMessage = nil
    }

    private func receive(_ snapshot: SpeedPositionSnapshot) {
        pendingPosition = snapshot
        progress = snapshot.totalProgression
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }
            guard !Task.isCancelled else {
                return
            }
            self?.persistPendingPosition()
        }
    }

    private func persistPendingPosition() {
        guard let snapshot = pendingPosition else {
            return
        }
        do {
            try progressStore.saveReadingPosition(
                ReadingPosition(
                    locatorJSON: snapshot.locatorJSON,
                    totalProgression: snapshot.totalProgression,
                    speedElementID: snapshot.elementID,
                    speedTokenOffset: snapshot.tokenOffset,
                    updatedAt: .now
                ),
                for: book.id,
                reachedPublicationEnd: snapshot.reachedPublicationEnd
            )
            pendingPosition = nil
        } catch {
            saveFailureMessage = String(localized: "reader.error.save")
        }
    }
}
