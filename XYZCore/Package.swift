// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "XYZCore",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "XYZCore", targets: ["XYZCore"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/swiftlang/swift-markdown.git",
            .upToNextMinor(from: "0.9.0")
        ),
    ],
    targets: [
        .target(
            name: "XYZCore",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown"),
            ]
        ),
        .testTarget(
            name: "XYZCoreTests",
            dependencies: [
                "XYZCore",
                .product(name: "Markdown", package: "swift-markdown"),
            ]
        ),
    ]
)
