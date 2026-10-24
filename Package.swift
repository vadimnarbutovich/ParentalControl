// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ParentalControlLogic",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ParentalControlLogic", targets: ["ParentalControlLogic"])
    ],
    targets: [
        .target(
            name: "ParentalControlLogic",
            path: "ParentalControl",
            sources: [
                "Models/AppModels.swift",
                "Localization/L10n.swift"
            ]
        ),
        .testTarget(
            name: "ParentalControlLogicTests",
            dependencies: ["ParentalControlLogic"],
            path: "Tests/ParentalControlLogicTests"
        )
    ]
)
