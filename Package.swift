// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "UniversalTabs",
    products: [
        .library(name: "UniversalTabs", targets: ["UniversalTabs"]),
        .library(name: "UTABComposerCore", targets: ["UTABComposerCore"]),
        .library(name: "UTABComposerDSL", targets: ["UTABComposerDSL"]),
        .executable(name: "utab-midi", targets: ["UTabMIDI"]),
        .executable(name: "utab-musicxml", targets: ["UTabMusicXML"]),
        .executable(name: "utab-pdmx-index", targets: ["UTabPDMXIndex"]),
        .executable(name: "utab-pdmx-import", targets: ["UTabPDMXImport"])
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", .upToNextMajor(from: "0.9.0"))
    ],
    targets: [
        .target(name: "UniversalTabs"),
        .target(name: "UTABComposerCore"),
        .target(name: "UTABComposerDSL", dependencies: ["UTABComposerCore"]),
        .executableTarget(name: "UTabMIDI", dependencies: ["UniversalTabs"]),
        .executableTarget(name: "UTabMusicXML", dependencies: ["UniversalTabs"]),
        .executableTarget(name: "UTabPDMXIndex", dependencies: [
            "UniversalTabs",
            .product(name: "ZIPFoundation", package: "ZIPFoundation")
        ]),
        .executableTarget(name: "UTabPDMXImport", dependencies: [
            "UniversalTabs",
            .product(name: "ZIPFoundation", package: "ZIPFoundation")
        ]),
        .testTarget(name: "UniversalTabsTests", dependencies: ["UniversalTabs"]),
        .testTarget(
            name: "UTABComposerTests",
            dependencies: ["UTABComposerCore", "UTABComposerDSL"]
        )
    ]
)
