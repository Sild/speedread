import SwiftUI
import UIKit

struct RegularReaderView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var viewModel: RegularReaderViewModel
    @State private var presentsOutline = false
    @State private var presentsAppearance = false
    @State private var mode = ReaderMode.regular
    @State private var scrubProgress: Double
    @State private var isScrubbing = false
    @State private var requestedSeekProgress: Double?

    @AppStorage("reader.theme") private var themeRawValue = ReaderTheme.system.rawValue
    @AppStorage("reader.font") private var fontRawValue = ReaderFont.publisher.rawValue
    @AppStorage("reader.fontScale") private var fontScale = 1.0
    @AppStorage("reader.pageMargins") private var pageMargins = 1.0
    @AppStorage("reader.scroll") private var epubScroll = false
    @AppStorage("reader.pdf.scroll") private var pdfScroll = true

    private let book: Book
    private let fileStore: any BookFileStore
    private let publicationService: any PublicationService
    private let progressStore: any ReadingProgressStore

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
        _scrubProgress = State(initialValue: book.progress)
        _viewModel = State(
            initialValue: RegularReaderViewModel(
                book: book,
                fileStore: fileStore,
                publicationService: publicationService,
                progressStore: progressStore
            )
        )
    }

    var body: some View {
        readerSurface
            .background(readerBackground.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .task {
                await viewModel.load(preferences: preferences)
                scrubProgress = viewModel.progress
            }
            .task(id: requestedSeekProgress) {
                await performRequestedSeek()
            }
            .onChange(of: colorScheme) {
                viewModel.apply(preferences)
            }
            .onChange(of: themeRawValue) {
                viewModel.apply(preferences)
            }
            .onChange(of: fontRawValue) {
                viewModel.apply(preferences)
            }
            .onChange(of: fontScale) {
                viewModel.apply(preferences)
            }
            .onChange(of: pageMargins) {
                viewModel.apply(preferences)
            }
            .onChange(of: epubScroll) {
                if !isPDF {
                    viewModel.apply(preferences)
                }
            }
            .onChange(of: pdfScroll) {
                if isPDF {
                    viewModel.apply(preferences)
                }
            }
            .onChange(of: viewModel.progress) {
                guard !isScrubbing else {
                    return
                }
                scrubProgress = viewModel.progress
            }
            .onChange(of: scenePhase) {
                if scenePhase != .active {
                    viewModel.flushPosition()
                }
            }
            .onDisappear {
                viewModel.flushPosition()
            }
            .sheet(isPresented: $presentsOutline) {
                if case let .ready(session) = viewModel.state {
                    ReaderOutlineView(items: session.outline) { itemID in
                        Task {
                            await session.navigate(to: itemID)
                            presentsOutline = false
                        }
                    }
                }
            }
            .sheet(isPresented: $presentsAppearance) {
                ReaderAppearanceView(
                    theme: themeBinding,
                    font: fontBinding,
                    fontScale: $fontScale,
                    pageMargins: $pageMargins,
                    scroll: activeScrollBinding,
                    isFixedLayout: book.layout == .fixed
                )
                .presentationDetents([.medium, .large])
            }
            .alert("reader.error.save.title", isPresented: saveFailurePresented) {
                Button("action.ok") {
                    viewModel.dismissSaveFailure()
                }
            } message: {
                Text(viewModel.saveFailureMessage ?? "")
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: viewModel.showsChrome)
    }

    @ViewBuilder
    private var readerSurface: some View {
        switch mode {
        case .regular:
            regularReaderSurface
        case .speed:
            SpeedReaderView(
                book: book,
                fileStore: fileStore,
                publicationService: publicationService,
                progressStore: progressStore,
                onSelectRegular: { highlightLocatorJSON in
                    await viewModel.reload(
                        preferences: preferences,
                        highlightLocatorJSON: highlightLocatorJSON
                    )
                    mode = .regular
                },
                onExitBook: exitBook
            )
        }
    }

    private var regularReaderSurface: some View {
        ZStack {
            readerContent
            if viewModel.showsChrome {
                readerChrome
                    .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private var readerContent: some View {
        switch viewModel.state {
        case .loading:
            ProgressView("reader.loading")
        case let .ready(session):
            ReaderNavigatorContainer(viewController: session.viewController)
                .ignoresSafeArea()
                .accessibilityIdentifier("reader.navigator")
                .accessibilityValue(session.transitionHighlightText ?? "")
                .alert("reader.error.navigation.title", isPresented: sessionFailurePresented(session)) {
                    Button("action.ok") {
                        session.dismissFailure()
                    }
                } message: {
                    Text(session.failureMessage ?? "")
                }
        case let .failure(message):
            ContentUnavailableView {
                Label("reader.error.title", systemImage: "book.closed")
            } description: {
                Text(message)
            } actions: {
                Button("action.retry") {
                    Task {
                        await viewModel.retry(preferences: preferences)
                    }
                }
                Button("reader.back") {
                    dismiss()
                }
            }
        }
    }

    private var readerChrome: some View {
        VStack(spacing: 0) {
            HStack(spacing: FastReaderSpacing.standard) {
                Button {
                    exitBook()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .accessibilityLabel("reader.back")
                .accessibilityIdentifier("reader.back")

                VStack(alignment: .leading, spacing: 2) {
                    Text(book.title)
                        .font(.headline)
                        .lineLimit(1)
                    if let sectionTitle = displayedSectionTitle {
                        Text(sectionTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Button {
                    presentsOutline = true
                } label: {
                    Image(systemName: "list.bullet")
                }
                .accessibilityLabel("reader.toc")
                .accessibilityIdentifier("reader.toc")
                Button {
                    presentsAppearance = true
                } label: {
                    Image(systemName: "textformat.size")
                }
                .accessibilityLabel("reader.appearance")
                .accessibilityIdentifier("reader.appearance")
            }
            .padding(.horizontal, FastReaderSpacing.standard)
            .padding(.vertical, FastReaderSpacing.small)
            .background(.regularMaterial)

            Spacer()

            VStack(spacing: FastReaderSpacing.small) {
                Slider(
                    value: $scrubProgress,
                    in: 0 ... 1,
                    onEditingChanged: { editing in
                        isScrubbing = editing
                        viewModel.setChromeAutoHidePaused(editing)
                        if !editing {
                            requestedSeekProgress = scrubProgress
                        }
                    }
                )
                .tint(FastReaderPalette.progress)
                .disabled(!readerIsReady || requestedSeekProgress != nil)
                .accessibilityLabel("reader.progress")
                .accessibilityValue(displayedProgress.formatted(.percent))
                .accessibilityHint("reader.progress.seek.hint")
                .accessibilityIdentifier("reader.progress")
                HStack {
                    Text(displayedProgress, format: .percent.precision(.fractionLength(0)))
                        .font(.caption.monospacedDigit())
                        .accessibilityIdentifier("reader.progress.percentage")
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .overlay {
                    ReaderModeControl(selection: .regular) { selectedMode in
                        if selectedMode == .speed {
                            viewModel.flushPosition()
                            mode = .speed
                        }
                    }
                }
            }
            .padding(.horizontal, FastReaderSpacing.standard)
            .padding(.vertical, FastReaderSpacing.small)
            .background(.regularMaterial)
        }
    }
}

extension RegularReaderView {
    private var preferences: RegularReaderPreferences {
        RegularReaderPreferences(
            theme: ReaderTheme(rawValue: themeRawValue) ?? .system,
            font: ReaderFont(rawValue: fontRawValue) ?? .publisher,
            fontScale: fontScale,
            pageMargins: pageMargins,
            scroll: isPDF ? pdfScroll : epubScroll,
            prefersDarkSystemTheme: colorScheme == .dark
        )
    }

    private func exitBook() {
        viewModel.flushPosition()
        dismiss()
    }

    private func performRequestedSeek() async {
        guard let progression = requestedSeekProgress else {
            return
        }
        defer {
            requestedSeekProgress = nil
        }
        guard case let .ready(session) = viewModel.state else {
            scrubProgress = viewModel.progress
            return
        }
        guard await session.seek(toTotalProgression: progression) else {
            scrubProgress = viewModel.progress
            return
        }
        scrubProgress = session.progress
    }

    private var displayedProgress: Double {
        isScrubbing ? scrubProgress : viewModel.progress
    }

    private var readerIsReady: Bool {
        if case .ready = viewModel.state {
            return true
        }
        return false
    }

    private var isPDF: Bool {
        book.mediaType == PublicationFormat.pdf.defaultMediaType
    }

    private var activeScrollBinding: Binding<Bool> {
        Binding(
            get: { isPDF ? pdfScroll : epubScroll },
            set: { newValue in
                if isPDF {
                    pdfScroll = newValue
                } else {
                    epubScroll = newValue
                }
            }
        )
    }

    private var displayedSectionTitle: String? {
        guard case let .ready(session) = viewModel.state,
              let sectionTitle = session.sectionTitle,
              !sectionTitle.isEmpty
        else {
            return nil
        }
        return sectionTitle
    }

    private var readerBackground: Color {
        switch ReaderTheme(rawValue: themeRawValue) ?? .system {
        case .system:
            colorScheme == .dark ? .black : FastReaderPalette.canvas
        case .paper:
            FastReaderPalette.canvas
        case .dark:
            .black
        case .sepia:
            Color(red: 0.98, green: 0.96, blue: 0.91)
        }
    }

    private var themeBinding: Binding<ReaderTheme> {
        Binding(
            get: { ReaderTheme(rawValue: themeRawValue) ?? .system },
            set: { themeRawValue = $0.rawValue }
        )
    }

    private var fontBinding: Binding<ReaderFont> {
        Binding(
            get: { ReaderFont(rawValue: fontRawValue) ?? .publisher },
            set: { fontRawValue = $0.rawValue }
        )
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

    private func sessionFailurePresented(_ session: RegularReaderSession) -> Binding<Bool> {
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

enum ReaderMode: Equatable {
    case regular
    case speed
}

struct ReaderModeControl: View {
    let selection: ReaderMode
    let onSelect: (ReaderMode) -> Void

    var body: some View {
        HStack(spacing: 0) {
            segment(title: String(localized: "reader.mode.regular"), mode: .regular)
            segment(title: String(localized: "reader.mode.speed"), mode: .speed)
        }
        .background(.thinMaterial, in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reader.mode.selector")
    }

    private func segment(title: String, mode: ReaderMode) -> some View {
        Button(title) {
            onSelect(mode)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, FastReaderSpacing.medium)
        .padding(.vertical, FastReaderSpacing.small)
        .background(selection == mode ? FastReaderPalette.focus : .clear, in: Capsule())
        .foregroundStyle(selection == mode ? FastReaderPalette.onFocus : FastReaderPalette.primaryText)
        .accessibilityAddTraits(selection == mode ? .isSelected : [])
        .accessibilityIdentifier(mode == .regular ? "reader.mode.regular" : "reader.mode.speed")
    }
}

private struct ReaderNavigatorContainer: UIViewControllerRepresentable {
    let viewController: UIViewController

    func makeUIViewController(context _: Context) -> UIViewController {
        viewController
    }

    func updateUIViewController(_: UIViewController, context _: Context) {}
}

private struct ReaderOutlineView: View {
    let items: [ReaderOutlineItem]
    let onSelect: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    ContentUnavailableView("reader.toc.empty", systemImage: "list.bullet")
                } else {
                    List(items) { item in
                        Button {
                            onSelect(item.id)
                        } label: {
                            Text(item.title)
                                .padding(.leading, CGFloat(item.depth) * FastReaderSpacing.medium)
                        }
                    }
                }
            }
            .navigationTitle("reader.toc")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.close") {
                        dismiss()
                    }
                    .accessibilityIdentifier("reader.toc.close")
                }
            }
        }
    }
}
