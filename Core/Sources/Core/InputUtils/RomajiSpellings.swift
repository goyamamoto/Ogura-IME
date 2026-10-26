import Foundation

/// The romaji spellings of each kana that Ogura's input table reads, one list for everything that needs them: the gate
/// to Zenzai's naturalness check (`StandardRomaji`), the identification layer's training data and the evaluation sets.
///
/// Where the spellings come from: Ogura's input table (the converter's default romaji table, which every key goes
/// through) and Mozc's public romaji table (google/mozc, src/data/preedit/romanji-hiragana.tsv). Whether they are
/// MS-IME's is not confirmed (its table is published only as images): no spelling here is said to be MS-IME's. The
/// spellings Mozc reads and the input table does not are left out (`notReadByTheInputTable`): they would change what
/// the keys type.
///
/// Each spelling is of a `kind`: `standard` (Hepburn, Kunrei, Nihon-shiki, Hepburn's loanword spellings), `ime` (spelled
/// so in input methods, not in the standard systems: jy-, cy-, thi, dhi, x and l for small kana, xtu…), or `table` (the
/// input table reads it, but nobody types Japanese so: bare c and q, wu, wh-). And it has two things, kept
/// apart:
/// - `weight`: how often people typing Japanese use it for its kana, among its spellings (those of a kana add up to 1,
///   or all are 0). Priors, not measured: there is no data on how people type. Standard spellings are typed; `ime`
///   ones only where the kana has no standard spelling (thi, small kana, xtu) and jy-; `table` ones never. The training
///   data and the evaluation sets type Japanese by these weights.
/// - `margin`: how much likelier Zenzai must find the keys of a word spelled with it read as kana than as letters for
///   the word to be Japanese (`StandardRomaji.margin`, `SegmentsManager.keepingNaturalJapanese`): keys that read as
///   kana are compared both ways, and the catalog only sets how far the comparison leans; nil, not compared. Standard
///   spellings 3 (`SegmentsManager.naturalJapaneseMargin`: Japanese when in doubt); an `ime` one only with its own
///   reason (people type Japanese so) and its numbers, in its `note`; `table` ones never: romaji support beyond the
///   standard systems is limited on purpose, and code is never コデ (care and 彼, core and これ both read naturally, so
///   the comparison alone would not keep them). The values are measured, not chosen: `OGURA_ROMAJI_MARGINS` sets
///   others for an evaluation (see `overrides`)
///
/// The numbers in the notes of the spellings beyond the standard systems, measured with the naturalness check on its
/// own at the app's settings: the lexicon's words it lets spell (that become romaji with it); J,
/// the pieces of Japanese typed with it that the identifier left as letters in evaluation sentences, and how
/// many the comparison turns back to kana at a margin of 3, 6 and 9; L, the lexicon's English words spelled with it
/// put in four sentence frames (a fifth, with a capital, never reaches the comparison), and how many the comparison
/// turns into kana at 3, 6 and 9. L puts the lexicon's words (which have no frequencies) in fixed frames: rare words
/// push its counts up, and it is not weighted by the words people actually type
enum RomajiSpellings {
    enum Kind: String, Sendable {
        case standard
        case ime
        case table
    }

    struct Spelling: Equatable, Sendable {
        let kana: String
        let spelling: String
        let weight: Double
        /// app: Ogura's input table; mozc: Mozc's public table
        let sources: [String]
        let kind: Kind
        /// As the catalog has it
        let catalogMargin: Float?
        /// In effect: the catalog's, or what `OGURA_ROMAJI_MARGINS` sets (see `overrides`)
        let margin: Float?
        /// Why an `ime` spelling is compared, or is not though typed for Japanese, with its numbers
        let note: String

        /// Whether words spelled with it are compared (Japanese when Zenzai finds them natural enough)
        var japaneseWhenInDoubt: Bool {
            self.margin != nil
        }
    }

    static let all: [Spelling] = Self.parse(Self.table, overrides: Self.overrides(ProcessInfo.processInfo.environment["OGURA_ROMAJI_MARGINS"]))

    /// The catalog's lines, each spelling's margin set by `overrides` where they name it: the spelling itself, else the
    /// longest start of it, else its kind
    static func parse(_ table: String, overrides: [String: Float?]) -> [Spelling] {
        table.split(separator: "\n").map { line in
            let fields = line.split(separator: " ", maxSplits: 6, omittingEmptySubsequences: true).map(String.init)
            let spelling = fields[1], kind = Kind(rawValue: fields[4]) ?? .table
            let catalogMargin = Float(fields[5])
            let named = Self.named(spelling, kind: kind, in: overrides)
            return Spelling(
                kana: fields[0], spelling: spelling, weight: Double(fields[2]) ?? 0, sources: fields[3].split(separator: ",").map(String.init), kind: kind,
                catalogMargin: catalogMargin, margin: named ?? catalogMargin, note: fields.count > 6 && fields[6] != "-" ? fields[6] : ""
            )
        }
    }

