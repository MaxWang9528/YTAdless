// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "YTadless",
    platforms: [
        .iOS("26.0"),
    ],
    products: [
        // An xtool project contains exactly one library product: the app.
        .library(
            name: "YTadless",
            targets: ["YTadless"]
        ),
    ],
    targets: [
        .target(
            name: "YTadless"
        ),
    ]
)
