import SwiftUI
import UIKit

struct LibraryView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var viewModel: LibraryViewModel
    @State private var importCoordinator: ImportCoordinator
    @State private var cloudSyncStatus: CloudSyncStatusModel
    @State private var presentsImporter = false
    @State private var editingBook: Book?
    @State private var pendingDeletion: Book?
    @State private var pendingShareBook: Book?
    @State private var sharePayload: BookSharePayload?
    @State private var shareFailureMessage: String?

    private let fileStore: any BookFileStore
    private let publicationService: any PublicationService
    private let progressStore: any ReadingProgressStore
    private let cloudSyncCoordinator: CloudKitSyncCoordinator?

    init(
        repository: any BookRepository,
        progressStore: any ReadingProgressStore,
        fileStore: any BookFileStore,
        publicationService: any PublicationService,
        importCoordinator: ImportCoordinator,
        cloudSyncStatus: CloudSyncStatusModel,
        cloudSyncCoordinator: CloudKitSyncCoordinator?
    ) {
        _viewModel = State(initialValue: LibraryViewModel(repository: repository))
        _importCoordinator = State(initialValue: importCoordinator)
        _cloudSyncStatus = State(initialValue: cloudSyncStatus)
        self.fileStore = fileStore
        self.publicationService = publicationService
        self.progressStore = progressStore
        self.cloudSyncCoordinator = cloudSyncCoordinator
    }

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.hasBooks {
                filters
            }
            content
        }
        .editorialCanvas()
        .navigationTitle("library.title")
        .navigationBarTitleDisplayMode(.large)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            LibrarySearchBar(text: searchText)
        }
        .toolbar {
            if let cloudSyncCoordinator {
                ToolbarItem(placement: .topBarLeading) {
                    CloudSyncStatusButton(
                        model: cloudSyncStatus,
                        coordinator: cloudSyncCoordinator
                    )
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    presentsImporter = true
                } label: {
                    Label("library.import", systemImage: "plus")
                }
                .disabled(importCoordinator.isImporting)
                .accessibilityIdentifier("library.import")
            }
        }
        .overlay {
            if importCoordinator.isImporting {
                ProgressView("library.importing")
                    .padding(FastReaderSpacing.large)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: FastReaderRadius.card))
            }
        }
        .fileImporter(
            isPresented: $presentsImporter,
            allowedContentTypes: [.fastReaderEPUB, .pdf],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case let .success(urls):
                Task {
                    await importCoordinator.importFiles(at: urls)
                }
            case let .failure(error):
                importCoordinator.reportPickerFailure(error)
            }
        }
        .sheet(item: $editingBook) { book in
            TagEditorView(book: book, availableTags: viewModel.availableTags) { names in
                try viewModel.setTags(names, bookID: book.id)
            }
            .presentationDetents([.large])
        }
        .sheet(item: $sharePayload) { payload in
            BookShareSheet(payload: payload)
        }
        .alert("library.import.error.title", isPresented: importFailurePresented) {
            Button("action.ok") {
                importCoordinator.dismissFailure()
            }
        } message: {
            Text(importCoordinator.failure?.message ?? "")
        }
        .alert("library.delete.title", isPresented: deletionPresented, presenting: pendingDeletion) { book in
            Button("action.delete", role: .destructive) {
                Task {
                    await importCoordinator.delete(bookID: book.id)
                }
            }
            Button("action.cancel", role: .cancel) {}
        } message: { book in
            Text(
                String.localizedStringWithFormat(
                    String(localized: "library.delete.message"),
                    book.title
                )
            )
        }
        .alert("library.share.error.title", isPresented: shareFailurePresented) {
            Button("action.ok") {
                shareFailureMessage = nil
            }
        } message: {
            Text(shareFailureMessage ?? "")
        }
        .task {
            viewModel.load()
        }
        .task(id: pendingShareBook?.id) {
            await preparePendingShare()
        }
        .onChange(of: importCoordinator.revision) {
            viewModel.load()
        }
        .onChange(of: cloudSyncStatus.libraryRevision) {
            viewModel.load()
        }
    }
}

