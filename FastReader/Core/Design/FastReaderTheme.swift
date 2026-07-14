import SwiftUI
import UIKit

enum FastReaderPalette {
    static let canvas = Color(
        light: UIColor(red: 0.97, green: 0.95, blue: 0.91, alpha: 1),
        dark: UIColor(red: 0.08, green: 0.08, blue: 0.07, alpha: 1)
    )
    static let raised = Color(
        light: UIColor(red: 1, green: 0.99, blue: 0.97, alpha: 1),
        dark: UIColor(red: 0.14, green: 0.13, blue: 0.12, alpha: 1)
    )
    static let primaryText = Color(
        light: UIColor(red: 0.13, green: 0.12, blue: 0.11, alpha: 1),
        dark: UIColor(red: 0.94, green: 0.92, blue: 0.88, alpha: 1)
    )
    static let secondaryText = Color(
        light: UIColor(red: 0.38, green: 0.35, blue: 0.31, alpha: 1),
        dark: UIColor(red: 0.69, green: 0.66, blue: 0.61, alpha: 1)
    )
    static let focusUIColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 1, green: 0.49, blue: 0.32, alpha: 1)
            : UIColor(red: 0.85, green: 0.34, blue: 0.18, alpha: 1)
    }

    static let focus = Color(focusUIColor)
    static let onFocus = Color(
        light: UIColor(red: 0.08, green: 0.08, blue: 0.07, alpha: 1),
        dark: UIColor(red: 0.08, green: 0.08, blue: 0.07, alpha: 1)
    )
    static let progress = Color(
        light: UIColor(red: 0.76, green: 0.48, blue: 0.16, alpha: 1),
        dark: UIColor(red: 0.95, green: 0.65, blue: 0.28, alpha: 1)
    )
}

enum FastReaderSpacing {
    static let xSmall: CGFloat = 4
    static let small: CGFloat = 8
    static let medium: CGFloat = 12
    static let standard: CGFloat = 16
    static let large: CGFloat = 24
    static let xLarge: CGFloat = 32
}

enum FastReaderRadius {
    static let small: CGFloat = 8
    static let card: CGFloat = 16
}

extension View {
    func editorialCanvas() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(FastReaderPalette.primaryText)
            .background(FastReaderPalette.canvas)
    }
}

private extension Color {
    init(light: UIColor, dark: UIColor) {
        self.init(
            UIColor { traits in
                traits.userInterfaceStyle == .dark ? dark : light
            }
        )
    }
}
