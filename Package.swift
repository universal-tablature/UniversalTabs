// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "UniversalTabs",
    products: [
        .library(name: "UniversalTabs", targets: ["UniversalTabs"]),
        .executable(name: "utab-midi", targets: ["UTabMIDI"])
    ],
    targets: [
        .target(name: "UniversalTabs"),
        .executableTarget(name: "UTabMIDI", dependencies: ["UniversalTabs"]),
        .testTarget(name: "UniversalTabsTests", dependencies: ["UniversalTabs"])
    ]
)
