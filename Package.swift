// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TinyLLMKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "TinyLLMKit", targets: ["TinyLLMKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-examples", from: "2.21.2"),
    ],
    targets: [
        .target(
            name: "TinyLLMKit",
            dependencies: [
                .product(name: "MLXLLM", package: "mlx-swift-examples"),
                .product(name: "MLXLMCommon", package: "mlx-swift-examples"),
            ]
        ),
        .testTarget(name: "TinyLLMKitTests", dependencies: ["TinyLLMKit"]),
    ]
)
