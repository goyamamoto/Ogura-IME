import Foundation

/// A model trained to tell the reading of typed keys the user meant from the other readings of the same keys (Japanese
/// in kana, Latin words as typed: tokenをおくって against とけんをおくって, みねにのぼる against mineにのぼる), for the
/// naturalness checks of Latin words (see `SegmentsManager.keepingNaturalJapanese`). Unlike Zenzai, which scores how
/// likely a reading is as Japanese input, it has learned which Latin words people write as letters in Japanese
public protocol ReadingJudge: AnyObject {
    /// A score for each of `readings`, in natural log: a higher score, a likelier reading. Nil when it cannot score them
    func scores(of readings: [String]) -> [Float]?
}
