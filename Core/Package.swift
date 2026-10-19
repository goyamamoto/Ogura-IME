// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

#if os(macOS)
let kanaKanjiConverterTraits: Set<Package.Dependency.Trait> = ["Zenzai"]
#else
// for testing in Ubuntu environment.
let kanaKanjiConverterTraits: Set<Package.Dependency.Trait> = []
#endif

let products: [Product] = [
    // Products define the executables and libraries a package produces, making them visible to other packages.
    .library(
        name: "Core",
        targets: ["Core"]
    ),
    .library(
        name: "ContinuationMLX",
        targets: ["ContinuationMLX"]
    )
]

let targets: [Target] = [
    .executableTarget(
        name: "git-info-generator"
    ),
    .plugin(
        name: "GitInfoPlugin",
        capability: .buildTool(),
        dependencies: [.target(name: "git-info-generator")]
    ),
    .target(
        name: "Core",
        dependencies: [
            .product(name: "SwiftUtils", package: "AzooKeyKanaKanjiConverter"),
            .product(name: "KanaKanjiConverterModuleWithDefaultDictionary", package: "AzooKeyKanaKanjiConverter")
        ],
        swiftSettings: [.interoperabilityMode(.Cxx)],
        plugins: [
            .plugin(name: "GitInfoPlugin")
        ]
    ),
    .testTarget(
        name: "CoreTests",
        // ContinuationMLX for the reading judge the Latin evaluation can add to the naturalness checks
        dependencies: ["Core", "ContinuationMLX"],
        swiftSettings: [.interoperabilityMode(.Cxx)]
    ),
    // MLX backend for 「続きを書く」 ("continue writing"), and the reading judge of the naturalness checks of Latin words
    // (CoreMLReadingJudge, Core ML). Apple Silicon only. Core's tests use it only in the Latin evaluation.
    .target(
        name: "ContinuationMLX",
        dependencies: [
            "Core",
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            .product(name: "Transformers", package: "swift-tokenizers")
        ],
        swiftSettings: [.interoperabilityMode(.Cxx)]
    )
]

let package = Package(
    name: "Core",
    platforms: [.macOS(.v14)],
    products: products,
    dependencies: [
        // A fork of azooKey/AzooKeyKanaKanjiConverter (ad714fe), branch ogura, with these additions: Zenzai's
        // log-probability of a reading (zenzaiInputLogProbability), for keeping natural Japanese
        // (SegmentsManager.keepingNaturalJapanese); a per-word flag that keeps a word out of the learning
        // (DicdataElementMetadata.isNotLearningTarget), for the forms made with F6-F10 (SegmentsManager.applyFunction);
        // flash attention off for models that need single precision, by GGUF metadata; scoring with a model other than
        // the conversion's (getScoringModel); choosing among whole candidates by probability and a thorough conversion
        // for committing (ZenzaiMode.thorough); a supplementary dictionary (supplementaryDictionaryURL); rendaku
        // lookups; and calling a conversion off while it runs (ZenzaiMode.Cancellation), for the thorough conversion made
        // in the background
        .package(url: "https://github.com/goyamamoto/AzooKeyKanaKanjiConverter", revision: "8fa550f12add182639a92419a40da78e93c9c913", traits: kanaKanjiConverterTraits),
        // Turn off the FoundationModelsIntegration trait because it requires the macOS 27 SDK
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.32.3", traits: []),
        // Use the same tokenizer implementation as the conversion engine (a minimal version of huggingface/swift-transformers). This avoids a clash between modules with the same name.
        .package(url: "https://github.com/ensan-hcl/swift-tokenizers", exact: "0.0.1")
    ],
    targets: targets
)
