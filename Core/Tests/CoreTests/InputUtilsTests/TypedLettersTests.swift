@testable import Core
import KanaKanjiConverterModuleWithDefaultDictionary
import Testing

@Test func testWritesUntypedLettersFindsEnglishWrittenForRomaji() {
    // Zenzai writes ノート typed as no-to in English, and ホテル after a Latin word
    #expect(SegmentsManager.writesUntypedLetters("オンライン会議でnoteを共有します", typed: "onrainkaigideno-towokyouyuushimasu"))
    #expect(SegmentsManager.writesUntypedLetters("Apocalypsehotelという映画", typed: "Apocalypsehoterutoiueiga"))
    #expect(!SegmentsManager.writesUntypedLetters("オンライン会議でノートを共有します", typed: "onrainkaigideno-towokyouyuushimasu"))
}

@Test func testWritesUntypedLettersAcceptsTypedLettersInAnyCase() {
    #expect(!SegmentsManager.writesUntypedLetters("今日はGitHubにpushした", typed: "kyouhagithubnipushsita"))
    #expect(!SegmentsManager.writesUntypedLetters("APIを呼ぶ", typed: "apiwoyobu"))
    // Letters still being read as romaji
    #expect(!SegmentsManager.writesUntypedLetters("ノーt", typed: "no-t"))
}

@Test func testWordWritingLettersForKanaReadingCountsAsUntypedEvenWhenKeysSpellThem() {
    // JAM for ジャム: the keys REDjamushinkusettei spell "jam", but the letters were not typed as letters
    let jam = DicdataElement(word: "JAM", ruby: "ジャム", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -10)
    let candidate = Candidate(
        text: "REDJAMシンク設定",
        value: -30,
        composingCount: .inputCount(19),
        lastMid: MIDData.一般.mid,
        data: [
            DicdataElement(word: "RED", ruby: "RED", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -5),
            jam,
            DicdataElement(word: "シンク", ruby: "シンク", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -10),
            DicdataElement(word: "設定", ruby: "セッテイ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -8)
        ]
    )
    #expect(!SegmentsManager.writesUntypedLetters(candidate.text, typed: "REDjamushinkusettei"))
    #expect(SegmentsManager.writesUntypedLetters(candidate, typed: "REDjamushinkusettei"))
    #expect(SegmentsManager.writingReadings(of: candidate, typed: "REDjamushinkusettei")?.text == "REDジャムシンク設定")
    // A temporary entry for a word typed with a capital is meant to write letters for its kana reading
    #expect(!SegmentsManager.writesUntypedLetters(candidate, typed: "REDjamushinkusettei", allowed: [jam]))
}

@Test func testLettersInTheReadingAreTypedLetters() {
    // Letters typed as they are keep a reading of letters (full width), and so does a letter still being typed after
    // kana (アイk): neither is written for kana
    let candidate = Candidate(
        text: "iCloudカスタムアイk",
        value: -30,
        composingCount: .inputCount(13),
        lastMid: MIDData.一般.mid,
        data: [
            DicdataElement(word: "iCloud", ruby: "ｉＣｌｏｕｄ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -5),
            DicdataElement(word: "カスタム", ruby: "カスタム", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -8),
            DicdataElement(word: "アイk", ruby: "アイｋ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -12)
        ]
    )
    #expect(!SegmentsManager.writesUntypedLetters(candidate, typed: "iCloudkasutamuaik"))
}

@Test func testWordsWritingLettersForKanaAreWrittenAsTheirReadings() throws {
    // The converter's dictionary writes Windows for ウインドウズ typed as uindouzu, in every conversion it gives. Written as
    // its reading, the conversion keeps its kanji instead of giving way to the whole input in katakana
    func element(_ word: String, _ ruby: String) -> DicdataElement {
        DicdataElement(word: word, ruby: ruby, cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -10)
    }
    let typed = "tatoebawindowstokakebauindouzuninaranaidesu"
    let words = [("例えば", "タトエバ")] + "windows".map { (String($0), String($0)) }
        + [("と", "ト"), ("書け", "カケ"), ("ば", "バ"), ("Windows", "ウインドウズ"), ("にならない", "ニナラナイ"), ("です", "デス")]
    let data = words.map { element($0.0, $0.1) }
    let candidate = Candidate(text: data.map(\.word).joined(), value: -200, composingCount: .inputCount(typed.count), lastMid: MIDData.一般.mid, data: data)
    #expect(SegmentsManager.writesUntypedLetters(candidate, typed: typed))
    let written = try #require(SegmentsManager.writingReadings(of: candidate, typed: typed))
    #expect(written.text == "例えばwindowsと書けばウインドウズにならないです")
    #expect(!SegmentsManager.writesUntypedLetters(written, typed: typed))
    // A temporary entry meant to write letters for its reading stays as it is (Ogura for オグラ)
    let ogura = element("Ogura", "オグラ")
    let named = Candidate(text: "Ogura", value: -10, composingCount: .inputCount(5), lastMid: MIDData.一般.mid, data: [ogura])
    #expect(SegmentsManager.writingReadings(of: named, typed: "Ogura", allowed: [ogura]) == nil)
}

@Test func testCommittedWordsAreLearnedAsOnePhrase() {
    // 税金を納める learned word by word would raise 納める for おさめる everywhere (国を治める too)
    let data = [
        DicdataElement(word: "税金", ruby: "ゼイキン", lcid: 1285, rcid: 1285, mid: 10, value: -8),
        DicdataElement(word: "を", ruby: "ヲ", lcid: 150, rcid: 150, mid: 20, value: -2),
        DicdataElement(word: "納める", ruby: "オサメル", lcid: 600, rcid: 610, mid: 30, value: -9)
    ]
    let candidate = Candidate(text: "税金を納める", value: -25, composingCount: .inputCount(11), lastMid: 30, data: data)
    let phrase = SegmentsManager.learnedAsOnePhrase(candidate)
    #expect(phrase.text == "税金を納める")
    #expect(phrase.data.count == 1)
    #expect(phrase.data.first?.word == "税金を納める")
    #expect(phrase.data.first?.ruby == "ゼイキンヲオサメル")
    #expect(phrase.data.first?.lcid == 1285)
    #expect(phrase.data.first?.rcid == 610)
    #expect(phrase.data.first?.value() == -19)
    // One word is learned as it is
    let word = Candidate(text: "機会", value: -9, composingCount: .inputCount(5), lastMid: 30, data: [DicdataElement(word: "機会", ruby: "キカイ", cid: 1285, mid: 30, value: -9)])
    #expect(SegmentsManager.learnedAsOnePhrase(word).data == word.data)
}