    /// The margin `overrides` set for `spelling`: by the spelling itself, else the longest start of it, else its kind;
    /// nil when none names it (a set none is .some(nil))
    private static func named(_ spelling: String, kind: Kind, in overrides: [String: Float?]) -> Float?? {
        if let margin = overrides[spelling] {
            return margin
        }
        for length in (1 ..< max(1, spelling.count)).reversed() {
            if let margin = overrides[String(spelling.prefix(length))] {
                return margin
            }
        }
        return overrides[kind.rawValue]
    }

    /// Margins an evaluation sets in place of the catalog's (`OGURA_ROMAJI_MARGINS`): name=value pairs separated by
    /// commas, a name a kind (standard, ime, table), a spelling, or its start (jy for jya, jyu…), a value a number or
    /// none (not compared): ime=6,jy=3,thi=8,table=none. The app never sets it
    static func overrides(_ text: String?) -> [String: Float?] {
        var overrides: [String: Float?] = [:]
        for pair in (text ?? "").split(separator: ",") {
            let parts = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty else {
                continue
            }
            if parts[1] == "none" {
                overrides[parts[0]] = .some(nil)
            } else if let value = Float(parts[1]) {
                overrides[parts[0]] = value
            }
        }
        return overrides
    }

    /// The margins in effect, for the first line of an evaluation's results: by kind, and the spellings whose margin is
    /// not their kind's catalog default, and the overrides set
    static var marginsDescription: String {
        func text(_ margin: Float?) -> String {
            margin.map { String(format: "%g", $0) } ?? "none"
        }
        let byKind = [Kind.standard, .ime, .table].map { kind in
            let margins = Set(Self.all.filter { $0.kind == kind }.map { text($0.margin) })
            return "\(kind.rawValue) \(margins.sorted().joined(separator: "/"))"
        }
        let compared = Self.all.filter { $0.kind != .standard && $0.margin != nil }.map { "\($0.spelling) \(text($0.margin))" }
        let set = ProcessInfo.processInfo.environment["OGURA_ROMAJI_MARGINS"] ?? "none"
        return byKind.joined(separator: ", ") + "; compared beyond the standard: " + compared.joined(separator: " ") + "; OGURA_ROMAJI_MARGINS=" + set
    }

    /// The catalog as kana, spelling, weight, sources, kind, margin (none: not compared) and note, separated by tabs, a
    /// line for each spelling, for the tools (the catalog's margins, not the overrides)
    static var tsv: String {
        Self.all.map {
            [$0.kana, $0.spelling, String($0.weight), $0.sources.joined(separator: ","), $0.kind.rawValue, $0.catalogMargin.map { String(format: "%g", $0) } ?? "none", $0.note]
                .joined(separator: "\t")
        }.joined(separator: "\n") + "\n"
    }

    /// What Mozc reads that Ogura's input table does not: left out, as they would change what the keys type
    static let notReadByTheInputTable = [
        "kyi", "gyi", "syi", "zyi", "vya", "vyi", "vyu", "vye", "vyo", "lyi", "xyi", "lye", "xye", "zwa", "zwi", "zwu", "zwe", "zwo",
        "hwyu", "n", "n'", "t'i", "d'i", "t'u", "d'u", "t'yu", "d'yu"
    ]

