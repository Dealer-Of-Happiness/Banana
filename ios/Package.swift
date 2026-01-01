// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DOHAI",
    platforms: [
        .iOS(.v17),
        .watchOS(.v10),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "DOHAI",
            targets: ["DOHAI"]
        ),
    ],
    dependencies: [
        // llama.cpp Swift bindings for local LLM
        .package(url: "https://github.com/ggerganov/llama.cpp", branch: "master"),
        // SQLite for local storage (SwiftData alternative)
        .package(url: "https://github.com/groue/GRDB.swift", from: "6.24.0"),
    ],
    targets: [
        .target(
            name: "DOHAI",
            dependencies: [
                .product(name: "llama", package: "llama.cpp"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/DOHAI"
        ),
        .target(
            name: "DOHAIWidgets",
            dependencies: ["DOHAI"],
            path: "Sources/DOHAIWidgets"
        ),
        .target(
            name: "DOHAIWatch",
            dependencies: [],
            path: "Sources/DOHAIWatch"
        ),
    ]
)
