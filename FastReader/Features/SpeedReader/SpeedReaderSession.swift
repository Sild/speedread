import Foundation
import Observation

@MainActor
@Observable
final class SpeedReaderSession {
    private(set) var tokens: [SpeedToken] = []
    private(set) var tokenIndex = 0
    private(set) var isPlaying = false
    private(set) var progress = 0.0
    private(set) var failureMessage: String?
    private(set) var settings: SpeedReaderSettings

    @ObservationIgnored var onPositionChange: ((SpeedPositionSnapshot) -> Void)?

    @ObservationIgnored private let provider: any SpeedContentProviding
    @ObservationIgnored private let clock = ContinuousClock()
    @ObservationIgnored private var playbackTask: Task<Void, Never>?

    init(provider: any SpeedContentProviding, settings: SpeedReaderSettings) {
        self.provider = provider
        self.settings = settings
    }

    deinit {
        playbackTask?.cancel()
    }

    var currentToken: SpeedToken? {
        tokens.indices.contains(tokenIndex) ? tokens[tokenIndex] : nil
    }

    var previousContext: [String] {
        guard !tokens.isEmpty else {
            return []
        }
        let start = max(0, tokenIndex - 3)
        return tokens[start ..< tokenIndex].map(\.text)
    }

    var nextContext: [String] {
        guard !tokens.isEmpty else {
            return []
        }
        let end = min(tokens.count, tokenIndex + 4)
        guard tokenIndex + 1 < end else {
            return []
        }
        return tokens[(tokenIndex + 1) ..< end].map(\.text)
    }

    func start(from position: ReadingPosition?) async throws {
        guard let element = try await provider.start(at: position?.locatorJSON) else {
            throw SpeedContentError.unavailable
        }
        try load(
            element,
            preferredElementID: position?.speedElementID,
            preferredOffset: position?.speedTokenOffset
        )
        emitPosition(reachedPublicationEnd: false)
    }

    func updateSettings(_ settings: SpeedReaderSettings) {
        self.settings = settings
    }

    func togglePlayback() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func play() {
        guard !isPlaying, currentToken != nil else {
            return
        }
        isPlaying = true
        playbackTask?.cancel()
        let playbackClock = clock
        playbackTask = Task { [weak self, playbackClock] in
            while !Task.isCancelled {
                guard let milliseconds = self?.currentPlaybackDelay else {
                    return
                }
                do {
                    try await playbackClock.sleep(for: .milliseconds(milliseconds))
                } catch {
                    return
                }
                guard !Task.isCancelled, let self, isPlaying else {
                    return
                }
                await advance()
            }
        }
    }

    func pause() {
        isPlaying = false
        playbackTask?.cancel()
        playbackTask = nil
    }

    func stop() {
        pause()
    }

    func moveNext() async {
        pause()
        await advance()
    }

    func movePrevious() async {
        pause()
        if tokenIndex > 0 {
            tokenIndex -= 1
            emitPosition(reachedPublicationEnd: false)
            return
        }
        do {
            guard let element = try await provider.previous() else {
                return
            }
            try load(element, preferredElementID: nil, preferredOffset: nil)
            tokenIndex = max(tokens.count - 1, 0)
            emitPosition(reachedPublicationEnd: false)
        } catch let error as SpeedContentError {
            failureMessage = error.userMessage
        } catch {
            failureMessage = String(localized: "speed.error.navigation")
        }
    }

    func seek(to progression: Double) async {
        pause()
        do {
            guard let element = try await provider.seek(toTotalProgression: progression) else {
                throw SpeedContentError.unavailable
            }
            try load(element, preferredElementID: nil, preferredOffset: nil)
            emitPosition(reachedPublicationEnd: false)
        } catch let error as SpeedContentError {
            failureMessage = error.userMessage
        } catch {
            failureMessage = String(localized: "speed.error.navigation")
        }
    }

    func dismissFailure() {
        failureMessage = nil
    }

    func currentPosition(reachedPublicationEnd: Bool = false) -> SpeedPositionSnapshot? {
        guard let token = currentToken else {
            return nil
        }
        return SpeedPositionSnapshot(
            locatorJSON: token.locatorJSON,
            totalProgression: reachedPublicationEnd ? 1 : token.totalProgression,
            elementID: token.elementID,
            tokenOffset: token.offset,
            reachedPublicationEnd: reachedPublicationEnd
        )
    }

    private func advance() async {
        if tokenIndex + 1 < tokens.count {
            tokenIndex += 1
            emitPosition(reachedPublicationEnd: false)
            return
        }
        do {
            guard let element = try await provider.next() else {
                pause()
                progress = 1
                emitPosition(reachedPublicationEnd: true)
                return
            }
            try load(element, preferredElementID: nil, preferredOffset: nil)
            emitPosition(reachedPublicationEnd: false)
        } catch let error as SpeedContentError {
            pause()
            failureMessage = error.userMessage
        } catch {
            pause()
            failureMessage = String(localized: "speed.error.navigation")
        }
    }

    private func load(
        _ element: SpeedContentElement,
        preferredElementID: String?,
        preferredOffset: Int?
    ) throws {
        let extractedTokens = SpeedTokenizer.tokenize(element)
        guard !extractedTokens.isEmpty else {
            throw SpeedContentError.unavailable
        }
        tokens = extractedTokens
        let preferredIndex: Int? = if let preferredElementID, let preferredOffset {
            extractedTokens.firstIndex(where: {
                $0.elementID == preferredElementID && $0.offset == preferredOffset
            })
        } else {
            nil
        }
        if let preferredIndex {
            tokenIndex = preferredIndex
        } else {
            tokenIndex = 0
        }
        progress = extractedTokens[tokenIndex].totalProgression
    }

    private func emitPosition(reachedPublicationEnd: Bool) {
        guard let snapshot = currentPosition(reachedPublicationEnd: reachedPublicationEnd) else {
            return
        }
        progress = snapshot.totalProgression
        onPositionChange?(snapshot)
    }

    private var currentPlaybackDelay: Int64? {
        guard isPlaying, let currentToken else {
            return nil
        }
        return SpeedPacing.durationMilliseconds(for: currentToken, settings: settings)
    }
}
