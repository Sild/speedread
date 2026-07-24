import Foundation
import Testing

@Suite("Tag selection draft")
struct TagSelectionDraftTests {
    @Test("Search selects canonical matches and creates one multiword tag")
    func searchAndCreation() {
        let fiction = tag("Fiction")
        let work = tag("Work")
        let resume = tag("Résumé")
        var draft = TagSelectionDraft(
            selectedTags: [fiction],
            availableTags: [resume, work, fiction]
        )

        #expect(draft.selectedOptions.map(\.displayName) == ["Fiction"])
        #expect(draft.availableOptions.map(\.displayName) == ["Résumé", "Work"])
        #expect(!draft.hasChanges)

        draft.query = "  WORK "
        #expect(draft.searchResults.map(\.displayName) == ["Work"])
        #expect(draft.creationDisplayName == nil)
        draft.selectOrCreateQuery()
        #expect(draft.query.isEmpty)
        #expect(draft.selectedDisplayNames == ["Fiction", "Work"])

        draft.query = "Re\u{301}sume\u{301}"
        #expect(draft.creationDisplayName == nil)
        draft.selectOrCreateQuery()
        #expect(draft.selectedDisplayNames == ["Fiction", "Résumé", "Work"])

        draft.query = "  Long Form  "
        #expect(draft.creationDisplayName == "Long Form")
        draft.selectOrCreateQuery()
        #expect(draft.selectedDisplayNames == ["Fiction", "Long Form", "Résumé", "Work"])
        #expect(draft.hasChanges)
    }

    @Test("Dirty state ignores unselected draft options")
    func dirtyState() throws {
        let fiction = tag("Fiction")
        var draft = TagSelectionDraft(selectedTags: [fiction], availableTags: [fiction])
        let fictionOption = try #require(draft.selectedOptions.first)

        draft.toggle(fictionOption)
        #expect(draft.selectedDisplayNames.isEmpty)
        #expect(draft.hasChanges)
        draft.toggle(fictionOption)
        #expect(!draft.hasChanges)

        draft.query = "   "
        draft.selectOrCreateQuery()
        #expect(draft.query == "   ")
        #expect(!draft.hasChanges)

        draft.query = "Draft Only"
        draft.selectOrCreateQuery()
        let draftOption = try #require(
            draft.selectedOptions.first(where: { $0.canonicalName == "draft only" })
        )
        draft.toggle(draftOption)
        #expect(draft.selectedDisplayNames == ["Fiction"])
        #expect(!draft.hasChanges)
    }

    private func tag(_ displayName: String) -> Tag {
        Tag(
            id: UUID(),
            canonicalName: TagNormalizer.canonicalize(displayName),
            displayName: displayName
        )
    }
}
