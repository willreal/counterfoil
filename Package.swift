// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CounterfoilCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CounterfoilCore", targets: ["CounterfoilCore"]),
    ],
    targets: [
        .target(
            name: "CounterfoilCore",
            path: "Sources",
            exclude: [
                "App.swift",
                "CaptureManager.swift",
                "SettingsStore.swift",
                "Transcribe.swift",
                "TranscriptStore.swift",
                "Views.swift",
            ],
            sources: ["RecordingModels.swift", "RecordingReliability.swift"]
        ),
        .testTarget(
            name: "CounterfoilCoreTests",
            dependencies: ["CounterfoilCore"],
            path: "Tests/CounterfoilCoreTests",
            swiftSettings: [
                .unsafeFlags([
                    "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                ]),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-framework", "Testing",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                ]),
            ]
        ),
        .executableTarget(
            name: "CounterfoilCoreVerification",
            dependencies: ["CounterfoilCore"],
            path: "Verification",
            exclude: [
                "RecordingPanelPreview.swift",
                "RecordingPanelPreviewInfo.plist",
            ],
            sources: ["main.swift"]
        ),
    ]
)
