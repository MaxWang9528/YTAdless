// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "YTadless",
    platforms: [
        .iOS("26.0"),
    ],
    products: [
        .library(name: "YTadless", targets: ["YTadless"]),
    ],
    dependencies: [
        .package(path: "Core"),
    ],
    targets: [
        .target(
            name: "YTadless",
            dependencies: [
                .product(name: "YTCore", package: "Core"),
                .product(name: "YTAssets", package: "Core"),
            ]
        ),
    ]
)
