// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SiriPlusCore",
    platforms: [.macOS(.v26)],
    products: [.library(name: "SiriPlusCore", targets: ["SiriPlusCore"])],
    targets: [
        .target(
            name: "SiriPlusCore",
            path: "SiriPlus",
            exclude: ["Features", "Intents", "App/SiriPlusApp.swift", "Resources"]
        ),
        .testTarget(name: "SiriPlusCoreTests", dependencies: ["SiriPlusCore"], path: "Tests")
    ]
)
