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
    @ObservationIgnored private let navigator: EPUBNavigatorViewController
    @ObservationIgnored private let outlineLinks: [UUID: Link]
    @ObservationIgnored private var latestSnapshot: ReaderPositionSnapshot?
    @ObservationIgnored private var reachedPublicationEnd = false

    init(
        publication: Publication,
        initialLocatorJSON: String?,
        highlightLocatorJSON: String?,
        preferences: RegularReaderPreferences
    ) throws {
        self.publication = publication
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
        transitionHighlightText = highlightLocator?.text.highlight

        navigator = try EPUBNavigatorViewController(
            publication: publication,
            initialLocation: initialLocator,
            config: EPUBNavigatorViewController.Configuration(
                preferences: Self.readiumPreferences(preferences),
                contentInset: [
                    .compact: (top: 82, bottom: 112),
                    .regular: (top: 96, bottom: 120)
                ]
            )
        )

        let flattenedOutline = Self.flatten(publication.manifest.tableOfContents)
        outline = flattenedOutline.items
        outlineLinks = flattenedOutline.links
        progress = initialLocator?.locations.totalProgression ?? 0
        sectionTitle = initialLocator?.title
        navigator.delegate = self

        if let highlightLocator {
            let canHighlight = highlightLocator.text.highlight?.isEmpty == false
                && navigator.supports(decorationStyle: .highlight)
            if canHighlight {
                navigator.apply(
                    decorations: [
                        Decoration(
                            id: "active-speed-word",
                            locator: highlightLocator,
                            style: .highlight(tint: FastReaderPalette.focusUIColor, isActive: true)
                        )
                    ],
                    in: Self.speedTransitionDecorationGroup
                )
            }
        }

        if let initialLocator {
            latestSnapshot = Self.snapshot(from: initialLocator)
        }
    }

    var viewController: UIViewController {
        navigator
    }

    func apply(_ preferences: RegularReaderPreferences) {
        navigator.submitPreferences(Self.readiumPreferences(preferences))
    }

    func navigate(to itemID: UUID) async {
        guard let link = outlineLinks[itemID] else {
            return
        }
        _ = await navigator.go(to: link, options: NavigatorGoOptions(animated: false))
    }

    func currentPosition() -> ReaderPositionSnapshot? {
        if let locator = navigator.currentLocation {
            return Self.snapshot(from: locator, reachedPublicationEnd: reachedPublicationEnd)
        }
        return latestSnapshot
    }

    func dismissFailure() {
        failureMessage = nil
    }

    private func receive(_ locator: Locator) {
        guard let snapshot = Self.snapshot(
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

    private static func snapshot(
        from locator: Locator,
        reachedPublicationEnd: Bool = false
    ) -> ReaderPositionSnapshot? {
        guard let locatorJSON = locator.jsonString else {
            return nil
        }
        let progression = reachedPublicationEnd
            ? 1
            : min(max(locator.locations.totalProgression ?? 0, 0), 1)
        return ReaderPositionSnapshot(
            locatorJSON: locatorJSON,
            totalProgression: progression,
            reachedPublicationEnd: reachedPublicationEnd,
            sectionTitle: locator.title
        )
    }

    private static func readiumPreferences(_ preferences: RegularReaderPreferences) -> EPUBPreferences {
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
                items.append(
                    ReaderOutlineItem(
                        id: id,
                        title: displayTitle,
                        depth: depth
                    )
                )
                linksByID[id] = link
                append(link.children, depth: depth + 1)
            }
        }

        append(links, depth: 0)
        return (items, linksByID)
    }
}

extension RegularReaderSession: EPUBNavigatorDelegate {
    func navigator(_: Navigator, locationDidChange locator: Locator) {
        receive(locator)
    }

    func navigator(_: Navigator, presentError _: NavigatorError) {
        failureMessage = String(localized: "reader.error.navigation")
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
