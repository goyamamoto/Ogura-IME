@testable import Core
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import Testing

// The guards of the romaji spelling catalog (RomajiSpellings): what reads, types and gates Japanese romaji follows the
// one list, and a change anywhere that it does not cover fails here, not silently in what the user types

@Test("綴りの目録と比べの入口（StandardRomaji）が食い違わない: 比べる綴り（margin のあるもの）は spells() を通り、その margin で比べ、比べない綴りは通らない")
func theCatalogAndTheGateAgree() {
    for spelling in RomajiSpellings.all {
        #expect(StandardRomaji.spells(spelling.spelling) == (spelling.margin != nil), "\(spelling.kana) \(spelling.spelling)")
        if let margin = spelling.margin {
            #expect(StandardRomaji.margin(spelling.spelling) == margin, "\(spelling.spelling)")
        }
    }
    // A word is compared at the strictest margin of the spellings it is typed with, spelled the way that keeps it lowest;
    // ん, っ and ー alone are the standard spellings'
    #expect(StandardRomaji.margin("nijyuu") == SegmentsManager.naturalJapaneseMargin)
    #expect(StandardRomaji.margin("kitte") == SegmentsManager.naturalJapaneseMargin)
    #expect(StandardRomaji.margin("n") == SegmentsManager.naturalJapaneseMargin)
    #expect(StandardRomaji.margin("pa-thi-") == nil)
    #expect(StandardRomaji.margin("code") == nil)
}

@Test("綴りの目録の決まり（目録の値。評価が振る値ではない）: 標準的な綴りは打ち、margin 3（迷ったら日本語）。表が読むだけの綴り（素の c、q、wu、wh-）は打たず、比べない。IME の綴りは、理由と数を書いた時だけ比べ、日本語に打つのに比べない時はその数を書く")
func theCatalogKeepsItsRules() {
    for spelling in RomajiSpellings.all {
        let name = "\(spelling.kana) \(spelling.spelling)"
        switch spelling.kind {
        case .standard:
            #expect(spelling.catalogMargin == SegmentsManager.naturalJapaneseMargin && spelling.weight > 0, "\(name)")
        case .table:
            #expect(spelling.weight == 0 && spelling.catalogMargin == nil, "\(name): read by the input table only")
        case .ime:
            if spelling.catalogMargin != nil || spelling.weight > 0 {
                #expect(spelling.note.contains { $0.isNumber }, "\(name): its numbers go in its note")
            }
        }
    }
    // Of the input methods' spellings, these are compared, each on its own measured reason: jy- (people type じゃ, じゅ,
    // じょ so), and the small っ and ん, cy- and fw- / hw- that (nearly) no English word of the lexicon is spelled with
    // (xn at 6, where its one word stays letters). Changing this set needs the numbers in the spellings' notes
    #expect(Set(RomajiSpellings.all.filter { $0.kind == .ime && $0.catalogMargin != nil }.map(\.spelling))
                == ["jya", "jyu", "jye", "jyo", "jyi", "xtsu", "ltsu", "cyo", "cyu", "fwa", "fwi", "fwo", "fwe", "hwe", "hwi", "hwo", "xn"])
    #expect(RomajiSpellings.all.first { $0.spelling == "xn" }?.catalogMargin == 6)
}

@Test("評価が振る margin（OGURA_ROMAJI_MARGINS）: 綴りそのもの、その頭、区分の順に効き、none は比べない。書いていない綴りは目録のまま")
func marginsSetForAnEvaluation() {
    let overrides = RomajiSpellings.overrides("ime=6, jy=2.5,thi=8,table=none,standard=none,bad,also=x")
    let spellings = Dictionary(uniqueKeysWithValues: RomajiSpellings.parse(RomajiSpellings.table, overrides: overrides).map { ($0.spelling, $0) })
    #expect(spellings["jyu"]?.margin == 2.5)
    #expect(spellings["thi"]?.margin == 8)
    #expect(spellings["cya"]?.margin == 6)
    #expect(spellings["ca"]?.margin == nil)
    #expect(spellings["shi"]?.margin == nil)
    #expect(spellings["shi"]?.catalogMargin == SegmentsManager.naturalJapaneseMargin)
    let none = Dictionary(uniqueKeysWithValues: RomajiSpellings.parse(RomajiSpellings.table, overrides: [:]).map { ($0.spelling, $0) })
    #expect(none.values.allSatisfy { $0.margin == $0.catalogMargin })
}

@Test("綴りの目録の形: 仮名ごとの重みの和は 1（打たない仮名は 0）。綴りは 1 度だけ。入力の表が読まない Mozc の綴りは目録に無い")
func theCatalogIsWellFormed() {
    for (kana, spellings) in Dictionary(grouping: RomajiSpellings.all, by: \.kana) {
        let total = spellings.map(\.weight).reduce(0, +)
        #expect(abs(total - 1) < 0.01 || total == 0, "\(kana): the weights add up to \(total)")
    }
    let spellings = RomajiSpellings.all.map(\.spelling)
    #expect(Set(spellings).count == spellings.count)
    #expect(Set(spellings).isDisjoint(with: RomajiSpellings.notReadByTheInputTable))
}

@Test("入力の表（変換器の既定のローマ字表）が仮名にする綴りは全部目録にあり、目録の綴りは全部入力の表が同じ仮名に読む。表が変われば、目録を直すまでここで落ちる")
func theCatalogHoldsEverySpellingTheInputTableReads() throws {
    let exported = try InputStyleManager.exportTable(InputTable.defaultRomanToKana)
    var table: [String: String] = [:]
    for line in exported.split(separator: "\n") {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        // Letters to kana only: っ by doubling a consonant, ん before another key, and symbols are how romaji is built,
        // not spellings (see StandardRomaji.spells)
        guard fields.count == 2, !fields[0].isEmpty, fields[0].allSatisfy({ $0.isASCII && $0.isLowercase }), !fields[1].isEmpty,
              fields[1].unicodeScalars.allSatisfy({ (0x3041 ... 0x3096).contains($0.value) }) else {
            continue
        }
        table[fields[0]] = fields[1]
    }
    let catalog = Dictionary(uniqueKeysWithValues: RomajiSpellings.all.map { ($0.spelling, $0.kana) })
    let missing = table.filter { catalog[$0.key] != $0.value }.map { "\($0.key)=\($0.value)" }.sorted()
    let extra = catalog.filter { table[$0.key] != $0.value }.map { "\($0.key)=\($0.value)" }.sorted()
    #expect(missing.isEmpty, "the input table reads these, the catalog does not have them: \(missing)")
    #expect(extra.isEmpty, "the catalog has these, the input table does not read them so: \(extra)")
}

@Test("目録の書き出し（道具が読む TSV）は目録の行と同じ")
func theCatalogWrittenOutIsTheCatalog() {
    let lines = RomajiSpellings.tsv.split(separator: "\n").map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
    #expect(lines.count == RomajiSpellings.all.count)
    for (fields, spelling) in zip(lines, RomajiSpellings.all) {
        #expect(fields.count == 7)
        #expect(fields[0] == spelling.kana && fields[1] == spelling.spelling && Double(fields[2]) == spelling.weight)
        #expect(fields[4] == spelling.kind.rawValue && fields[5] == (spelling.catalogMargin.map { String(format: "%g", $0) } ?? "none"))
    }
}
