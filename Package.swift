// swift-tools-version: 6.0
//
// PicshopKit — the modular engine behind Picshop.
//
// Layout
// ─────────────────────────────────────────────────────────────────────────────
//  PicshopCore     Pure Swift. Documents, layers, edit operations, history,
//                  video timeline model, intent taxonomy. Builds & tests on Linux.
//  PicshopIntent   Pure Swift natural-language → EditPlan parsing (FR/EN),
//                  plus the Apple Foundation Models engine (Apple platforms only).
//  PicshopImaging  Core Image / Vision / Metal / Core ML pipelines (Apple only).
//  PicshopVideo    AVFoundation composition, custom compositor, export (Apple only).
//  PicshopSpeech   SpeechAnalyzer (iOS 26) + SFSpeechRecognizer fallback (Apple only).
//  PicshopUI       SwiftUI design system + editor screens (Apple only).
//
// Apple-only targets compile to empty modules on Linux so `swift build` and
// `swift test` keep working for the platform-independent layers in CI.

import PackageDescription

let package = Package(
    name: "PicshopKit",
    defaultLocalization: "en",
    platforms: [
        .iOS("26.0"),
        .macOS("15.0"),
    ],
    products: [
        .library(name: "PicshopCore", targets: ["PicshopCore"]),
        .library(name: "PicshopIntent", targets: ["PicshopIntent"]),
        .library(name: "PicshopImaging", targets: ["PicshopImaging"]),
        .library(name: "PicshopVideo", targets: ["PicshopVideo"]),
        .library(name: "PicshopSpeech", targets: ["PicshopSpeech"]),
        .library(name: "PicshopUI", targets: ["PicshopUI"]),
    ],
    targets: [
        .target(
            name: "PicshopCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "PicshopIntent",
            dependencies: ["PicshopCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "PicshopImaging",
            dependencies: ["PicshopCore", "PicshopIntent"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "PicshopVideo",
            dependencies: ["PicshopCore", "PicshopIntent", "PicshopImaging"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "PicshopSpeech",
            dependencies: ["PicshopCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "PicshopUI",
            dependencies: [
                "PicshopCore", "PicshopIntent", "PicshopImaging", "PicshopVideo", "PicshopSpeech",
            ],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "PicshopCoreTests",
            dependencies: ["PicshopCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PicshopImagingTests",
            dependencies: ["PicshopImaging", "PicshopCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PicshopIntentTests",
            dependencies: ["PicshopIntent", "PicshopCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
