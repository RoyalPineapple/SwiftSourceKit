// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "SwiftSourceKit",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "SwiftSourceKit", targets: ["SwiftSourceKit"]),
        .executable(name: "SourceKitDProbe", targets: ["SourceKitDProbe"]),
    ],
    targets: [
        .target(
            name: "SwiftSourceKit",
            dependencies: ["CSourceKitDShim"],
            exclude: ["sourcekit-uid-provenance.txt"],
            swiftSettings: strictConcurrencySettings
        ),
        .target(
            name: "CSourceKitDShim"
        ),
        .executableTarget(
            name: "SourceKitDProbe",
            dependencies: ["SwiftSourceKit"],
            swiftSettings: strictConcurrencySettings
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
