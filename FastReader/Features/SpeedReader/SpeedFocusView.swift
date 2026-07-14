import SwiftUI

struct SpeedFocusView: View {
    private static let focusFraction = 0.42
    private static let railHeight: CGFloat = 92

    let token: SpeedToken?
    let previous: [String]
    let next: [String]

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Rectangle()
                    .fill(FastReaderPalette.focus.opacity(0.28))
                    .frame(width: 2, height: 76)
                    .position(
                        x: proxy.size.width * Self.focusFraction,
                        y: Self.railHeight / 2
                    )

                SpeedReadingRailLayout(
                    focusFraction: Self.focusFraction,
                    contextGap: FastReaderSpacing.medium
                ) {
                    contextText(previous)
                    activeText(token?.prefix ?? "")
                    activeText(token?.focus ?? "", isFocus: true)
                    activeText(token?.suffix ?? "")
                    contextText(next)
                }
            }
            .frame(width: proxy.size.width, height: Self.railHeight)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            .clipped()
        }
        .accessibilityHidden(true)
    }

    private func activeText(_ text: String, isFocus: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 42, weight: isFocus ? .bold : .semibold, design: .rounded))
            .foregroundStyle(isFocus ? FastReaderPalette.focus : FastReaderPalette.primaryText)
            .lineLimit(1)
            .fixedSize()
    }

    private func contextText(_ words: [String]) -> some View {
        Text(words.joined(separator: " "))
            .font(.system(size: 22, weight: .regular, design: .rounded))
            .foregroundStyle(FastReaderPalette.secondaryText.opacity(0.72))
            .lineLimit(1)
            .fixedSize()
    }
}

private struct SpeedReadingRailLayout: Layout {
    let focusFraction: CGFloat
    let contextGap: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache _: inout ()
    ) -> CGSize {
        let dimensions = subviews.map { $0.dimensions(in: .unspecified) }
        return CGSize(
            width: proposal.width ?? dimensions.reduce(0) { $0 + $1.width },
            height: proposal.height ?? (dimensions.map(\.height).max() ?? 0)
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal _: ProposedViewSize,
        subviews: Subviews,
        cache _: inout ()
    ) {
        guard subviews.count == 5 else {
            return
        }

        let dimensions = subviews.map { $0.dimensions(in: .unspecified) }
        let baselines = dimensions.map { $0[VerticalAlignment.firstTextBaseline] }
        let maximumBaseline = baselines.max() ?? 0
        let maximumBelowBaseline = zip(dimensions, baselines)
            .map { pair in pair.0.height - pair.1 }
            .max() ?? 0
        let contentHeight = maximumBaseline + maximumBelowBaseline
        let contentTop = bounds.midY - contentHeight / 2
        let focusX = bounds.minX + bounds.width * focusFraction

        let focusLeft = focusX - dimensions[2].width / 2
        let origins = [
            focusLeft - dimensions[1].width - contextGap - dimensions[0].width,
            focusLeft - dimensions[1].width,
            focusLeft,
            focusLeft + dimensions[2].width,
            focusLeft + dimensions[2].width + dimensions[3].width + contextGap
        ]

        for index in subviews.indices {
            subviews[index].place(
                at: CGPoint(
                    x: origins[index],
                    y: contentTop + maximumBaseline - baselines[index]
                ),
                anchor: .topLeading,
                proposal: .unspecified
            )
        }
    }
}
