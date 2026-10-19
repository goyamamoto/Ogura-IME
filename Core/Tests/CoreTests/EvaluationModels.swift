import Core
import Foundation

/// The Zenzai models and the supplementary dictionary an evaluation converts with: by default those the app ships, when
/// they are built in the repository (genmai as Config.ZenzaiModel chooses, see Tools/build_genmai_gguf.sh, and the
/// supplementary dictionary, see Tools/build_supplement_dictionary.sh), else zenz-v3.2-small and no supplement. The app
/// finds them in its resources directory, next to zenz-v3.2-small; the repository keeps zenz-v3.2-small alone in
/// Ogura/Resources/gguf, so the evaluations name them to SegmentsManager.
/// - `OGURA_ZENZAI_WEIGHT=<file>` converts with those Zenzai weights (a model in GGUF)
/// - `OGURA_ZENZAI_CHECK_WEIGHT=<file>` has the naturalness checks score readings with those weights instead of
///   zenz-v3.2-small's (see `SegmentsManager.zenzaiCheckWeightURL`)
/// - `OGURA_SUPPLEMENT_DIR=<dir>` uses the supplementary dictionary there
/// - `OGURA_ZENZAI_SECOND_OPINION=0` commits without the checks' model scoring the candidates too (see
///   `SegmentsManager.zenzaiSecondOpinion`); `OGURA_ZENZAI_SECOND_WEIGHT_RATIO=<λ>` sets how much it counts and
///   `OGURA_ZENZAI_SECOND_THRESHOLD=<T>` from what preference it is heard
struct EvaluationModels {
    /// Where zenz-v3.2-small is (`SegmentsManager.Context.resourcesDirectoryURL`)
    let resourcesDirectoryURL: URL
    /// Whether zenz-v3.2-small's weights are there: an LFS pointer, or a tree exported without them, has none
    let hasZenzai: Bool
    let zenzaiWeightURL: URL?
    let zenzaiCheckWeightURL: URL?
    let supplementaryDictionaryURL: URL?
    let zenzaiSecondOpinion: Bool
    let zenzaiSecondOpinionWeight: Float?
    let zenzaiSecondOpinionThreshold: Float?

    init(repository: URL, environment: [String: String]) {
        let resources = repository.appendingPathComponent("Ogura/Resources", isDirectory: true)
        self.resourcesDirectoryURL = resources.appendingPathComponent("gguf", isDirectory: true)
        let zenz = self.resourcesDirectoryURL.appendingPathComponent("ggml-model-Q5_K_M.gguf", isDirectory: false)
        self.hasZenzai = ((try? FileManager.default.attributesOfItem(atPath: zenz.path)[.size] as? Int) ?? 0) > 1_000_000
        let genmai = resources.appendingPathComponent("genmai/ggml-model-Q5_K_M.gguf", isDirectory: false)
        self.zenzaiWeightURL = environment["OGURA_ZENZAI_WEIGHT"].map { URL(fileURLWithPath: $0) }
            ?? (Config.ZenzaiModel().value == .genmai && FileManager.default.fileExists(atPath: genmai.path) ? genmai : nil)
        self.zenzaiCheckWeightURL = environment["OGURA_ZENZAI_CHECK_WEIGHT"].map { URL(fileURLWithPath: $0) }
        let supplement = resources.appendingPathComponent("Dictionary/supplement", isDirectory: true)
        self.supplementaryDictionaryURL = environment["OGURA_SUPPLEMENT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? (FileManager.default.fileExists(atPath: supplement.appendingPathComponent("supplement.louds").path) ? supplement : nil)
        self.zenzaiSecondOpinion = environment["OGURA_ZENZAI_SECOND_OPINION"] != "0"
        self.zenzaiSecondOpinionWeight = environment["OGURA_ZENZAI_SECOND_WEIGHT_RATIO"].flatMap(Float.init)
        self.zenzaiSecondOpinionThreshold = environment["OGURA_ZENZAI_SECOND_THRESHOLD"].flatMap(Float.init)
    }

    /// What a report's first line says about them
    var description: String {
        "weights=\(self.zenzaiWeightURL?.path ?? "zenz-v3.2-small") check weights=\(self.zenzaiCheckWeightURL?.path ?? "zenz-v3.2-small") "
            + "supplement=\(self.supplementaryDictionaryURL?.path ?? "none") "
            + "second opinion=\(self.zenzaiSecondOpinion ? "λ \(self.zenzaiSecondOpinionWeight ?? SegmentsManager.secondOpinionWeight) T \(self.zenzaiSecondOpinionThreshold ?? SegmentsManager.secondOpinionThreshold)" : "off")"
    }
}
