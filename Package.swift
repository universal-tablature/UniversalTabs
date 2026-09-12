// swift-tools-version: 6.0
// Copyright 2026 Mattias Holm
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import PackageDescription

var products: [Product] = [
    .library(name: "UniversalTabs", targets: ["UniversalTabs"]),
    .library(name: "UTABComposerCore", targets: ["UTABComposerCore"]),
    .library(name: "UTABInstruments", targets: ["UTABInstruments"]),
    .library(name: "UTABComposerDSL", targets: ["UTABComposerDSL"]),
    .library(name: "UTABComposerText", targets: ["UTABComposerText"]),
    .library(name: "UTABEditing", targets: ["UTABEditing"]),
    .library(name: "UTABInstrumentLibrary", targets: ["UTABInstrumentLibrary"]),
    .library(name: "UTABLowering", targets: ["UTABLowering"]),
    .library(name: "UTABNotation", targets: ["UTABNotation"]),
    .library(name: "UTABEngraving", targets: ["UTABEngraving"]),
    .library(name: "UTABLanguageServer", targets: ["UTABLanguageServer"]),
    .executable(name: "utabc", targets: ["UTabCompiler"]),
    .executable(name: "utab-lsp", targets: ["UTabLanguageServerCommand"]),
    .executable(name: "utab-midi", targets: ["UTabMIDI"]),
    .executable(name: "utab-musicxml", targets: ["UTabMusicXML"]),
    .executable(name: "utab-lilypond", targets: ["UTabLilyPond"]),
    .executable(name: "utab-mei", targets: ["UTabMEI"]),
]

var dependencies: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-argument-parser", .upToNextMajor(from: "1.8.2")),
]

var targets: [Target] = [
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
    .target(name: "UTABNotation", dependencies: ["UniversalTabs"]),
    .target(name: "UTABEngraving", dependencies: ["UTABNotation"]),
    .target(
        name: "UTABLanguageServer",
        dependencies: ["UniversalTabs", "UTABComposerCore", "UTABComposerText", "UTABInstrumentLibrary", "UTABLowering"]
    ),
    .executableTarget(name: "UTabCompiler", dependencies: ["UTABComposerText", "UTABInstrumentLibrary", "UTABLowering"]),
    .executableTarget(name: "UTabLanguageServerCommand", dependencies: ["UTABLanguageServer"]),
    .executableTarget(name: "UTabMIDI", dependencies: ["UniversalTabs"]),
    .executableTarget(name: "UTabMusicXML", dependencies: ["UniversalTabs"]),
    .executableTarget(name: "UTabLilyPond", dependencies: [
        "UniversalTabs",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
    ]),
    .executableTarget(name: "UTabMEI", dependencies: [
        "UniversalTabs",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
    ]),
    .testTarget(name: "UniversalTabsTests", dependencies: ["UniversalTabs"]),
    .testTarget(name: "UTABEditingTests", dependencies: ["UTABEditing", "UTABComposerCore"]),
    .testTarget(
        name: "UTABComposerTests",
        dependencies: ["UTABComposerCore", "UTABInstruments", "UTABComposerDSL", "UTABComposerText", "UTABInstrumentLibrary", "UTABLowering", "UniversalTabs"]
    ),
    .testTarget(name: "UTabCompilerIntegrationTests", dependencies: ["UTabCompiler"]),
    .testTarget(name: "UTABLanguageServerTests", dependencies: ["UTABLanguageServer"]),
]

#if !os(Windows)
    products += [
    .executable(name: "utab-pdmx-index", targets: ["UTabPDMXIndex"]),
	    .executable(name: "utab-pdmx-import", targets: ["UTabPDMXImport"]),
	    .executable(name: "utab-pdmx-validate", targets: ["UTabPDMXValidate"]),
]
dependencies.append(
    .package(url: "https://github.com/weichsel/ZIPFoundation.git", .upToNextMajor(from: "0.9.0"))
)
targets += [
    .executableTarget(name: "UTabPDMXIndex", dependencies: [
        "UniversalTabs",
        .product(name: "ZIPFoundation", package: "ZIPFoundation"),
    ]),
    .executableTarget(name: "UTabPDMXImport", dependencies: [
        "UniversalTabs",
        .product(name: "ZIPFoundation", package: "ZIPFoundation"),
    ]),
    .executableTarget(name: "UTabPDMXValidate", dependencies: [
        "UniversalTabs",
        .product(name: "ZIPFoundation", package: "ZIPFoundation"),
    ]),
]
#endif

let package = Package(
    name: "UniversalTabs",
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
    ],

    products: products,
    dependencies: dependencies,
    targets: targets
)
