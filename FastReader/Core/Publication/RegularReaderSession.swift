import Foundation
import Observation
@preconcurrency import ReadiumNavigator
@preconcurrency import ReadiumShared
import UIKit

@MainActor
@Observable
final class RegularReaderSession {
    private static let speedTransitionDecorationGroup = "speed-transition"

    private(set) var progress: Double
    private(set) var sectionTitle: String?
    private(set) var failureMessage: String?
    let transitionHighlightText: String?

    let outline: [ReaderOutlineItem]

    @ObservationIgnored var onPositionChange: ((ReaderPositionSnapshot) -> Void)?
    @ObservationIgnored var onToggleChrome: (() -> Void)?

    @ObservationIgnored private let publication: Publication
    @ObservationIgnored private let format: PublicationFormat
    @ObservationIgnored private let navigator: ReaderNavigator
    @ObservationIgnored private let outlineLinks: [UUID: Link]
    @ObservationIgnored private var latestSnapshot: ReaderPositionSnapshot?
    @ObservationIgnored private var epubInitialPositionContinuity: EPUBInitialPositionContinuity?
    @ObservationIgnored private var reachedPublicationEnd = false
    @ObservationIgnored private var pdfScrollObservation: NSKeyValueObservation?
    @ObservationIgnored private weak var pdfScrollView: UIScrollView?

    init(
        publication: Publication,
        format: PublicationFormat,
        initialLocatorJSON: String?,
        highlightLocatorJSON: String?,
        preferences: RegularReaderPreferences,
        httpServer: HTTPServer
    ) throws {
        self.publication = publication
        self.format = format
        let initialLocator: Locator? = if let initialLocatorJSON {
            try Locator(jsonString: initialLocatorJSON)
        } else {
            nil
        }
        let highlightLocator: Locator? = if let highlightLocatorJSON {
            try? Locator(jsonString: highlightLocatorJSON)
        } else {
            nil
        }
        if format == .epub {
            epubInitialPositionContinuity = EPUBInitialPositionContinuity(
                exactLocator: initialLocator
            )
        }
        transitionHighlightText = highlightLocator?.text.highlight

        navigator = try Self.makeNavigator(
            publication: publication,
            format: format,
            initialLocator: initialLocator,
            preferences: preferences,
            httpServer: httpServer
        )

        let flattenedOutline = Self.flatten(publication.manifest.tableOfContents)
        outline = flattenedOutline.items
        outlineLinks = flattenedOutline.links
        progress = initialLocator?.locations.totalProgression ?? 0
        sectionTitle = initialLocator?.title

        switch navigator {
        case let .epub(navigator):
            navigator.delegate = self
        case let .pdf(navigator):
            navigator.delegate = self
        }

        Self.applyTransitionHighlight(highlightLocator, to: navigator)

        if let initialLocator {
            latestSnapshot = Self.snapshot(
                from: initialLocator,
                preservesSpeedCursor: epubInitialPositionContinuity != nil
            )
        }
    }

    deinit {
        pdfScrollObservation?.invalidate()
    }

    var viewController: UIViewController {
        switch navigator {
        case let .epub(navigator):
            navigator
        case let .pdf(navigator):
            navigator
        }
    }

    func apply(_ preferences: RegularReaderPreferences) {
        switch navigator {
        case let .epub(navigator):
            navigator.submitPreferences(Self.epubPreferences(preferences))
        case let .pdf(navigator):
            navigator.submitPreferences(Self.pdfPreferences(preferences))
            updatePDFCompletion(navigator)
        }
    }

    func navigate(to itemID: UUID) async {
        guard let link = outlineLinks[itemID] else {
            return
        }
        switch navigator {
        case let .epub(navigator):
            _ = await navigator.go(to: link, options: NavigatorGoOptions(animated: false))
        case let .pdf(navigator):
            _ = await navigator.go(to: link, options: NavigatorGoOptions(animated: false))
        }
    }

    func currentPosition() -> ReaderPositionSnapshot? {
        let locator: Locator? = switch navigator {
        case let .epub(navigator):
            navigator.currentLocation
        case let .pdf(navigator):
            navigator.currentLocation
        }
        if let locator {
            return snapshot(from: locator, reachedPublicationEnd: reachedPublicationEnd)
        }
        return latestSnapshot
    }

    func dismissFailure() {
        failureMessage = nil
    }

    private func receive(_ locator: Locator) {
        guard let snapshot = snapshot(
            from: locator,
            reachedPublicationEnd: reachedPublicationEnd
        ) else {
            failureMessage = String(localized: "reader.error.position")
            return
        }
        latestSnapshot = snapshot
        progress = snapshot.totalProgression
        sectionTitle = snapshot.sectionTitle
        onPositionChange?(snapshot)
    }

