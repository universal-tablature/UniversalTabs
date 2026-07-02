// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "UniversalTabs",
    products: [
        .library(name: "UniversalTabs", targets: ["UniversalTabs"]),
        .executable(name: "utab-midi", targets: ["UTabMIDI"]),
        .executable(name: "utab-musicxml", targets: ["UTabMusicXML"]),
        .executable(name: "utab-pdmx-index", targets: ["UTabPDMXIndex"])
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", .upToNextMajor(from: "0.9.0"))
    ],
    targets: [
        .target(name: "UniversalTabs"),
        .executableTarget(name: "UTabMIDI", dependencies: ["UniversalTabs"]),
        .executableTarget(name: "UTabMusicXML", dependencies: ["UniversalTabs"]),
        .executableTarget(name: "UTabPDMXIndex", dependencies: [
            "UniversalTabs",
            .product(name: "ZIPFoundation", package: "ZIPFoundation")
        ]),
        .testTarget(name: "UniversalTabsTests", dependencies: ["UniversalTabs"])
    ]
)
