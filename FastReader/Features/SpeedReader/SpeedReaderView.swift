import SwiftUI

struct SpeedReaderView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var viewModel: SpeedReaderViewModel
    @State private var scrubProgress = 0.0
    @State private var isScrubbing = false

    @AppStorage("speed.wordsPerMinute") private var wordsPerMinute = 300
    @AppStorage("speed.adaptivePauses") private var adaptivePauses = true

    private let book: Book
    private let onSelectRegular: @MainActor (String?) async -> Void
    private let onExitBook: @MainActor () -> Void

    init(
        book: Book,
        fileStore: any BookFileStore,
        publicationService: any PublicationService,
        progressStore: any ReadingProgressStore,
        onSelectRegular: @escaping @MainActor (String?) async -> Void,
        onExitBook: @escaping @MainActor () -> Void
    ) {
        self.book = book
        self.onSelectRegular = onSelectRegular
        self.onExitBook = onExitBook
        _viewModel = State(
            initialValue: SpeedReaderViewModel(
                book: book,
                fileStore: fileStore,
                publicationService: publicationService,
                progressStore: progressStore
            )
        )
    }

    var body: some View {
        ZStack {
            FastReaderPalette.canvas.ignoresSafeArea()
            content
        }
        .task {
            await viewModel.load(settings: settings)
            scrubProgress = viewModel.progress
        }
        .onChange(of: wordsPerMinute) {
            updateSessionSettings()
        }
        .onChange(of: adaptivePauses) {
            updateSessionSettings()
        }
        .onChange(of: scenePhase) {
            if scenePhase != .active {
                viewModel.stopAndFlush()
            }
        }
        .onDisappear {
            viewModel.stopAndFlush()
        }
        .alert("reader.error.save.title", isPresented: saveFailurePresented) {
            Button("action.ok") {
                viewModel.dismissSaveFailure()
            }
        } message: {
            Text(viewModel.saveFailureMessage ?? "")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            ProgressView("speed.loading")
                .accessibilityIdentifier("speed.loading")
        case let .ready(session):
            speedSurface(session)
        case let .unavailable(message):
            ContentUnavailableView {
                Label("speed.unavailable.title", systemImage: "text.magnifyingglass")
            } description: {
                Text(message)
            } actions: {
                Button("speed.return.regular") {
                    returnToRegular()
                }
            }
        case let .failure(message):
            ContentUnavailableView {
                Label("speed.error.title", systemImage: "bolt.slash")
            } description: {
                Text(message)
            } actions: {
                Button("speed.return.regular") {
                    returnToRegular()
                }
            }
        }
    }

    private func speedSurface(_ session: SpeedReaderSession) -> some View {
        VStack(spacing: 0) {
            if !session.isPlaying {
                topBar
                    .transition(.opacity)
            }

            SpeedFocusView(
                token: session.currentToken,
                previous: session.previousContext,
                next: session.nextContext
            )
            .contentShape(Rectangle())
            .onTapGesture {
                session.togglePlayback()
            }
            .accessibilityHidden(true)

            if !session.isPlaying {
                controls(session)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: session.isPlaying)
        .alert("speed.error.navigation.title", isPresented: sessionFailurePresented(session)) {
            Button("speed.return.regular") {
                session.dismissFailure()
                returnToRegular()
            }
        } message: {
            Text(session.failureMessage ?? "")
        }
        .onChange(of: session.progress) {
            guard !isScrubbing else {
                return
            }
            scrubProgress = session.progress
        }
    }
}

private extension SpeedReaderView {
    private var topBar: some View {
        HStack(spacing: FastReaderSpacing.standard) {
            ReaderBackButton {
                viewModel.stopAndFlush()
                onExitBook()
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(book.title)
                    .font(.headline)
                    .lineLimit(1)
                Text("speed.technique")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Toggle("speed.adaptive", isOn: $adaptivePauses)
                    .accessibilityIdentifier("speed.adaptive")
            } label: {
                Image(systemName: "gearshape")
                    .frame(width: 32, height: 32)
            }
            .accessibilityLabel("speed.settings")
            .accessibilityIdentifier("speed.settings")
        }
        .padding(.horizontal, FastReaderSpacing.standard)
        .padding(.vertical, FastReaderSpacing.small)
        .background(.regularMaterial)
    }