    private func updatePDFCompletion(_ navigator: PDFNavigatorViewController) {
        guard format == .pdf, let locator = navigator.currentLocation else {
            return
        }
        let pageCount = publication.metadata.numberOfPages ?? 0
        let nowAtEnd = ReaderEndDetection.hasReachedPDFEnd(
            currentPage: locator.locations.position,
            pageCount: pageCount,
            isScrolling: navigator.settings.scroll,
            visibleBottom: pdfVisibleBottom,
            contentHeight: pdfScrollView.map { Double($0.contentSize.height) }
        )
        if nowAtEnd != reachedPublicationEnd {
            reachedPublicationEnd = nowAtEnd
        }
        receive(locator)
    }

    private func updateCurrentPDFCompletion() {
        guard case let .pdf(navigator) = navigator else {
            return
        }
        updatePDFCompletion(navigator)
    }

    private var pdfVisibleBottom: Double? {
        guard let scrollView = pdfScrollView else {
            return nil
        }
        let visibleBottom = scrollView.contentOffset.y
            + scrollView.bounds.height
            - scrollView.adjustedContentInset.bottom
        return Double(visibleBottom)
    }

    private static func epubPreferences(_ preferences: RegularReaderPreferences) -> EPUBPreferences {
        let theme: Theme = switch preferences.theme {
        case .system:
            preferences.prefersDarkSystemTheme ? .dark : .light
        case .paper:
            .light
        case .dark:
            .dark
        case .sepia:
            .sepia
        }
        let fontFamily: FontFamily? = switch preferences.font {
        case .publisher:
            nil
        case .serif:
            .serif
        case .sansSerif:
            .sansSerif
        case .openDyslexic:
            .openDyslexic
        }
        return EPUBPreferences(
            fontFamily: fontFamily,
            fontSize: min(max(preferences.fontScale, 0.7), 2),
            pageMargins: min(max(preferences.pageMargins, 0), 4),
            publisherStyles: false,
            scroll: preferences.scroll,
            theme: theme
        )
    }

    private static func makeNavigator(
        publication: Publication,
        format: PublicationFormat,
        initialLocator: Locator?,
        preferences: RegularReaderPreferences,
        httpServer: HTTPServer
    ) throws -> ReaderNavigator {
        switch format {
        case .epub:
            try .epub(
                EPUBNavigatorViewController(
                    publication: publication,
                    initialLocation: initialLocator,
                    config: EPUBNavigatorViewController.Configuration(
                        preferences: epubPreferences(preferences),
                        contentInset: [
                            .compact: (top: 82, bottom: 112),
                            .regular: (top: 96, bottom: 120)
                        ]
                    )
                )
            )
        case .pdf:
            try .pdf(
                PDFNavigatorViewController(
                    publication: publication,
                    initialLocation: initialLocator,
                    config: PDFNavigatorViewController.Configuration(
                        preferences: pdfPreferences(preferences)
                    ),
                    httpServer: httpServer
                )
            )
        }
    }

    private static func applyTransitionHighlight(
        _ locator: Locator?,
        to readerNavigator: ReaderNavigator
    ) {
        guard let locator,
              locator.text.highlight?.isEmpty == false,
              case let .epub(navigator) = readerNavigator,
              navigator.supports(decorationStyle: .highlight)
        else {
            return
        }
        navigator.apply(
            decorations: [
                Decoration(
                    id: "active-speed-word",
                    locator: locator,
                    style: .highlight(tint: FastReaderPalette.focusUIColor, isActive: true)
                )
            ],
            in: speedTransitionDecorationGroup
        )
    }

    static func pdfPreferences(_ preferences: RegularReaderPreferences) -> PDFPreferences {
        let backgroundColor: UIColor = switch preferences.theme {
        case .system:
            preferences.prefersDarkSystemTheme ? .black : .systemBackground
        case .paper:
            .white
        case .dark:
            .black
        case .sepia:
            UIColor(red: 0.98, green: 0.96, blue: 0.91, alpha: 1)
        }
        return PDFPreferences(
            backgroundColor: ReadiumNavigator.Color(uiColor: backgroundColor),
            fit: .page,
            scroll: preferences.scroll,
            scrollAxis: .vertical
        )
    }

    private static func flatten(_ links: [Link]) -> (items: [ReaderOutlineItem], links: [UUID: Link]) {
        var items: [ReaderOutlineItem] = []
        var linksByID: [UUID: Link] = [:]

        func append(_ links: [Link], depth: Int) {
            for link in links {
                let id = UUID()
                let title = link.title?.trimmingCharacters(in: .whitespacesAndNewlines)
                let displayTitle = if let title, !title.isEmpty {
                    title
                } else {
                    String(localized: "reader.toc.untitled")
                }
                items.append(ReaderOutlineItem(id: id, title: displayTitle, depth: depth))
                linksByID[id] = link
                append(link.children, depth: depth + 1)
            }
        }

        append(links, depth: 0)
        return (items, linksByID)
    }
}

