import Foundation

struct TagSelectionDraft: Equatable {
    struct Option: Identifiable, Equatable {
        let canonicalName: String
        let displayName: String

        var id: String {
            canonicalName
        }
    }

    var query = ""

    private(set) var optionsByCanonicalName: [String: Option]
    private(set) var selectedCanonicalNames: Set<String>
    private let initialSelectedCanonicalNames: Set<String>

    init(selectedTags: [Tag], availableTags: [Tag]) {
        var options: [String: Option] = [:]
        for tag in availableTags + selectedTags where options[tag.canonicalName] == nil {
            options[tag.canonicalName] = Option(
                canonicalName: tag.canonicalName,
                displayName: tag.displayName
            )
        }
        let selectedNames = Set(selectedTags.map(\.canonicalName))
        optionsByCanonicalName = options
        selectedCanonicalNames = selectedNames
        initialSelectedCanonicalNames = selectedNames
    }

    var hasQuery: Bool {
        !canonicalQuery.isEmpty
    }

    var hasChanges: Bool {
        selectedCanonicalNames != initialSelectedCanonicalNames
    }

    var selectedOptions: [Option] {
        sortedOptions(optionsByCanonicalName.values.filter(isSelected))
    }

    var availableOptions: [Option] {
        sortedOptions(optionsByCanonicalName.values.filter { !isSelected($0) })
    }

    var searchResults: [Option] {
        guard hasQuery else {
            return []
        }
        return sortedOptions(
            optionsByCanonicalName.values.filter { option in
                option.canonicalName.contains(canonicalQuery)
            }
        )
    }

    var creationDisplayName: String? {
        let displayName = trimmedQuery
        guard !canonicalQuery.isEmpty, optionsByCanonicalName[canonicalQuery] == nil else {
            return nil
        }
        return displayName
    }

    var selectedDisplayNames: [String] {
        selectedOptions.map(\.displayName)
    }

    func isSelected(_ option: Option) -> Bool {
        selectedCanonicalNames.contains(option.canonicalName)
    }

    mutating func toggle(_ option: Option) {
        if isSelected(option) {
            selectedCanonicalNames.remove(option.canonicalName)
        } else {
            selectedCanonicalNames.insert(option.canonicalName)
        }
    }

    mutating func selectOrCreateQuery() {
        guard !canonicalQuery.isEmpty else {
            return
        }
        if optionsByCanonicalName[canonicalQuery] == nil {
            optionsByCanonicalName[canonicalQuery] = Option(
                canonicalName: canonicalQuery,
                displayName: trimmedQuery
            )
        }
        selectedCanonicalNames.insert(canonicalQuery)
        query = ""
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canonicalQuery: String {
        TagNormalizer.canonicalize(trimmedQuery)
    }

    private func sortedOptions(_ options: some Sequence<Option>) -> [Option] {
        options.sorted { left, right in
            let comparison = left.displayName.localizedStandardCompare(right.displayName)
            if comparison == .orderedSame {
                return left.canonicalName < right.canonicalName
            }
            return comparison == .orderedAscending
        }
    }
}
