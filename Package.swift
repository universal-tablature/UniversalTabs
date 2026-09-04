// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "UniversalTabs",
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
    ],

    products: [
        .library(name: "UniversalTabs", targets: ["UniversalTabs"]),
        .library(name: "UTABComposerCore", targets: ["UTABComposerCore"]),
        .library(name: "UTABInstruments", targets: ["UTABInstruments"]),
        .library(name: "UTABComposerDSL", targets: ["UTABComposerDSL"]),
        .library(name: "UTABComposerText", targets: ["UTABComposerText"]),
        .library(name: "UTABEditing", targets: ["UTABEditing"]),
        .library(name: "UTABInstrumentLibrary", targets: ["UTABInstrumentLibrary"]),
        .library(name: "UTABLowering", targets: ["UTABLowering"]),
        .library(name: "UTABAudio", targets: ["UTABAudio"]),
        .library(name: "UTABPitchDetection", targets: ["UTABPitchDetection"]),
        .library(name: "UTABNotation", targets: ["UTABNotation"]),
        .library(name: "UTABEngraving", targets: ["UTABEngraving"]),
        .library(name: "UTABScoreUI", targets: ["UTABScoreUI"]),
        .library(name: "UTABLanguageServer", targets: ["UTABLanguageServer"]),
        .executable(name: "utabc", targets: ["UTabCompiler"]),
        .executable(name: "utab-lsp", targets: ["UTabLanguageServerCommand"]),
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
        .target(name: "UTABInstruments", dependencies: ["UTABComposerCore"]),
        .target(name: "UTABComposerDSL", dependencies: ["UTABComposerCore", "UTABInstruments"]),
        .target(name: "UTABComposerText", dependencies: ["UTABComposerCore"]),
        .target(name: "UTABEditing", dependencies: ["UniversalTabs", "UTABComposerCore"]),
        .target(
            name: "UTABInstrumentLibrary",
            dependencies: ["UTABInstruments", "UTABComposerText", "UTABLowering"],
            resources: [.copy("Stdlib")]
        ),
        .target(name: "UTABLowering", dependencies: ["UniversalTabs", "UTABComposerCore", "UTABComposerText", "UTABInstruments"]),
        .target(
            name: "UTABAudio",
            linkerSettings: [.linkedFramework("AVFAudio", .when(platforms: [.iOS, .macOS]))]
        ),
        .target(name: "UTABPitchDetection", dependencies: ["UTABAudio"]),
        .target(name: "UTABNotation", dependencies: ["UniversalTabs"]),
        .target(name: "UTABEngraving", dependencies: ["UTABNotation"]),
        .target(name: "UTABScoreUI", dependencies: ["UniversalTabs", "UTABEditing", "UTABNotation", "UTABEngraving"]),
        .target(
            name: "UTABLanguageServer",
            dependencies: ["UniversalTabs", "UTABComposerCore", "UTABComposerText", "UTABInstrumentLibrary", "UTABLowering"]
        ),
        .executableTarget(name: "UTabCompiler", dependencies: ["UTABComposerText", "UTABInstrumentLibrary", "UTABLowering"]),
        .executableTarget(name: "UTabLanguageServerCommand", dependencies: ["UTABLanguageServer"]),
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
        .testTarget(name: "UTABEditingTests", dependencies: ["UTABEditing", "UTABComposerCore"]),
        .testTarget(name: "UTABScoreUITests", dependencies: ["UTABScoreUI", "UTABNotation", "UTABEngraving", "UniversalTabs"]),
        .testTarget(
            name: "UTABComposerTests",
            dependencies: ["UTABComposerCore", "UTABInstruments", "UTABComposerDSL", "UTABComposerText", "UTABInstrumentLibrary", "UTABLowering", "UniversalTabs"]
        ),
        .testTarget(name: "UTabCompilerIntegrationTests", dependencies: ["UTabCompiler"]),
        .testTarget(name: "UTABLanguageServerTests", dependencies: ["UTABLanguageServer"]),
        .testTarget(name: "UTABAudioTests", dependencies: ["UTABAudio", "UTABPitchDetection"])
    ]
)
