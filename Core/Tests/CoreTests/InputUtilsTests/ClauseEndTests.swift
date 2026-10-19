@testable import Core
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import Testing

private let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// The input of `keys` typed in romaji, with the clause end moved `back` characters from the end, as Shift+← does
private func typedInput(_ keys: String, back: Int = 0) -> TypedInput? {
    var text = ComposingText()
    for key in keys {
        text.insertAtCursorPosition([.init(piece: .key(intention: KeyMap.h2zMap(key), input: key, modifiers: []), inputStyle: .mapped(id: .defaultRomanToKana))])
    }
    text.insertAtCursorPosition([.init(piece: .compositionSeparator, inputStyle: .mapped(id: .defaultRomanToKana))])
    _ = text.moveCursorFromCursorPosition(count: -back)
    return TypedInput(text)
}

@Test func testClauseEndIsTheKeyBeforeTheCursor() throws {
    #expect(try #require(typedInput("korehawindowsdesu")).clauseEnd == nil)
    // これはwindowsです with the clause shrunk by two characters (す, then で): the clause ends before d
    #expect(try #require(typedInput("korehawindowsdesu", back: 2)).clauseEnd == 13)
}

@Test func testSpanSplitsAtAKeyInsideIt() {
    let span = LatinInputGuess.Span(word: "Sakehasake", keys: 0 ..< 10)
    #expect(span.split(at: 4) == [.init(word: "Sake", keys: 0 ..< 4), .init(word: "hasake", keys: 4 ..< 10)])
    #expect(span.split(at: 10) == [span])
}

@MainActor
@Test func testRulesSplitLatinWordsAtTheClauseEnd() throws {
    var input = try #require(typedInput("korehawindowsdesu"))
    #expect(RuleBasedScriptIdentifier().segment(input).latinWords.map(\.keys) == [6 ..< 13])
    input.clauseEnd = 10
    #expect(RuleBasedScriptIdentifier().segment(input).latinWords.map(\.keys) == [6 ..< 10, 10 ..< 13])
}

@MainActor
@Test func testLearnedIdentifierKeepsLatinWordsInsideTheClause() throws {
    let identifier = try TaggerScriptIdentifier(
        modelDirectory: repository.appendingPathComponent("Ogura/Resources/ScriptModel", isDirectory: true),
        converter: KanaKanjiConverter.withDefaultDictionary()
    )
    var input = try #require(typedInput("Sakehasakedesu"))
    #expect(identifier.segment(input).latinWords.map(\.word) == ["Sake"])
    for clauseEnd in 1 ..< input.keys.count {
        input.clauseEnd = clauseEnd
        #expect(identifier.segment(input).latinWords.allSatisfy { !($0.keys.lowerBound < clauseEnd && clauseEnd < $0.keys.upperBound) })
    }
}
