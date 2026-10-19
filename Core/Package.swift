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
        dependencies: ["Core"],
        swiftSettings: [.interoperabilityMode(.Cxx)]
    ),
    // MLX backend for 「続きを書く」 ("continue writing"). Apple Silicon only. Core's own tests do not use it.
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
        // A fork of azooKey/AzooKeyKanaKanjiConverter (ad714fe) with one addition: Zenzai's log-probability of a
        // reading (zenzaiInputLogProbability), for keeping natural Japanese (SegmentsManager.keepingNaturalJapanese)
        .package(url: "https://github.com/goyamamoto/AzooKeyKanaKanjiConverter", revision: "cd3cd71af9cd6e10de9dc9f9b0b7d98a5649ab88", traits: kanaKanjiConverterTraits),
        // Turn off the FoundationModelsIntegration trait because it requires the macOS 27 SDK
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.32.3", traits: []),
        // Use the same tokenizer implementation as the conversion engine (a minimal version of huggingface/swift-transformers). This avoids a clash between modules with the same name.
        .package(url: "https://github.com/ensan-hcl/swift-tokenizers", exact: "0.0.1")
    ],
    targets: targets
)
