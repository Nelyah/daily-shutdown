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
    targets: [
        .executableTarget(
            name: "DailyShutdown",
            path: "DailyShutdown",
            exclude: [],
            sources: [
                "main.swift",
                "Config.swift",
                "State.swift",
                "Policy.swift",
                "Scheduler.swift",
                "AlertPresenter.swift",
                "SystemActions.swift",
                "Logging.swift",
                "ShutdownController.swift",
                "UserPreferences.swift"
            ],
            resources: []
        ),
        .testTarget(
            name: "DailyShutdownTests",
            dependencies: ["DailyShutdown"],
            path: "Tests/DailyShutdownTests"
        )
    ]
)