extension RegularReaderSession {
    func seek(toTotalProgression requestedProgression: Double) async -> Bool {
        let progression = min(max(requestedProgression, 0), 1)
        guard let locator = await seekLocator(for: progression) else {
            failureMessage = String(localized: "reader.error.navigation")
            return false
        }

        let previousReachedPublicationEnd = reachedPublicationEnd
        reachedPublicationEnd = progression == 1
        let succeeded = switch navigator {
        case let .epub(navigator):
            await navigator.go(to: locator, options: NavigatorGoOptions(animated: false))
        case let .pdf(navigator):
            await navigator.go(to: locator, options: NavigatorGoOptions(animated: false))
        }
        guard succeeded else {
            reachedPublicationEnd = previousReachedPublicationEnd
            failureMessage = String(localized: "reader.error.navigation")
            return false
        }

        if progression == 1, case let .pdf(navigator) = navigator, navigator.settings.scroll {
            scrollPDFToEnd()
        }
        receive(locator)
        return true
    }

    static func seekLocator(for requestedProgression: Double, in positions: [Locator]) -> Locator? {
        let progression = min(max(requestedProgression, 0), 1)
        guard let closest = positions.min(by: {
            abs(($0.locations.totalProgression ?? 0) - progression)
                < abs(($1.locations.totalProgression ?? 0) - progression)
        }) else {
            return nil
        }
        guard progression == 0 || progression == 1 else {
            return closest
        }
        return closest.copy(locations: {
            $0.progression = progression
            $0.totalProgression = progression
        })
    }

    private func seekLocator(for progression: Double) async -> Locator? {
        switch await publication.positions() {
        case let .success(positions):
            Self.seekLocator(for: progression, in: positions)
        case .failure:
            nil
        }
    }

    private func scrollPDFToEnd() {
        guard let scrollView = pdfScrollView else {
            return
        }
        scrollView.layoutIfNeeded()
        let maximumOffset = max(
            -scrollView.adjustedContentInset.top,
            scrollView.contentSize.height
                - scrollView.bounds.height
                + scrollView.adjustedContentInset.bottom
        )
        scrollView.setContentOffset(
            CGPoint(x: scrollView.contentOffset.x, y: maximumOffset),
            animated: false
        )
    }
}

private enum ReaderNavigator {
    case epub(EPUBNavigatorViewController)
    case pdf(PDFNavigatorViewController)
}

private extension RegularReaderSession {
    func snapshot(
        from locator: Locator,
        reachedPublicationEnd: Bool
    ) -> ReaderPositionSnapshot? {
        let preservesSpeedCursor = epubInitialPositionContinuity?
            .preservesSpeedCursor(at: locator) ?? false
        return Self.snapshot(
            from: locator,
            reachedPublicationEnd: reachedPublicationEnd,
            preservesSpeedCursor: preservesSpeedCursor
        )
    }

    static func firstScrollView(in view: UIView) -> UIScrollView? {
        if let scrollView = view as? UIScrollView {
            return scrollView
        }
        for subview in view.subviews {
            if let scrollView = firstScrollView(in: subview) {
                return scrollView
            }
        }
        return nil
    }
}

extension RegularReaderSession: EPUBNavigatorDelegate {
    func navigator(_: Navigator, locationDidChange locator: Locator) {
        if case let .pdf(pdfNavigator) = navigator {
            updatePDFCompletion(pdfNavigator)
        } else {
            receive(locator)
        }
    }

    func navigator(_: Navigator, presentError _: NavigatorError) {
        failureMessage = String(localized: "reader.error.navigation")
    }

    func navigator(_: Navigator, didJumpTo _: Locator) {
        epubInitialPositionContinuity?.invalidate()
    }

    func navigator(
        _ navigator: EPUBNavigatorViewController,
        viewportDidChange viewport: EPUBNavigatorViewController.Viewport?
    ) {
        guard let viewport,
              let finalResource = publication.readingOrder.last?.url(),
              let finalProgression = viewport.progressions[finalResource]
        else {
            return
        }
        let nowAtEnd = ReaderEndDetection.hasReachedEnd(
            finalResourceIsVisible: viewport.readingOrder.contains(finalResource),
            finalResourceProgressionUpperBound: finalProgression.upperBound
        )
        guard nowAtEnd != reachedPublicationEnd else {
            return
        }
        reachedPublicationEnd = nowAtEnd
        if let locator = navigator.currentLocation {
            receive(locator)
        }
    }

    func navigator(_: VisualNavigator, didTapAt _: CGPoint) {
        onToggleChrome?()
    }
}

extension RegularReaderSession: @preconcurrency PDFNavigatorDelegate {
    func navigator(
        _: PDFNavigatorViewController,
        setupPDFView view: PDFDocumentView
    ) {
        pdfScrollObservation?.invalidate()
        guard let scrollView = Self.firstScrollView(in: view) else {
            return
        }
        pdfScrollView = scrollView
        pdfScrollObservation = scrollView.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else {
                    return
                }
                self.updateCurrentPDFCompletion()
            }
        }
    }
}
