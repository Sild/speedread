import Foundation
import Observation

@MainActor
@Observable
final class RegularReaderViewModel {
    enum State {
        case loading
        case ready(RegularReaderSession)
        case failure(String)
    }

    private(set) var state: State = .loading
    private(set) var progress: Double
    var showsChrome = true
    var saveFailureMessage: String?

    private let book: Book
    private let fileStore: any BookFileStore
    private let publicationService: any PublicationService
    private let progressStore: any ReadingProgressStore
    private var persistedPosition: ReadingPosition?
    private var pendingPosition: ReaderPositionSnapshot?
    private var saveTask: Task<Void, Never>?
    private var chromeHideTask: Task<Void, Never>?

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

    func load(
        preferences: RegularReaderPreferences,
        highlightLocatorJSON: String? = nil
    ) async {
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
            persistedPosition = savedPosition
            let session = try await publicationService.makeRegularReaderSession(
                at: fileURL,
                initialLocatorJSON: savedPosition?.locatorJSON,
                highlightLocatorJSON: highlightLocatorJSON,
                preferences: preferences
            )
            session.onPositionChange = { [weak self] snapshot in
                self?.receive(snapshot)
            }
            session.onToggleChrome = { [weak self] in
                self?.toggleChrome()
            }
            try progressStore.markOpened(bookID: book.id, at: .now)
            state = .ready(session)
            scheduleChromeHide()
        } catch {
            state = .failure(String(localized: "reader.error.open"))
        }
    }

    func apply(_ preferences: RegularReaderPreferences) {
        guard case let .ready(session) = state else {
            return
        }
        session.apply(preferences)
    }

    func flushPosition() {
        saveTask?.cancel()
        saveTask = nil
        chromeHideTask?.cancel()
        chromeHideTask = nil
        if pendingPosition == nil, case let .ready(session) = state {
            pendingPosition = session.currentPosition()
        }
        persistPendingPosition()
    }

    func retry(preferences: RegularReaderPreferences) async {
        state = .loading
        await load(preferences: preferences)
    }

    func reload(
        preferences: RegularReaderPreferences,
        highlightLocatorJSON: String?
    ) async {
        saveTask?.cancel()
        saveTask = nil
        chromeHideTask?.cancel()
        chromeHideTask = nil
        pendingPosition = nil
        state = .loading
        await load(
            preferences: preferences,
            highlightLocatorJSON: highlightLocatorJSON
        )
    }

    func dismissSaveFailure() {
        saveFailureMessage = nil
    }

    func toggleChrome() {
        chromeHideTask?.cancel()
        chromeHideTask = nil
        showsChrome.toggle()
        if showsChrome {
            scheduleChromeHide()
        }
    }

    func setChromeAutoHidePaused(_ paused: Bool) {
        chromeHideTask?.cancel()
        chromeHideTask = nil
        showsChrome = true
        if !paused {
            scheduleChromeHide()
        }
    }

    private func receive(_ snapshot: ReaderPositionSnapshot) {
        pendingPosition = snapshot
        progress = snapshot.totalProgression
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(700))
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
            let position = if let persistedPosition {
                persistedPosition.updatingFromRegularReader(
                    locatorJSON: snapshot.locatorJSON,
                    totalProgression: snapshot.totalProgression,
                    preserveSpeedCursor: snapshot.preservesSpeedCursor,
                    at: .now
                )
            } else {
                ReadingPosition(
                    locatorJSON: snapshot.locatorJSON,
                    totalProgression: snapshot.totalProgression,
                    speedElementID: nil,
                    speedTokenOffset: nil,
                    updatedAt: .now
                )
            }
            try progressStore.saveReadingPosition(
                position,
                for: book.id,
                reachedPublicationEnd: snapshot.reachedPublicationEnd
            )
            persistedPosition = position
            pendingPosition = nil
        } catch {
            saveFailureMessage = String(localized: "reader.error.save")
        }
    }

    private func scheduleChromeHide() {
        chromeHideTask?.cancel()
        chromeHideTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(4))
            } catch {
                return
            }
            guard !Task.isCancelled else {
                return
            }
            self?.showsChrome = false
        }
    }
}
