// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ScrollRubberbandFix",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "ScrollRubberbandFix",
            targets: ["ScrollRubberbandFix"]
        )
    ],
    targets: [
        .target(
            name: "ScrollRubberbandFix"
        ),
        .testTarget(
            name: "ScrollRubberbandFixTests",
            dependencies: ["ScrollRubberbandFix"]
        )
    ],
    swiftLanguageModes: [.v6]
)
