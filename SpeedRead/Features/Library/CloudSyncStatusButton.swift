import SwiftUI

struct CloudSyncStatusButton: View {
    @State var model: CloudSyncStatusModel
    let coordinator: CloudKitSyncCoordinator

    @State private var presentsStatus = false
    @State private var actionTask: Task<Void, Never>?

    var body: some View {
        Button {
            presentsStatus.toggle()
        } label: {
            Image(systemName: symbolName)
        }
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier("library.cloudSync")
        .popover(isPresented: $presentsStatus) {
            VStack(alignment: .leading, spacing: SpeedReadSpacing.standard) {
                Label {
                    Text(title)
                        .font(.headline)
                } icon: {
                    Image(systemName: symbolName)
                        .foregroundStyle(SpeedReadPalette.focus)
                }
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(SpeedReadPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                actions
            }
            .padding(SpeedReadSpacing.large)
            .frame(idealWidth: 320)
            .presentationCompactAdaptation(.popover)
        }
        .onDisappear {
            actionTask?.cancel()
            actionTask = nil
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch model.status {
        case .localOnly, .retryableError, .unavailable:
            Button("sync.action.retry") {
                runAction {
                    await coordinator.retry()
                }
            }
            .buttonStyle(.borderedProminent)
        case .accountChange:
            Button("sync.action.useNewAccount") {
                runAction {
                    await coordinator.confirmUseWithNewAccount()
                }
            }
            .buttonStyle(.borderedProminent)
        case .syncing, .upToDate, .downloading:
            EmptyView()
        }
    }

    private var symbolName: String {
        switch model.status {
        case .localOnly:
            "icloud.slash"
        case .syncing:
            "icloud"
        case .upToDate:
            "checkmark.icloud"
        case .downloading:
            "icloud.and.arrow.down"
        case .accountChange, .retryableError, .unavailable:
            "exclamationmark.icloud"
        }
    }

    private var title: LocalizedStringKey {
        switch model.status {
        case .localOnly:
            "sync.status.localOnly.title"
        case .syncing:
            "sync.status.syncing.title"
        case .upToDate:
            "sync.status.upToDate.title"
        case .downloading:
            "sync.status.downloading.title"
        case .accountChange:
            "sync.status.accountChange.title"
        case .retryableError:
            "sync.status.retryable.title"
        case .unavailable:
            "sync.status.unavailable.title"
        }
    }

    private var message: LocalizedStringKey {
        switch model.status {
        case .localOnly:
            "sync.status.localOnly.message"
        case .syncing:
            "sync.status.syncing.message"
        case .upToDate:
            "sync.status.upToDate.message"
        case .downloading:
            "sync.status.downloading.message"
        case .accountChange:
            "sync.status.accountChange.message"
        case .retryableError:
            "sync.status.retryable.message"
        case .unavailable:
            "sync.status.unavailable.message"
        }
    }

    private var accessibilityLabel: Text {
        Text(title)
    }

    private func runAction(_ action: @escaping @Sendable () async -> Void) {
        actionTask?.cancel()
        actionTask = Task {
            await action()
        }
    }
}
