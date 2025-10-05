// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DailyShutdown",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "DailyShutdown", targets: ["DailyShutdown"]) // Provides the main entry point
    ],
    dependencies: [
        .package(url: "https://github.com/dduan/TOMLDecoder.git", from: "0.2.0")
    ],
    targets: [
        .executableTarget(
            name: "DailyShutdown",
            dependencies: [
                .product(name: "TOMLDecoder", package: "TOMLDecoder")
            ],
            path: "DailyShutdown",
            exclude: [],
            sources: [
                "main.swift",
                "Config.swift",
                "ConfigFile.swift",
                "State.swift",
                "Policy.swift",
                "Scheduler.swift",
                "AlertPresenter.swift",
                "SystemActions.swift",
                "Logging.swift",
                "ShutdownController.swift",
                "UserPreferences.swift",
                "Installer.swift"
            ],
            resources: []
        ),
        .testTarget(
            name: "DailyShutdownTests",
            dependencies: ["DailyShutdown", .product(name: "TOMLDecoder", package: "TOMLDecoder")],
            path: "Tests/DailyShutdownTests"
        )
    ]
)
