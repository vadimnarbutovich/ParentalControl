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
                "Models/BodyJoints.swift",
                "Localization/L10n.swift",
                "Services/RewardEngine.swift",
                "Services/ExerciseRepCounter.swift"
            ]
        ),
        .testTarget(
            name: "ParentalControlLogicTests",
            dependencies: ["ParentalControlLogic"],
            path: "Tests/ParentalControlLogicTests"
        )
    ]
)
