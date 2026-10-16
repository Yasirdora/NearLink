// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "NearLink",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
        .tvOS(.v18),
        .visionOS(.v2)
    ],
    products: [
        .library(name: "NearLink", targets: ["NearLink"])
    ],
    targets: [
        .target(name: "NearLink"),
        .testTarget(name: "NearLinkTests", dependencies: ["NearLink"])
    ]
)
