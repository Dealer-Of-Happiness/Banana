// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BananaAI",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "BananaAI",
            targets: ["BananaAI"]
        ),
    ],
    dependencies: [
        // llama.cpp Swift bindings for local LLM
        .package(url: "https://github.com/ggerganov/llama.cpp", branch: "master"),
        // SQLite for local storage
        .package(url: "https://github.com/groue/GRDB.swift", from: "6.24.0"),
    ],
    targets: [
        .target(
            name: "BananaAI",
            dependencies: [
                .product(name: "llama", package: "llama.cpp"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/BananaAI"
        ),
        .testTarget(
            name: "BananaAITests",
            dependencies: ["BananaAI"],
            path: "Tests/BananaAITests"
        ),
    ]
)
