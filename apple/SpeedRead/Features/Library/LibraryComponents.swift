import SwiftUI
import UniformTypeIdentifiers

struct BookCard: View {
    let book: Book
    let fileStore: any BookFileStore

    @State private var coverImage: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: SpeedReadSpacing.small) {
            cover
            Text(book.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2, reservesSpace: true)
            Text(book.authorsDisplay.isEmpty ? " " : book.authorsDisplay)
                .font(.caption)
                .foregroundStyle(SpeedReadPalette.secondaryText)
                .lineLimit(1, reservesSpace: true)
                .accessibilityHidden(book.authorsDisplay.isEmpty)
            ProgressView(value: book.progress)
                .tint(SpeedReadPalette.progress)
                .padding(.horizontal, SpeedReadSpacing.xSmall)
            status
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(book.title), \(book.authorsDisplay)")
        .task(id: book.coverRelativePath) {
            await loadCover()
        }
    }

    private var cover: some View {
        RoundedRectangle(cornerRadius: SpeedReadRadius.card)
            .fill(SpeedReadPalette.raised)
            .aspectRatio(0.68, contentMode: .fit)
            .overlay {
                GeometryReader { proxy in
                    if let coverImage {
                        Image(uiImage: coverImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .clipped()
                    } else {
                        Image(systemName: "book.closed")
                            .font(.system(size: 40, weight: .light))
                            .foregroundStyle(SpeedReadPalette.secondaryText)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: SpeedReadRadius.card))
    }

    private var status: some View {
        HStack {
            Text(book.status.localizedName)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer()
            Text(book.progress, format: .percent.precision(.fractionLength(0)))
                .monospacedDigit()
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(SpeedReadPalette.secondaryText)
    }

    private func loadCover() async {
        guard let coverPath = book.coverRelativePath,
              let data = try? await fileStore.data(relativePath: coverPath)
        else {
            coverImage = nil
            return
        }
        coverImage = UIImage(data: data)
    }
}

struct FilterPill: View {
    let title: String
    let count: Int
    let selected: Bool
    var disabled = false
    let accessibilityIdentifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: SpeedReadSpacing.xSmall) {
                Text(title)
                Text(count, format: .number)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.thinMaterial, in: Capsule())
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, SpeedReadSpacing.medium)
            .padding(.vertical, SpeedReadSpacing.small)
            .background(selected ? SpeedReadPalette.focus : SpeedReadPalette.raised)
            .foregroundStyle(selected ? SpeedReadPalette.onFocus : SpeedReadPalette.primaryText)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
        .accessibilityValue(Text(count, format: .number))
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

enum BookShareError: Error, Equatable {
    case missingFile
    case inaccessibleFile

    var userMessage: String {
        switch self {
        case .missingFile:
            String(localized: "library.share.error.missingFile")
        case .inaccessibleFile:
            String(localized: "library.share.error.inaccessibleFile")
        }
    }
}

@MainActor
struct BookSharePayload: Identifiable {
    let id: UUID
    let itemProvider: NSItemProvider

    static func prepare(
        book: Book,
        fileStore: any BookFileStore
    ) async throws -> BookSharePayload {
        try Task.checkCancellation()
        guard await fileStore.fileExists(relativePath: book.fileRelativePath) else {
            throw BookShareError.missingFile
        }

        let fileURL: URL
        do {
            fileURL = try await fileStore.fileURL(relativePath: book.fileRelativePath)
        } catch {
            throw BookShareError.inaccessibleFile
        }
        try Task.checkCancellation()

        guard let itemProvider = NSItemProvider(contentsOf: fileURL) else {
            throw BookShareError.inaccessibleFile
        }
        let suggestedFilename = suggestedFilename(
            title: book.title,
            fileExtension: fileURL.pathExtension
        )
        itemProvider.suggestedName = suggestedFilename
        return BookSharePayload(
            id: book.id,
            itemProvider: itemProvider
        )
    }

    static func suggestedFilename(title: String, fileExtension: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/\\:")
            .union(.controlCharacters)
        let normalizedTitle = title
            .components(separatedBy: invalidCharacters)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = String(
            (normalizedTitle.isEmpty
                ? String(localized: "library.share.defaultFilename")
                : normalizedTitle)
                .prefix(120)
        )
        let normalizedExtension = fileExtension.lowercased()
        guard !normalizedExtension.isEmpty,
              !baseName.lowercased().hasSuffix(".\(normalizedExtension)")
        else {
            return baseName
        }
        return "\(baseName).\(normalizedExtension)"
    }
}

struct TagEditorView: View {
    let book: Book
    let onSave: ([String]) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: TagSelectionDraft
    @State private var saveFailurePresented = false

    init(
        book: Book,
        availableTags: [Tag],
        onSave: @escaping ([String]) throws -> Void
    ) {
        self.book = book
        self.onSave = onSave
        _draft = State(
            initialValue: TagSelectionDraft(
                selectedTags: book.tags,
                availableTags: availableTags
            )
        )
    }

    var body: some View {
        NavigationStack {
            List {
                searchSection
                if draft.hasQuery {
                    resultsSection
                } else {
                    selectedSection
                    availableSection
                }
            }
            .navigationTitle("library.tags.edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel") {
                        dismiss()
                    }
                    .accessibilityIdentifier("library.tags.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.save") {
                        save()
                    }
                    .disabled(!draft.hasChanges)
                    .accessibilityIdentifier("library.tags.save")
                }
            }
            .alert("library.tags.save.error.title", isPresented: $saveFailurePresented) {
                Button("action.ok") {}
            } message: {
                Text("library.tags.save.error.message")
            }
        }
    }

    private var searchSection: some View {
        Section {
            HStack(spacing: SpeedReadSpacing.small) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(SpeedReadPalette.secondaryText)
                    .accessibilityHidden(true)
                TextField("library.tags.search.placeholder", text: $draft.query)
                    .submitLabel(.done)
                    .onSubmit {
                        draft.selectOrCreateQuery()
                    }
                    .accessibilityIdentifier("library.tags.search")
                if !draft.query.isEmpty {
                    Button {
                        draft.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(SpeedReadPalette.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("library.tags.search.clear")
                }
            }
        } header: {
            Text("library.tags.find_or_create")
        } footer: {
            Text("library.tags.guidance")
        }
    }

    private var resultsSection: some View {
        Section("library.tags.results") {
            if let displayName = draft.creationDisplayName {
                Button {
                    draft.selectOrCreateQuery()
                } label: {
                    Label(createTitle(displayName), systemImage: "plus.circle.fill")
                }
                .accessibilityIdentifier("library.tags.create")
            }
            ForEach(draft.searchResults) { option in
                tagRow(option, clearsQuery: true)
            }
        }
    }

    private var selectedSection: some View {
        Section("library.tags.selected") {
            if draft.selectedOptions.isEmpty {
                Text("library.tags.none.selected")
                    .foregroundStyle(SpeedReadPalette.secondaryText)
            } else {
                ForEach(draft.selectedOptions) { option in
                    tagRow(option)
                }
            }
        }
    }

    @ViewBuilder
    private var availableSection: some View {
        if !draft.availableOptions.isEmpty {
            Section("library.tags.available") {
                ForEach(draft.availableOptions) { option in
                    tagRow(option)
                }
            }
        } else if draft.selectedOptions.isEmpty {
            Section("library.tags.available") {
                Text("library.tags.none.available.editor")
                    .foregroundStyle(SpeedReadPalette.secondaryText)
            }
        }
    }

    private func tagRow(
        _ option: TagSelectionDraft.Option,
        clearsQuery: Bool = false
    ) -> some View {
        let selected = draft.isSelected(option)
        return Button {
            draft.toggle(option)
            if clearsQuery {
                draft.query = ""
            }
        } label: {
            HStack {
                Image(systemName: "tag")
                    .accessibilityHidden(true)
                Text(option.displayName)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(SpeedReadPalette.focus)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(
            selected
                ? Text("library.tags.selection.selected")
                : Text("library.tags.selection.not_selected")
        )
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("library.tags.option.\(option.canonicalName)")
    }

    private func createTitle(_ displayName: String) -> String {
        String.localizedStringWithFormat(
            String(localized: "library.tags.create"),
            displayName
        )
    }

    private func save() {
        do {
            try onSave(draft.selectedDisplayNames)
            dismiss()
        } catch {
            saveFailurePresented = true
        }
    }
}

extension UTType {
    static var speedReadEPUB: UTType {
        UTType(filenameExtension: "epub") ?? UTType(importedAs: "org.idpf.epub-container")
    }
}
