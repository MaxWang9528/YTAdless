// swift-tools-version: 6.0
// Phase 0 contract (PLAN.md §4): frozen. Pure Swift only; never import UIKit, WebKit,
// AVFoundation, MediaPlayer, SwiftUI or CryptoKit here (D3).

import PackageDescription

let package = Package(
    name: "YTCore",
    platforms: [
        .iOS("26.0"),
    ],
    products: [
        .library(name: "YTCore", targets: ["YTCore"]),
        .library(name: "YTAssets", targets: ["YTAssets"]),
    ],
    targets: [
        .target(
            name: "YTCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "YTAssets",
            // `.copy` keeps the directory layout ("scripts/x.js"); `.process` would flatten it.
            resources: [
                .copy("manifest.json"),
                .copy("scripts"),
                .copy("rules"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "YTCoreTests",
            dependencies: ["YTCore", "YTAssets"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