    private func controls(_ session: SpeedReaderSession) -> some View {
        VStack(spacing: FastReaderSpacing.medium) {
            HStack {
                Text(session.progress, format: .percent.precision(.fractionLength(0)))
                    .font(.caption.monospacedDigit())
                Slider(
                    value: $scrubProgress,
                    in: 0 ... 1,
                    onEditingChanged: { editing in
                        isScrubbing = editing
                        if !editing {
                            Task {
                                await session.seek(to: scrubProgress)
                            }
                        }
                    }
                )
                .tint(FastReaderPalette.progress)
                .accessibilityLabel("reader.progress")
                .accessibilityIdentifier("reader.progress")
            }

            playbackControls(session)
            speedAndModeControls
        }
        .padding(.horizontal, FastReaderSpacing.standard)
        .padding(.top, FastReaderSpacing.standard)
        .padding(.bottom, FastReaderSpacing.small)
        .background(.regularMaterial)
    }

    private var speedAndModeControls: some View {
        HStack {
            wpmButton(
                systemImage: "minus",
                accessibilityLabel: "speed.wpm.decrease",
                accessibilityIdentifier: "speed.wpm.decrease",
                disabled: wordsPerMinute <= 100
            ) {
                wordsPerMinute = max(wordsPerMinute - 25, 100)
            }
            Spacer()
            wpmButton(
                systemImage: "plus",
                accessibilityLabel: "speed.wpm.increase",
                accessibilityIdentifier: "speed.wpm.increase",
                disabled: wordsPerMinute >= 1000
            ) {
                wordsPerMinute = min(wordsPerMinute + 25, 1000)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 52)
        .overlay {
            modeControl
                .overlay(alignment: .bottom) {
                    Text("\(wordsPerMinute) WPM")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .dynamicTypeSize(.large)
                        .offset(y: FastReaderSpacing.standard)
                        .accessibilityIdentifier("speed.wpm")
                }
        }
    }

    private var modeControl: some View {
        ReaderModeControl(selection: .speed) { selectedMode in
            if selectedMode == .regular {
                returnToRegular()
            }
        }
    }

    private func wpmButton(
        systemImage: String,
        accessibilityLabel: LocalizedStringKey,
        accessibilityIdentifier: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .frame(width: 60, height: 60)
                .background(.thinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private func playbackControls(_ session: SpeedReaderSession) -> some View {
        HStack(spacing: FastReaderSpacing.large) {
            Button {
                Task {
                    await session.movePrevious()
                }
            } label: {
                Image(systemName: "backward.end.fill")
                    .font(.title3)
                    .frame(width: 60, height: 60)
                    .background(.thinMaterial, in: Circle())
            }
            .accessibilityLabel("speed.previous")
            .accessibilityIdentifier("speed.previous")

            Button {
                session.togglePlayback()
            } label: {
                Image(systemName: session.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .frame(width: 68, height: 68)
                    .background(FastReaderPalette.focus, in: Circle())
                    .foregroundStyle(FastReaderPalette.onFocus)
            }
            .accessibilityLabel(session.isPlaying ? "speed.pause" : "speed.play")
            .accessibilityIdentifier("speed.playPause")

            Button {
                Task {
                    await session.moveNext()
                }
            } label: {
                Image(systemName: "forward.end.fill")
                    .font(.title3)
                    .frame(width: 60, height: 60)
                    .background(.thinMaterial, in: Circle())
            }
            .accessibilityLabel("speed.next")
            .accessibilityIdentifier("speed.next")
        }
    }

    private var settings: SpeedReaderSettings {
        SpeedReaderSettings(
            wordsPerMinute: wordsPerMinute,
            adaptivePauses: adaptivePauses
        )
    }

    private func updateSessionSettings() {
        guard case let .ready(session) = viewModel.state else {
            return
        }
        session.updateSettings(settings)
    }

    private func returnToRegular() {
        let highlightLocatorJSON: String? = if case let .ready(session) = viewModel.state {
            session.currentToken?.locatorJSON
        } else {
            nil
        }
        viewModel.stopAndFlush()
        Task {
            await onSelectRegular(highlightLocatorJSON)
        }
    }

    private var saveFailurePresented: Binding<Bool> {
        Binding(
            get: { viewModel.saveFailureMessage != nil },
            set: { presented in
                if !presented {
                    viewModel.dismissSaveFailure()
                }
            }
        )
    }

    private func sessionFailurePresented(_ session: SpeedReaderSession) -> Binding<Bool> {
        Binding(
            get: { session.failureMessage != nil },
            set: { presented in
                if !presented {
                    session.dismissFailure()
                }
            }
        )
    }
}
