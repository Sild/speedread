import SwiftUI

struct RootView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let repository: any BookRepository
    let progressStore: any ReadingProgressStore
    let fileStore: any BookFileStore
    let publicationService: any PublicationService
    let importCoordinator: ImportCoordinator
    let cloudSyncStatus: CloudSyncStatusModel
    let cloudSyncCoordinator: CloudKitSyncCoordinator?

    var body: some View {
        Group {
            if horizontalSizeClass == .compact {
                compactLibrary
            } else {
                regularLibrary
            }
        }
        .tint(FastReaderPalette.focus)
    }

    private var compactLibrary: some View {
        NavigationStack {
            LibraryView(
                repository: repository,
                progressStore: progressStore,
                fileStore: fileStore,
                publicationService: publicationService,
                importCoordinator: importCoordinator,
                cloudSyncStatus: cloudSyncStatus,
                cloudSyncCoordinator: cloudSyncCoordinator
            )
        }
    }

    private var regularLibrary: some View {
        NavigationSplitView {
            LibrarySidebar()
        } detail: {
            NavigationStack {
                LibraryView(
                    repository: repository,
                    progressStore: progressStore,
                    fileStore: fileStore,
                    publicationService: publicationService,
                    importCoordinator: importCoordinator,
                    cloudSyncStatus: cloudSyncStatus,
                    cloudSyncCoordinator: cloudSyncCoordinator
                )
            }
        }
    }
}

private struct LibrarySidebar: View {
    var body: some View {
        ScrollView {
            Label {
                Text("library.sidebar.all")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "books.vertical")
            }
            .font(.headline)
            .foregroundStyle(FastReaderPalette.primaryText)
            .padding(FastReaderSpacing.standard)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                FastReaderPalette.raised,
                in: RoundedRectangle(cornerRadius: FastReaderRadius.small)
            )
            .padding(FastReaderSpacing.standard)
        }
        .editorialCanvas()
        .navigationTitle("app.name")
        .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 420)
    }
}
