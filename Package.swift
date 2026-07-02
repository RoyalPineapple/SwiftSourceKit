// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "SwiftSourceKit",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "SwiftSourceKit", targets: ["SwiftSourceKit"]),
    ],
    targets: [
        .target(
            name: "SwiftSourceKit",
            dependencies: ["CSourceKitDShim"],
            swiftSettings: strictConcurrencySettings
        ),
        .target(
            name: "CSourceKitDShim"
        ),
        .testTarget(
            name: "SwiftSourceKitTests",
            dependencies: ["SwiftSourceKit"],
            swiftSettings: strictConcurrencySettings
        ),
    ]
)

let strictConcurrencySettings: [SwiftSetting] = [
    .enableUpcomingFeature("StrictConcurrency"),
    .enableUpcomingFeature("InferSendableFromCaptures"),
]
