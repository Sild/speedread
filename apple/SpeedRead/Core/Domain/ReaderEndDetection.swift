enum ReaderEndDetection {
    static func hasReachedEnd(
        finalResourceIsVisible: Bool,
        finalResourceProgressionUpperBound: Double?
    ) -> Bool {
        finalResourceIsVisible && (finalResourceProgressionUpperBound ?? 0) >= 1
    }

    static func hasReachedPDFEnd(
        currentPage: Int?,
        pageCount: Int,
        isScrolling: Bool,
        visibleBottom: Double?,
        contentHeight: Double?
    ) -> Bool {
        guard pageCount > 0, currentPage == pageCount else {
            return false
        }
        guard isScrolling else {
            return true
        }
        guard let visibleBottom, let contentHeight else {
            return false
        }
        return visibleBottom >= contentHeight - 1
    }
}
