import SwiftUI

@main
struct FastReaderApp: App {
    @State private var bootstrap = AppBootstrap()

    var body: some Scene {
        WindowGroup {
            BootstrapView(bootstrap: bootstrap)
                .modifier(UITestEnvironmentModifier(arguments: ProcessInfo.processInfo.arguments))
                .onOpenURL { url in
                    guard case let .ready(dependencies) = bootstrap.state else {
                        return
                    }
                    Task {
                        await dependencies.importCoordinator.importFiles(at: [url])
                    }
                }
        }
    }
}

private struct UITestEnvironmentModifier: ViewModifier {
    let arguments: [String]

    func body(content: Content) -> some View {
        content
            .preferredColorScheme(arguments.contains("-ui-testing-dark") ? .dark : nil)
            .transaction { transaction in
                if arguments.contains("-ui-testing-reduce-motion") {
                    transaction.disablesAnimations = true
                }
            }
            .transformEnvironment(\.dynamicTypeSize) { dynamicTypeSize in
                if arguments.contains("-ui-testing-accessibility-text") {
                    dynamicTypeSize = .accessibility3
                }
            }
    }
}