private struct LibrarySearchBar: View {
    @Binding var text: String
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: FastReaderSpacing.small) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(FastReaderPalette.secondaryText)
                .accessibilityHidden(true)
            TextField("library.search.prompt", text: $text)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .submitLabel(.search)
                .onSubmit {
                    isFocused = false
                }
                .accessibilityIdentifier("library.search")
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(FastReaderPalette.secondaryText)
                .accessibilityLabel("library.search.clear")
                .accessibilityIdentifier("library.search.clear")
            }
        }
        .padding(.horizontal, FastReaderSpacing.medium)
        .padding(.vertical, FastReaderSpacing.medium)
        .background(.regularMaterial, in: Capsule())
        .padding(.horizontal, FastReaderSpacing.standard)
        .padding(.vertical, FastReaderSpacing.small)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
    }
}

private struct BookShareSheet: UIViewControllerRepresentable {
    let payload: BookSharePayload

    func makeUIViewController(context _: Context) -> UIActivityViewController {
        let configuration = UIActivityItemsConfiguration(itemProviders: [payload.itemProvider])
        return UIActivityViewController(activityItemsConfiguration: configuration)
    }

    func updateUIViewController(_: UIActivityViewController, context _: Context) {}
}

private extension LibraryView {
    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            ProgressView()
                .accessibilityLabel("library.loading")
        case let .loaded(books) where books.isEmpty:
            emptyLibrary
        case let .loaded(books):
            bookGrid(books)
        case .failure:
            ContentUnavailableView {
                Label("library.load.error.title", systemImage: "exclamationmark.triangle")
            } description: {
                Text("library.load.error.message")
            } actions: {
                Button("action.retry") {
                    viewModel.load()
                }
            }
        }
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: FastReaderSpacing.medium) {
            filterSection(title: String(localized: "library.status")) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: FastReaderSpacing.small) {
                        FilterPill(
                            title: String(localized: "library.filter.all"),
                            count: viewModel.facetCounts.allStatuses,
                            selected: viewModel.filter.status == nil,
                            accessibilityIdentifier: "library.filter.status.all"
                        ) {
                            viewModel.selectStatus(nil)
                        }
                        ForEach(BookStatus.allCases, id: \.self) { status in
                            FilterPill(
                                title: status.localizedName,
                                count: viewModel.facetCounts.count(for: status),
                                selected: viewModel.filter.status == status,
                                accessibilityIdentifier: "library.filter.status.\(status.rawValue)"
                            ) {
                                viewModel.selectStatus(status)
                            }
                        }
                    }
                }
            }

            filterSection(title: String(localized: "library.tags")) {
                tagFilterContent
            }
        }
        .padding(.horizontal, FastReaderSpacing.medium)
        .padding(.vertical, FastReaderSpacing.medium)
        .background(FastReaderPalette.canvas)
    }

    private func filterSection(
        title: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: FastReaderSpacing.small) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(FastReaderPalette.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var tagFilterContent: some View {
        if viewModel.availableTags.isEmpty {
            Text("library.tags.none.available")
                .font(.subheadline)
                .foregroundStyle(FastReaderPalette.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: FastReaderSpacing.small) {
                    ForEach(viewModel.availableTags) { tag in
                        let selected = viewModel.filter.requiredTagIDs.contains(tag.id)
                        let count = viewModel.facetCounts.count(for: tag)
                        FilterPill(
                            title: "#\(tag.displayName)",
                            count: count,
                            selected: selected,
                            disabled: count == 0 && !selected,
                            accessibilityIdentifier: "library.filter.tag.\(tag.id.uuidString)"
                        ) {
                            viewModel.toggleTag(tag)
                        }
                    }
                }
            }
        }
    }

    private func bookGrid(_ books: [Book]) -> some View {
        ScrollView {
            LazyVGrid(
                columns: [
                    GridItem(
                        .adaptive(minimum: minimumBookCardWidth, maximum: maximumBookCardWidth),
                        spacing: FastReaderSpacing.standard
                    )
                ],
                spacing: FastReaderSpacing.large
            ) {
                ForEach(books) { book in
                    bookLink(book)
                }
            }
            .padding(.horizontal, FastReaderSpacing.medium)
            .padding(.vertical, FastReaderSpacing.standard)
        }
        .accessibilityLabel("library.count")
        .accessibilityValue(Text(books.count, format: .number))
        .accessibilityIdentifier("library.bookGrid")
    }

    private func bookLink(_ book: Book) -> some View {
        NavigationLink {
            RegularReaderView(
                book: book,
                fileStore: fileStore,
                publicationService: publicationService,
                progressStore: progressStore
            )
        } label: {
            BookCard(book: book, fileStore: fileStore)
        }
        .buttonStyle(.plain)
        .contextMenu {
            bookContextMenu(book)
        }
    }

    @ViewBuilder
    private func bookContextMenu(_ book: Book) -> some View {
        Menu("library.status") {
            ForEach(BookStatus.allCases, id: \.self) { status in
                Button {
                    viewModel.setStatus(status, bookID: book.id)
                } label: {
                    if book.status == status {
                        Label(status.localizedName, systemImage: "checkmark")
                    } else {
                        Text(status.localizedName)
                    }
                }
            }
        }
        Button("library.tags.edit") {
            editingBook = book
        }
        Button {
            pendingShareBook = book
        } label: {
            Label("library.share", systemImage: "square.and.arrow.up")
        }
        .accessibilityIdentifier("library.share")
        Divider()
        Button("action.delete", role: .destructive) {
            pendingDeletion = book
        }
    }

    private var emptyLibrary: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: FastReaderSpacing.standard) {
                    Image(systemName: "books.vertical")
                        .font(.system(.largeTitle, design: .rounded, weight: .light))
                        .foregroundStyle(FastReaderPalette.focus)
                        .accessibilityHidden(true)
                    Text("library.empty.title")
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("library.empty.title")
                    Text("library.empty.message")
                        .foregroundStyle(FastReaderPalette.secondaryText)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("library.import") {
                        presentsImporter = true
                    }
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(FastReaderPalette.onFocus)
                }
                .padding(FastReaderSpacing.xLarge)
                .frame(maxWidth: 560, minHeight: proxy.size.height)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var searchText: Binding<String> {
        Binding(
            get: { viewModel.filter.query },
            set: { value in
                viewModel.setQuery(value)
            }
        )
    }

    private func preparePendingShare() async {
        guard let book = pendingShareBook else {
            return
        }
        defer {
            pendingShareBook = nil
        }
        do {
            sharePayload = try await BookSharePayload.prepare(
                book: book,
                fileStore: fileStore
            )
        } catch is CancellationError {
            return
        } catch let error as BookShareError {
            shareFailureMessage = error.userMessage
        } catch {
            shareFailureMessage = BookShareError.inaccessibleFile.userMessage
        }
    }

    private var minimumBookCardWidth: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 160 : 92
    }

    private var maximumBookCardWidth: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 240 : 128
    }

    private var importFailurePresented: Binding<Bool> {
        Binding(
            get: { importCoordinator.failure != nil },
            set: { isPresented in
                if !isPresented {
                    importCoordinator.dismissFailure()
                }
            }
        )
    }

    private var deletionPresented: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    pendingDeletion = nil
                }
            }
        )
    }

    private var shareFailurePresented: Binding<Bool> {
        Binding(
            get: { shareFailureMessage != nil },
            set: { isPresented in
                if !isPresented {
                    shareFailureMessage = nil
                }
            }
        )
    }
}

#Preview {
    let repository = InMemoryBookRepository()
    if let fileStore = try? ApplicationSupportBookFileStore(
        rootURL: FileManager.default.temporaryDirectory.appending(path: "FastReaderPreview")
    ) {
        let coordinator = ImportCoordinator(
            repository: repository,
            fileStore: fileStore,
            publicationService: ReadiumPublicationService()
        )
        RootView(
            repository: repository,
            progressStore: repository,
            fileStore: fileStore,
            publicationService: ReadiumPublicationService(),
            importCoordinator: coordinator,
            cloudSyncStatus: CloudSyncStatusModel(),
            cloudSyncCoordinator: nil
        )
    }
}
