import SwiftUI

struct ReaderAppearanceView: View {
    @Environment(\.dismiss) private var dismiss

    @Binding var theme: ReaderTheme
    @Binding var font: ReaderFont
    @Binding var fontScale: Double
    @Binding var pageMargins: Double
    @Binding var scroll: Bool
    let isFixedLayout: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("reader.appearance.theme") {
                    Picker("reader.appearance.theme", selection: $theme) {
                        ForEach(ReaderTheme.allCases) { theme in
                            Text(theme.localizationKey).tag(theme)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                Section("reader.appearance.layout") {
                    Toggle("reader.appearance.scroll", isOn: $scroll)
                        .accessibilityIdentifier("reader.appearance.scroll")
                    if !isFixedLayout {
                        LabeledContent("reader.appearance.margin") {
                            Stepper(value: $pageMargins, in: 0 ... 4, step: 0.3) {
                                Text(pageMargins, format: .number.precision(.fractionLength(1)))
                                    .monospacedDigit()
                            }
                        }
                    }
                }
                if !isFixedLayout {
                    Section("reader.appearance.typography") {
                        Picker("reader.appearance.font", selection: $font) {
                            ForEach(ReaderFont.allCases) { font in
                                Text(font.localizationKey).tag(font)
                            }
                        }
                        LabeledContent("reader.appearance.size") {
                            Stepper(value: $fontScale, in: 0.7 ... 2, step: 0.1) {
                                Text(fontScale, format: .percent.precision(.fractionLength(0)))
                                    .monospacedDigit()
                            }
                        }
                    }
                }
            }
            .navigationTitle("reader.appearance")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.close") {
                        dismiss()
                    }
                    .accessibilityIdentifier("reader.appearance.close")
                }
            }
        }
    }
}

private extension ReaderTheme {
    var localizationKey: LocalizedStringKey {
        switch self {
        case .system:
            "reader.theme.system"
        case .paper:
            "reader.theme.paper"
        case .sepia:
            "reader.theme.sepia"
        case .dark:
            "reader.theme.dark"
        }
    }
}

private extension ReaderFont {
    var localizationKey: LocalizedStringKey {
        switch self {
        case .publisher:
            "reader.font.publisher"
        case .serif:
            "reader.font.serif"
        case .sansSerif:
            "reader.font.sansSerif"
        case .openDyslexic:
            "reader.font.openDyslexic"
        }
    }
}
