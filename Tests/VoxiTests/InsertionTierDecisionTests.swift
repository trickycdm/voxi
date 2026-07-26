import Testing
@testable import Voxi

@MainActor
@Suite struct InsertionTierDecisionTests {
    private func decide(
        hasElement: Bool, isElectron: Bool = false, canSetSelectedText: Bool = false,
        hasEnabledPasteItem: Bool = true, probeMustNotRun: Bool = false
    ) -> TextInserter.AutoTierDecision {
        TextInserter.autoTierDecision(
            hasElement: hasElement,
            isElectron: isElectron,
            canSetSelectedText: canSetSelectedText,
            hasEnabledPasteItem: {
                #expect(!probeMustNotRun, "menu-bar probe ran on a path that shouldn't need it")
                return hasEnabledPasteItem
            }
        )
    }

    @Test func writableElementTriesDirectFirst() {
        #expect(decide(
            hasElement: true, canSetSelectedText: true, probeMustNotRun: true
        ) == .tryDirectThenPasteboard)
    }

    @Test func electronSkipsDirectAndUsesPasteboard() {
        // Element present → probe not consulted (today's behavior preserved).
        #expect(decide(
            hasElement: true, isElectron: true, canSetSelectedText: true
        ) == .pasteboard)
    }

    @Test func unsettableElementFallsToPasteboard() {
        #expect(decide(hasElement: true, canSetSelectedText: false) == .pasteboard)
    }

    @Test func noElementWithPasteMenuItemUsesPasteboard() {
        #expect(decide(hasElement: false, hasEnabledPasteItem: true) == .pasteboard)
    }

    @Test func noElementWithoutPasteMenuItemFallsToClipboard() {
        #expect(decide(hasElement: false, hasEnabledPasteItem: false) == .clipboardFallback)
    }
}
