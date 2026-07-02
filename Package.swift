// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "UniversalTabs",
    products: [
        .library(name: "UniversalTabs", targets: ["UniversalTabs"]),
        .executable(name: "utab-midi", targets: ["UTabMIDI"]),
        .executable(name: "utab-musicxml", targets: ["UTabMusicXML"])
    ],
    targets: [
        .target(name: "UniversalTabs"),
        .executableTarget(name: "UTabMIDI", dependencies: ["UniversalTabs"]),
        .executableTarget(name: "UTabMusicXML", dependencies: ["UniversalTabs"]),
        .testTarget(name: "UniversalTabsTests", dependencies: ["UniversalTabs"])
    ]
)
