// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "SoccerShots",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "SoccerShots", targets: ["SoccerShots"])
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "3.31.3"),
        .package(url: "https://github.com/huggingface/swift-huggingface.git", exact: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers.git", exact: "1.3.0")
    ],
    targets: [
        .executableTarget(
            name: "SoccerShots",
            dependencies: [
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers")
            ],
            path: "Sources/SoccerShots"
        ),
        .testTarget(
            name: "SoccerShotsTests",
            dependencies: ["SoccerShots"],
            path: "Tests/SoccerShotsTests"
        )
    ]
)
