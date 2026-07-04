import Foundation
import Testing
@testable import Voxi

@Suite struct ChordSymbolsTests {
    @Test func rendersDefaultBindings() {
        #expect(ChordSymbols.render(.defaultPushToTalk) == "fn")
        #expect(ChordSymbols.render(.defaultToggle) == "fn Space")
        #expect(ChordSymbols.render(.defaultCommand) == "⌃ fn")
    }

    @Test func rendersModifierGlyphsInCanonicalOrder() {
        let all = ChordBinding(control: true, option: true, command: true, shift: true)
        #expect(ChordSymbols.render(all) == "⌃⌥⇧⌘")
        #expect(ChordSymbols.render(ChordBinding(control: true, option: true)) == "⌃⌥")
    }

    @Test func rendersModifiersPlusKey() {
        let binding = ChordBinding(command: true, shift: true, keyCode: 40) // K
        #expect(ChordSymbols.render(binding) == "⇧⌘ K")
    }

    @Test func emptyBindingRendersNone() {
        #expect(ChordSymbols.render(ChordBinding()) == "None")
    }

    @Test func unknownKeyCodeFallsBack() {
        #expect(ChordSymbols.keyName(200) == "Key 200")
        #expect(ChordSymbols.keyName(49) == "Space")
        #expect(ChordSymbols.keyName(126) == "↑")
    }
}

@Suite struct VariantsCSVTests {
    @Test func parseTrimsAndDropsEmpties() {
        #expect(VariantsCSV.parse(" Xcode , GRDB ,, ,swift ") == ["Xcode", "GRDB", "swift"])
    }

    @Test func parseDedupesCaseInsensitivelyKeepingFirstCasing() {
        #expect(VariantsCSV.parse("GRDB, grdb, Grdb, other") == ["GRDB", "other"])
    }

    @Test func emptyInputParsesToEmpty() {
        #expect(VariantsCSV.parse("") == [])
        #expect(VariantsCSV.parse("  ,  , ") == [])
    }

    @Test func joinParseRoundTrip() {
        let variants = ["gee are dee bee", "grdb", "Gr-Db"]
        #expect(VariantsCSV.parse(VariantsCSV.join(variants)) == variants)
    }
}

@Suite struct DictionaryValidationTests {
    @Test func trimsAndRejectsEmpty() {
        #expect(DictionaryValidation.normalizedTerm("  GRDB  ") == "GRDB")
        #expect(DictionaryValidation.normalizedTerm("") == nil)
        #expect(DictionaryValidation.normalizedTerm("   \n") == nil)
    }
}

@Suite struct ModelSizeFormatTests {
    @Test func formatsMBAndGB() {
        #expect(ModelSizeFormat.label(forMB: 626) == "626 MB")
        #expect(ModelSizeFormat.label(forMB: 1536) == "1.5 GB")
        #expect(ModelSizeFormat.label(forMB: 1024) == "1.0 GB")
        #expect(ModelSizeFormat.label(forMB: nil) == "size unknown")
    }
}

@Suite struct HistoryQueryModeTests {
    @Test func emptyOrUnsearchableQueriesShowRecent() {
        #expect(HistoryQuery.mode(for: "") == .recent)
        #expect(HistoryQuery.mode(for: "   ") == .recent)
        #expect(HistoryQuery.mode(for: "\"\"") == .recent) // no letters/digits
    }

    @Test func searchableQueriesSwitchToSearch() {
        #expect(HistoryQuery.mode(for: "hello") == .search(query: "hello"))
        #expect(HistoryQuery.mode(for: " report 42 ") == .search(query: " report 42 "))
    }
}
