@testable import Core
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import Testing

/// Offering the letters as typed when romaji keystrokes do not look like Japanese (see `LatinInputGuess`)
private let english: Set<String> = ["windows", "hello", "safari", "sake", "made", "test"]
private func knownWord(_ input: String) -> String? {
    english.contains(input) ? input : nil
}

@Test func latinGuessPutsKnownWordWithLeftoverLettersFirst() {
    // うぃんどws: letters left inside the kana
    #expect(LatinInputGuess.guess(input: "windows", kana: "うぃんどws", readingIsWord: false, knownWord: knownWord)
                == .init(text: "windows", rank: 0))
    // へっぉ: a small vowel after っ is not produced by Japanese romaji typing
    #expect(LatinInputGuess.guess(input: "hello", kana: "へっぉ", readingIsWord: false, knownWord: knownWord)
                == .init(text: "hello", rank: 0))
}

@Test func latinGuessKeepsPossibleTypoBelowJapanese() {
    // Not a known word, so this may be a typo of arigatou: offer it, but not first
    #expect(LatinInputGuess.guess(input: "arigatpu", kana: "ありがtぷ", readingIsWord: false, knownWord: knownWord)
                == .init(text: "arigatpu", rank: 1))
}

@Test func latinGuessOffersKnownWordWhoseReadingIsNotAWord() {
    #expect(LatinInputGuess.guess(input: "safari", kana: "さふぁり", readingIsWord: false, knownWord: knownWord)
                == .init(text: "safari", rank: 2))
}

@Test func latinGuessLeavesJapaneseAlone() {
    // Also English words, but the readings are Japanese words
    #expect(LatinInputGuess.guess(input: "sake", kana: "さけ", readingIsWord: true, knownWord: knownWord) == nil)
    #expect(LatinInputGuess.guess(input: "made", kana: "まで", readingIsWord: true, knownWord: knownWord) == nil)
    #expect(LatinInputGuess.guess(input: "kyouhaiitenkidesune", kana: "きょうはいいてんきですね", readingIsWord: false, knownWord: knownWord) == nil)
    // A trailing n becomes ん
    #expect(LatinInputGuess.guess(input: "sumimasen", kana: "すみませn", readingIsWord: false, knownWord: knownWord) == nil)
    // Loanword sounds such as ウィ and ティ are Japanese
    #expect(LatinInputGuess.guess(input: "paati", kana: "ぱあてぃ", readingIsWord: false, knownWord: knownWord) == nil)
}

@Test func capitalRunsAreLatinWords() {
    #expect(LatinInputGuess.capitalRuns(keys: Array("SHIFTwoosu")) == [.init(word: "SHIFT", keys: 0 ..< 5)])
    #expect(LatinInputGuess.capitalRuns(keys: Array("korehaAPItoUIdesu")).map(\.word) == ["API", "UI"])
    // A single capital starts a word but is not a run
    #expect(LatinInputGuess.capitalRuns(keys: Array("MacBookPro")).isEmpty)
}

@MainActor
@Test func latinCandidateAppearsWhenConverting() {
    let manager = SegmentsManager(
        kanaKanjiConverter: KanaKanjiConverter.withDefaultDictionary(),
        applicationDirectoryURL: testLearningDirectory,
        personalizationDirectoryURL: nil,
        context: .init(useZenzai: false)
    )
    func convert(_ input: String) -> [String] {
        for character in input {
            manager.insertAtCursorPosition(pieces: [.key(intention: KeyMap.h2zMap(character), input: character, modifiers: [])], inputStyle: .roman2kana)
        }
        manager.insertCompositionSeparator(inputStyle: .roman2kana, skipUpdate: true)
        manager.update(requestRichCandidates: true)
        defer { manager.stopComposition() }
        if case .selecting(let candidates, _) = manager.getCurrentCandidateWindow(inputState: .selecting) {
            return candidates.map(\.text)
        }
        return []
    }
    #expect(convert("windows").first == "windows")
    #expect(!convert("sake").contains("sake"))
}

#if canImport(AppKit)
@MainActor
@Test func systemKnownWordKeepsCapitalsTypedWithShift() {
    #expect(LatinInputGuess.systemKnownWord("GitHub") == "GitHub")
    #expect(LatinInputGuess.systemKnownWord("iPhone") == "iPhone")
    #expect(LatinInputGuess.systemKnownWord("iphone") == "iPhone")
    // A capital starts a word, so these run into one from the Japanese before it
    #expect(LatinInputGuess.systemKnownWord("haWindows") == nil)
    #expect(LatinInputGuess.systemKnownWord("haMac") == nil)
}
#endif