    /// kana, spelling, weight, sources, kind, margin (none: not compared), note (- for none)
    static let table = """
    あ a 1 app,mozc standard 3 -
    ぁ xa 0.5 app,mozc ime none not compared, the identifier decides: in only with its own reason; lexicon words it lets spell: 98; J 0; L 214 (60 words) → kana at 3/6/9: 2/2/0
    ぁ la 0.5 app,mozc ime none not compared, the identifier decides: in only with its own reason; lexicon words it lets spell: 1324; J 0; L 117 (30 words) → kana at 3/6/9: 4/3/0
    い i 1 app,mozc standard 3 -
    ぃ xi 0.5 app,mozc ime none not compared, the identifier decides: in only with its own reason; lexicon words it lets spell: 183; J 0; L 215 (60 words) → kana at 3/6/9: 26/10/2
    ぃ li 0.5 app,mozc ime none not compared, the identifier decides: in only with its own reason; lexicon words it lets spell: 1790; J 0; L 111 (30 words) → kana at 3/6/9: 0/0/0
    う u 1 app,mozc standard 3 -
    う wu 0 app,mozc table none not compared: read by the input table only; lexicon words it lets spell: 13; J 4 → kana at 3/6/9: 4/4/4; L 47 (12 words) → kana at 3/6/9: 26/18/10
    う whu 0 app,mozc table none not compared: read by the input table only; lexicon words it lets spell: 2; J 5 → kana at 3/6/9: 5/5/5; L 8 (2 words) → kana at 3/6/9: 5/4/2
    ゔ vu 1 app,mozc standard 3 -
    ぅ xu 0.5 app,mozc ime none not compared, the identifier decides: in only with its own reason; lexicon words it lets spell: 19; J 0; L 58 (18 words) → kana at 3/6/9: 2/0/0
    ぅ lu 0.5 app,mozc ime none not compared, the identifier decides: in only with its own reason; lexicon words it lets spell: 337; J 0; L 115 (30 words) → kana at 3/6/9: 1/0/0
    え e 1 app,mozc standard 3 -
    ぇ xe 0.5 app,mozc ime none not compared, the identifier decides: in only with its own reason; lexicon words it lets spell: 60; J 0; L 221 (59 words) → kana at 3/6/9: 26/7/3
    ぇ le 0.5 app,mozc ime none not compared, the identifier decides: in only with its own reason; lexicon words it lets spell: 1040; J 0; L 114 (30 words) → kana at 3/6/9: 1/0/0
    お o 1 app,mozc standard 3 -
    ぉ xo 0.5 app,mozc ime none not compared, the identifier decides: in only with its own reason; lexicon words it lets spell: 58; J 0; L 203 (57 words) → kana at 3/6/9: 5/0/0
    ぉ lo 0.5 app,mozc ime none not compared, the identifier decides: in only with its own reason; lexicon words it lets spell: 630; J 0; L 115 (30 words) → kana at 3/6/9: 1/0/0
    か ka 1 app,mozc standard 3 -
    か ca 0 app,mozc table none not compared: keeping the English words spelled with co would need a margin of 9 and cake 15, and then only 60 to 83 of 105 pieces of Japanese typed with co come back as kana; lexicon words it lets spell: 963; J 65 → kana at 3/6/9: 64/60/59; L 115 (30 words) → kana at 3/6/9: 47/28/18
    が ga 1 app,mozc standard 3 -
    ゕ xka 0.5 app ime none not compared, the identifier decides: in only with its own reason; lexicon words it lets spell: 0; J 0; L 0 (0 words)
    ゕ lka 0.5 app ime none not compared, the identifier decides: in only with its own reason; lexicon words it lets spell: 17; J 0; L 61 (17 words) → kana at 3/6/9: 0/0/0
    き ki 1 app,mozc standard 3 -
    ぎ gi 1 app,mozc standard 3 -
    く ku 1 app,mozc standard 3 -
    く cu 0 app,mozc table none not compared: keeping the English words spelled with co would need a margin of 9 and cake 15, and then only 60 to 83 of 105 pieces of Japanese typed with co come back as kana; lexicon words it lets spell: 268; J 25 → kana at 3/6/9: 25/25/25; L 109 (30 words) → kana at 3/6/9: 59/49/27
    ぐ gu 1 app,mozc standard 3 -
    け ke 1 app,mozc standard 3 -
    げ ge 1 app,mozc standard 3 -
    ゖ xke 0.5 app ime none not compared, the identifier decides: in only with its own reason; lexicon words it lets spell: 0; J 0; L 0 (0 words)
    ゖ lke 0.5 app ime none not compared, the identifier decides: in only with its own reason; lexicon words it lets spell: 9; J 0; L 32 (9 words) → kana at 3/6/9: 0/0/0
    こ ko 1 app,mozc standard 3 -
    こ co 0 app,mozc table none not compared: keeping the English words spelled with co would need a margin of 9 and cake 15, and then only 60 to 83 of 105 pieces of Japanese typed with co come back as kana; lexicon words it lets spell: 962; J 105 → kana at 3/6/9: 104/99/83; L 117 (30 words) → kana at 3/6/9: 50/36/24
    ご go 1 app,mozc standard 3 -
    さ sa 1 app,mozc standard 3 -
    ざ za 1 app,mozc standard 3 -
    し si 0.398 app,mozc standard 3 -
    し ci 0 app,mozc table none not compared: keeping the English words spelled with co would need a margin of 9 and cake 15, and then only 60 to 83 of 105 pieces of Japanese typed with co come back as kana; lexicon words it lets spell: 470; J 25 → kana at 3/6/9: 25/25/20; L 112 (30 words) → kana at 3/6/9: 34/22/16
    し shi 0.602 app,mozc standard 3 -
    じ zi 0.398 app,mozc standard 3 -
    じ ji 0.602 app,mozc standard 3 -
    す su 1 app,mozc standard 3 -
    ず zu 1 app,mozc standard 3 -
    せ se 1 app,mozc standard 3 -
    せ ce 0 app,mozc table none not compared: keeping the English words spelled with co would need a margin of 9 and cake 15, and then only 60 to 83 of 105 pieces of Japanese typed with co come back as kana; lexicon words it lets spell: 755; J 48 → kana at 3/6/9: 48/47/46; L 111 (30 words) → kana at 3/6/9: 18/9/7
    ぜ ze 1 app,mozc standard 3 -
    そ so 1 app,mozc standard 3 -
    ぞ zo 1 app,mozc standard 3 -
    た ta 1 app,mozc standard 3 -
    だ da 1 app,mozc standard 3 -
    ち ti 0.398 app,mozc standard 3 -
    ち chi 0.602 app,mozc standard 3 -
    ぢ di 1 app,mozc standard 3 -
    つ tu 0.398 app,mozc standard 3 -
    つ tsu 0.602 app,mozc standard 3 -
    っ xtu 0.25 app,mozc ime none not compared, the identifier decides: in only with its own reason; lexicon words it lets spell: 15; J 0; L 53 (15 words) → kana at 3/6/9: 12/6/5
    っ ltu 0.25 app,mozc ime none not compared, the identifier decides: in only with its own reason; lexicon words it lets spell: 13; J 4 → kana at 3/6/9: 4/4/4; L 49 (13 words) → kana at 3/6/9: 10/9/5
    っ xtsu 0.25 app,mozc ime 3 compared at 3: no English word of the lexicon is spelled with it; lexicon words it lets spell: 0; J 18 → kana at 3/6/9: 18/18/16; L 0 (0 words)
    っ ltsu 0.25 app,mozc ime 3 compared at 3: no English word of the lexicon is spelled with it; lexicon words it lets spell: 0; J 17 → kana at 3/6/9: 17/17/17; L 0 (0 words)
    づ du 1 app,mozc standard 3 -
    て te 1 app,mozc standard 3 -
    で de 1 app,mozc standard 3 -
    と to 1 app,mozc standard 3 -
    ど do 1 app,mozc standard 3 -
    な na 1 app,mozc standard 3 -
    に ni 1 app,mozc standard 3 -
    ぬ nu 1 app,mozc standard 3 -
    ね ne 1 app,mozc standard 3 -
    の no 1 app,mozc standard 3 -
    は ha 1 app,mozc standard 3 -
    ば ba 1 app,mozc standard 3 -
    ぱ pa 1 app,mozc standard 3 -
    ひ hi 1 app,mozc standard 3 -
    び bi 1 app,mozc standard 3 -
    ぴ pi 1 app,mozc standard 3 -
    ふ hu 0.398 app,mozc standard 3 -
    ふ fu 0.602 app,mozc standard 3 -
    ぶ bu 1 app,mozc standard 3 -
    ぷ pu 1 app,mozc standard 3 -
    へ he 1 app,mozc standard 3 -
    べ be 1 app,mozc standard 3 -
    ぺ pe 1 app,mozc standard 3 -
    ほ ho 1 app,mozc standard 3 -
    ぼ bo 1 app,mozc standard 3 -
    ぽ po 1 app,mozc standard 3 -
    ま ma 1 app,mozc standard 3 -
    み mi 1 app,mozc standard 3 -
    む mu 1 app,mozc standard 3 -
    め me 1 app,mozc standard 3 -
    も mo 1 app,mozc standard 3 -
    や ya 1 app,mozc standard 3 -
    ゃ xya 0.5 app,mozc ime none not compared, the identifier decides: in only with its own reason; lexicon words it lets spell: 2; J 0; L 7 (2 words) → kana at 3/6/9: 3/2/0
    ゃ lya 0.5 app,mozc ime none not compared, the identifier decides: in only with its own reason; lexicon words it lets spell: 13; J 0; L 49 (13 words) → kana at 3/6/9: 15/9/2
    ゆ yu 1 app,mozc standard 3 -
    ゅ xyu 0.5 app,mozc ime none not compared, the identifier decides: in only with its own reason; lexicon words it lets spell: 0; J 0; L 0 (0 words)
    ゅ lyu 0.5 app,mozc ime none not compared, the identifier decides: in only with its own reason; lexicon words it lets spell: 1; J 0; L 4 (1 words) → kana at 3/6/9: 1/0/0
    よ yo 1 app,mozc standard 3 -
    ょ xyo 0.5 app,mozc ime none not compared, the identifier decides: in only with its own reason; lexicon words it lets spell: 1; J 0; L 3 (1 words) → kana at 3/6/9: 0/0/0
    ょ lyo 0.5 app,mozc ime none not compared, the identifier decides: in only with its own reason; lexicon words it lets spell: 8; J 0; L 32 (8 words) → kana at 3/6/9: 3/2/1
    ら ra 1 app,mozc standard 3 -
    り ri 1 app,mozc standard 3 -
    る ru 1 app,mozc standard 3 -
    れ re 1 app,mozc standard 3 -
    ろ ro 1 app,mozc standard 3 -
    わ wa 1 app,mozc standard 3 -
    ゎ xwa 0.5 app,mozc ime none not compared, the identifier decides: in only with its own reason; lexicon words it lets spell: 1; J 0; L 3 (1 words) → kana at 3/6/9: 0/0/0
    ゎ lwa 0.5 app,mozc ime none not compared, the identifier decides: in only with its own reason; lexicon words it lets spell: 7; J 0; L 26 (7 words) → kana at 3/6/9: 0/0/0
    ゐ wyi 1 app,mozc ime none not compared, the identifier decides: in only with its own reason; lexicon words it lets spell: 0; J 0; L 0 (0 words)
    ゑ wye 1 app,mozc ime none not compared, the identifier decides: in only with its own reason; lexicon words it lets spell: 1; J 0; L 4 (1 words) → kana at 3/6/9: 2/1/0
    を wo 1 app,mozc standard 3 -
    ん nn 1 app,mozc standard 3 -
    ん xn 0 app,mozc ime 6 compared at 6: two English words of the lexicon are spelled with it, and the one in the fixed frames stays letters at 6 (L); lexicon words it lets spell: 2; J 20 → kana at 3/6/9: 20/20/20; L 4 (1 words) → kana at 3/6/9: 1/0/0
    いぇ ye 1 app,mozc standard 3 -
    ゔぁ va 1 app,mozc standard 3 -
    ゔぃ vi 1 app,mozc standard 3 -
    ゔぇ ve 1 app,mozc standard 3 -
    ゔぉ vo 1 app,mozc standard 3 -
    きゃ kya 1 app,mozc standard 3 -
    きゅ kyu 1 app,mozc standard 3 -
    きぇ kye 1 app,mozc standard 3 -
    きょ kyo 1 app,mozc standard 3 -
    ぎゃ gya 1 app,mozc standard 3 -
    ぎゅ gyu 1 app,mozc standard 3 -
    ぎぇ gye 1 app,mozc standard 3 -
    ぎょ gyo 1 app,mozc standard 3 -
    くぁ qa 0 app,mozc table none not compared: read by the input table only; lexicon words it lets spell: 7; J 0; L 24 (6 words) → kana at 3/6/9: 0/0/0
    くぁ kwa 1 app,mozc standard 3 -
    くぁ qwa 0 app table none not compared: read by the input table only; lexicon words it lets spell: 0; J 0; L 0 (0 words)
    くぃ qi 0 app,mozc table none not compared: read by the input table only; lexicon words it lets spell: 7; J 0; L 23 (6 words) → kana at 3/6/9: 3/0/0
    くぃ kwi 1 app,mozc ime none not compared, the identifier decides: in only with its own reason; lexicon words it lets spell: 4; J 0; L 16 (4 words) → kana at 3/6/9: 0/0/0
    くぃ qwi 0 app table none not compared: read by the input table only; lexicon words it lets spell: 0; J 0; L 0 (0 words)
    くぅ qu 0 app table none not compared: read by the input table only; lexicon words it lets spell: 332; J 0; L 111 (30 words) → kana at 3/6/9: 0/0/0
    くぅ kwu 1 app,mozc ime none not compared, the identifier decides: in only with its own reason; lexicon words it lets spell: 0; J 0; L 0 (0 words)
    くぅ qwu 0 app table none not compared: read by the input table only; lexicon words it lets spell: 0; J 0; L 0 (0 words)
    くぇ qe 0 app,mozc table none not compared: read by the input table only; lexicon words it lets spell: 4; J 0; L 16 (4 words) → kana at 3/6/9: 3/1/0
    くぇ kwe 1 app,mozc ime none not compared, the identifier decides: in only with its own reason; lexicon words it lets spell: 0; J 0; L 0 (0 words)
    くぇ qwe 0 app table none not compared: read by the input table only; lexicon words it lets spell: 1; J 0; L 4 (1 words) → kana at 3/6/9: 1/1/0
    くぉ qo 0 app,mozc table none not compared: read by the input table only; lexicon words it lets spell: 3; J 0; L 8 (2 words) → kana at 3/6/9: 1/0/0
    くぉ kwo 1 app,mozc ime none not compared, the identifier decides: in only with its own reason; lexicon words it lets spell: 0; J 0; L 0 (0 words)
    くぉ qwo 0 app table none not compared: read by the input table only; lexicon words it lets spell: 0; J 0; L 0 (0 words)
    ぐぁ gwa 1 app,mozc standard 3 -
    ぐぃ gwi 1 app,mozc ime none not compared, the identifier decides: in only with its own reason; lexicon words it lets spell: 7; J 0; L 28 (7 words) → kana at 3/6/9: 0/0/0
    ぐぅ gwu 1 app,mozc ime none not compared, the identifier decides: in only with its own reason; lexicon words it lets spell: 0; J 0; L 0 (0 words)
    ぐぇ gwe 1 app,mozc ime none not compared, the identifier decides: in only with its own reason; lexicon words it lets spell: 1; J 0; L 4 (1 words) → kana at 3/6/9: 0/0/0
    ぐぉ gwo 1 app,mozc ime none not compared, the identifier decides: in only with its own reason; lexicon words it lets spell: 1; J 0; L 4 (1 words) → kana at 3/6/9: 0/0/0
    しゃ sha 0.602 app,mozc standard 3 -
    しゃ sya 0.398 app,mozc standard 3 -
    しゅ shu 0.602 app,mozc standard 3 -
    しゅ syu 0.398 app,mozc standard 3 -
    しぇ she 0.602 app,mozc standard 3 -
    しぇ sye 0.398 app,mozc standard 3 -
    しょ sho 0.602 app,mozc standard 3 -
    しょ syo 0.398 app,mozc standard 3 -
    じゃ ja 0.524 app,mozc standard 3 -
    じゃ zya 0.346 app,mozc standard 3 -
    じゃ jya 0.131 app,mozc ime 3 compared: people type じゃ じゅ じぇ じょ じぃ so; lexicon words it lets spell: 0; J 1 → kana at 3/6/9: 1/1/1; L 0 (0 words)
    じぃ jyi 1 app,mozc ime 3 compared: people type じゃ じゅ じぇ じょ じぃ so; lexicon words it lets spell: 0; J 0; L 0 (0 words)
    じゅ ju 0.524 app,mozc standard 3 -
    じゅ zyu 0.346 app,mozc standard 3 -
    じゅ jyu 0.131 app,mozc ime 3 compared: people type じゃ じゅ じぇ じょ じぃ so; lexicon words it lets spell: 1; J 12 → kana at 3/6/9: 12/12/12; L 4 (1 words) → kana at 3/6/9: 4/3/3
    じぇ je 0.524 app,mozc standard 3 -
    じぇ zye 0.346 app,mozc standard 3 -
    じぇ jye 0.131 app,mozc ime 3 compared: people type じゃ じゅ じぇ じょ じぃ so; lexicon words it lets spell: 0; J 0; L 0 (0 words)
    じょ jo 0.524 app,mozc standard 3 -
    じょ zyo 0.346 app,mozc standard 3 -
    じょ jyo 0.131 app,mozc ime 3 compared: people type じゃ じゅ じぇ じょ じぃ so; lexicon words it lets spell: 0; J 2 → kana at 3/6/9: 2/2/2; L 0 (0 words)
    すぁ swa 1 app,mozc ime none not compared, the identifier decides: in only with its own reason; lexicon words it lets spell: 14; J 0; L 56 (14 words) → kana at 3/6/9: 0/0/0
    すぃ swi 1 app,mozc ime none not compared, the identifier decides: in only with its own reason; lexicon words it lets spell: 16; J 0; L 59 (15 words) → kana at 3/6/9: 2/1/0
    すぅ swu 1 app,mozc ime none not compared, the identifier decides: in only with its own reason; lexicon words it lets spell: 2; J 0; L 8 (2 words) → kana at 3/6/9: 0/0/0
    すぇ swe 1 app,mozc ime none not compared, the identifier decides: in only with its own reason; lexicon words it lets spell: 8; J 0; L 31 (8 words) → kana at 3/6/9: 0/0/0
    すぉ swo 1 app,mozc ime none not compared, the identifier decides: in only with its own reason; lexicon words it lets spell: 8; J 0; L 31 (8 words) → kana at 3/6/9: 1/0/0
    ちゃ cha 0.602 app,mozc standard 3 -
    ちゃ cya 0 app,mozc ime none not compared, the identifier decides: in only with its own reason; lexicon words it lets spell: 53; J 17 → kana at 3/6/9: 11/11/10; L 202 (53 words) → kana at 3/6/9: 64/28/14
    ちゃ tya 0.398 app,mozc standard 3 -
    ちぃ tyi 0.5 app,mozc ime none not compared, the identifier decides: in only with its own reason; lexicon words it lets spell: 2; J 0; L 8 (2 words) → kana at 3/6/9: 1/0/0
    ちぃ cyi 0.5 app,mozc ime none not compared, the identifier decides: in only with its own reason; lexicon words it lets spell: 1; J 0; L 4 (1 words) → kana at 3/6/9: 1/0/0
    ちゅ chu 0.602 app,mozc standard 3 -
    ちゅ cyu 0 app,mozc ime 3 compared at 3: no English word of the lexicon is spelled with it; lexicon words it lets spell: 0; J 1 → kana at 3/6/9: 1/1/1; L 0 (0 words)
    ちゅ tyu 0.398 app,mozc standard 3 -
    ちぇ che 0.602 app,mozc standard 3 -
    ちぇ cye 0 app,mozc ime none not compared, the identifier decides: in only with its own reason; lexicon words it lets spell: 3; J 2 → kana at 3/6/9: 2/2/1; L 9 (3 words) → kana at 3/6/9: 8/5/3
    ちぇ tye 0.398 app,mozc standard 3 -
    ちょ cho 0.602 app,mozc standard 3 -
    ちょ cyo 0 app,mozc ime 3 compared at 3: no English word of the lexicon is spelled with it; lexicon words it lets spell: 0; J 8 → kana at 3/6/9: 8/8/8; L 0 (0 words)
    ちょ tyo 0.398 app,mozc standard 3 -
    つぁ tsa 1 app,mozc standard 3 -
    つぃ tsi 1 app,mozc standard 3 -
    つぇ tse 1 app,mozc standard 3 -
    つぉ tso 1 app,mozc standard 3 -
    てゃ tha 1 app,mozc ime none not compared, the identifier decides: in only with its own reason; lexicon words it lets spell: 52; J 0; L 193 (52 words) → kana at 3/6/9: 20/5/0
    てぃ thi 1 app,mozc ime none not compared, the identifier decides: in only with its own reason; lexicon words it lets spell: 90; J 0; L 225 (60 words) → kana at 3/6/9: 80/53/22
    てゅ thu 1 app,mozc ime none not compared, the identifier decides: in only with its own reason; lexicon words it lets spell: 14; J 2 → kana at 3/6/9: 2/2/1; L 52 (14 words) → kana at 3/6/9: 12/3/0
    てぇ the 1 app,mozc ime none not compared, the identifier decides: in only with its own reason; lexicon words it lets spell: 166; J 0; L 219 (60 words) → kana at 3/6/9: 11/3/0
    てょ tho 1 app,mozc ime none not compared, the identifier decides: in only with its own reason; lexicon words it lets spell: 73; J 0; L 223 (60 words) → kana at 3/6/9: 12/6/4
    とぁ twa 1 app,mozc ime none not compared, the identifier decides: in only with its own reason; lexicon words it lets spell: 19; J 0; L 72 (19 words) → kana at 3/6/9: 0/0/0
    とぃ twi 1 app,mozc ime none not compared, the identifier decides: in only with its own reason; lexicon words it lets spell: 34; J 0; L 130 (34 words) → kana at 3/6/9: 3/0/0
    とぅ twu 1 app,mozc ime none not compared, the identifier decides: in only with its own reason; lexicon words it lets spell: 0; J 0; L 0 (0 words)
    とぇ twe 1 app,mozc ime none not compared, the identifier decides: in only with its own reason; lexicon words it lets spell: 9; J 0; L 32 (9 words) → kana at 3/6/9: 1/0/0
    とぉ two 1 app,mozc ime none not compared, the identifier decides: in only with its own reason; lexicon words it lets spell: 8; J 0; L 28 (8 words) → kana at 3/6/9: 0/0/0
    ぢゃ dya 1 app,mozc standard 3 -
    ぢぃ dyi 1 app,mozc ime none not compared, the identifier decides: in only with its own reason; lexicon words it lets spell: 3; J 0; L 12 (3 words) → kana at 3/6/9: 0/0/0
    ぢゅ dyu 1 app,mozc standard 3 -
    ぢぇ dye 1 app,mozc standard 3 -
    ぢょ dyo 1 app,mozc standard 3 -
    でゃ dha 1 app,mozc ime none not compared, the identifier decides: in only with its own reason; lexicon words it lets spell: 11; J 0; L 42 (11 words) → kana at 3/6/9: 6/1/0
    でぃ dhi 1 app,mozc ime none not compared, the identifier decides: in only with its own reason; lexicon words it lets spell: 7; J 0; L 27 (7 words) → kana at 3/6/9: 10/5/2
    でゅ dhu 1 app,mozc ime none not compared, the identifier decides: in only with its own reason; lexicon words it lets spell: 7; J 0; L 27 (7 words) → kana at 3/6/9: 11/6/1
    でぇ dhe 1 app,mozc ime none not compared, the identifier decides: in only with its own reason; lexicon words it lets spell: 16; J 0; L 58 (16 words) → kana at 3/6/9: 3/0/0
    でょ dho 1 app,mozc ime none not compared, the identifier decides: in only with its own reason; lexicon words it lets spell: 10; J 0; L 40 (10 words) → kana at 3/6/9: 3/1/0
    どぁ dwa 1 app,mozc ime none not compared, the identifier decides: in only with its own reason; lexicon words it lets spell: 7; J 0; L 26 (7 words) → kana at 3/6/9: 0/0/0
    どぃ dwi 1 app,mozc ime none not compared, the identifier decides: in only with its own reason; lexicon words it lets spell: 17; J 0; L 65 (17 words) → kana at 3/6/9: 0/0/0
    どぅ dwu 1 app,mozc ime none not compared, the identifier decides: in only with its own reason; lexicon words it lets spell: 0; J 0; L 0 (0 words)
    どぇ dwe 1 app,mozc ime none not compared, the identifier decides: in only with its own reason; lexicon words it lets spell: 0; J 0; L 0 (0 words)
    どぉ dwo 1 app,mozc ime none not compared, the identifier decides: in only with its own reason; lexicon words it lets spell: 3; J 0; L 12 (3 words) → kana at 3/6/9: 0/0/0
    にゃ nya 1 app,mozc standard 3 -
    にぃ nyi 1 app,mozc ime none not compared, the identifier decides: in only with its own reason; lexicon words it lets spell: 7; J 0; L 24 (6 words) → kana at 3/6/9: 0/0/0
    にゅ nyu 1 app,mozc standard 3 -
    にぇ nye 1 app,mozc standard 3 -
    にょ nyo 1 app,mozc standard 3 -
    ひゃ hya 1 app,mozc standard 3 -
    ひぃ hyi 1 app,mozc ime none not compared, the identifier decides: in only with its own reason; lexicon words it lets spell: 0; J 0; L 0 (0 words)
    ひゅ hyu 1 app,mozc standard 3 -
    ひぇ hye 1 app,mozc standard 3 -
    ひょ hyo 1 app,mozc standard 3 -
    びゃ bya 1 app,mozc standard 3 -
    びぃ byi 1 app,mozc ime none not compared, the identifier decides: in only with its own reason; lexicon words it lets spell: 0; J 0; L 0 (0 words)
    びゅ byu 1 app,mozc standard 3 -
    びぇ bye 1 app,mozc standard 3 -
    びょ byo 1 app,mozc standard 3 -
    ぴゃ pya 1 app,mozc standard 3 -
    ぴぃ pyi 1 app,mozc ime none not compared, the identifier decides: in only with its own reason; lexicon words it lets spell: 2; J 0; L 8 (2 words) → kana at 3/6/9: 0/0/0
    ぴゅ pyu 1 app,mozc standard 3 -
    ぴぇ pye 1 app,mozc standard 3 -
    ぴょ pyo 1 app,mozc standard 3 -
    ふぁ fa 1 app,mozc standard 3 -
    ふぁ hwa 0 app,mozc ime none not compared, the identifier decides: in only with its own reason; lexicon words it lets spell: 1; J 0; L 4 (1 words) → kana at 3/6/9: 2/1/0
    ふぁ fwa 0 app ime 3 compared at 3: the one English word of the lexicon spelled with it stays letters (L); lexicon words it lets spell: 1; J 1 → kana at 3/6/9: 1/1/1; L 4 (1 words) → kana at 3/6/9: 0/0/0
    ふぃ fi 1 app,mozc standard 3 -
    ふぃ hwi 0 app,mozc ime 3 compared at 3: no English word of the lexicon is spelled with it; lexicon words it lets spell: 0; J 1 → kana at 3/6/9: 1/1/1; L 0 (0 words)
    ふぃ fwi 0 app ime 3 compared at 3: the one English word of the lexicon spelled with it stays letters (L); lexicon words it lets spell: 1; J 1 → kana at 3/6/9: 1/1/1; L 4 (1 words) → kana at 3/6/9: 0/0/0
    ふぅ fwu 1 app ime none not compared, the identifier decides: in only with its own reason; lexicon words it lets spell: 0; J 0; L 0 (0 words)
    ふぇ fe 1 app,mozc standard 3 -
    ふぇ hwe 0 app,mozc ime 3 compared at 3: no English word of the lexicon is spelled with it; lexicon words it lets spell: 0; J 0; L 0 (0 words)
    ふぇ fwe 0 app ime 3 compared at 3: no English word of the lexicon is spelled with it; lexicon words it lets spell: 0; J 0; L 0 (0 words)
    ふぉ fo 1 app,mozc standard 3 -
    ふぉ hwo 0 app,mozc ime 3 compared at 3: no English word of the lexicon is spelled with it; lexicon words it lets spell: 0; J 0; L 0 (0 words)
    ふぉ fwo 0 app ime 3 compared at 3: no English word of the lexicon is spelled with it; lexicon words it lets spell: 0; J 4 → kana at 3/6/9: 4/4/4; L 0 (0 words)
    ふゃ fya 1 app,mozc ime none not compared, the identifier decides: in only with its own reason; lexicon words it lets spell: 0; J 0; L 0 (0 words)
    ふゅ fyu 1 app,mozc standard 3 -
    ふょ fyo 1 app,mozc ime none not compared, the identifier decides: in only with its own reason; lexicon words it lets spell: 0; J 0; L 0 (0 words)
    みゃ mya 1 app,mozc standard 3 -
    みぃ myi 1 app,mozc ime none not compared, the identifier decides: in only with its own reason; lexicon words it lets spell: 0; J 0; L 0 (0 words)
    みゅ myu 1 app,mozc standard 3 -
    みぇ mye 1 app,mozc standard 3 -
    みょ myo 1 app,mozc standard 3 -
    りゃ rya 1 app,mozc standard 3 -
    りぃ ryi 1 app,mozc ime none not compared, the identifier decides: in only with its own reason; lexicon words it lets spell: 0; J 0; L 0 (0 words)
    りゅ ryu 1 app,mozc standard 3 -
    りぇ rye 1 app,mozc standard 3 -
    りょ ryo 1 app,mozc standard 3 -
    うぃ wi 1 app,mozc standard 3 -
    うぃ whi 0 app,mozc table none not compared: read by the input table only; lexicon words it lets spell: 23; J 0; L 91 (23 words) → kana at 3/6/9: 23/14/4
    うぇ we 1 app,mozc standard 3 -
    うぇ whe 0 app,mozc table none not compared: read by the input table only; lexicon words it lets spell: 28; J 0; L 111 (28 words) → kana at 3/6/9: 21/6/3
    うぁ wha 0 app,mozc table none not compared: read by the input table only; lexicon words it lets spell: 17; J 0; L 68 (17 words) → kana at 3/6/9: 4/0/0
    うぉ who 0 app,mozc table none not compared: read by the input table only; lexicon words it lets spell: 13; J 0; L 52 (13 words) → kana at 3/6/9: 5/1/0
    """
}
