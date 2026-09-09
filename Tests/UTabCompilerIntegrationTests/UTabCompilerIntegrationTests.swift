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

import Foundation
import Testing
@testable import UTabCompiler

@Test func looseTwinkleFixtureProducesDeterministicJSONAndMIDI() throws {
    let fixture = fixturesDirectory.appendingPathComponent("twinkle.utab")
    let firstDirectory = try temporaryDirectory()
    let secondDirectory = try temporaryDirectory()
    defer {
        try? FileManager.default.removeItem(at: firstDirectory)
        try? FileManager.default.removeItem(at: secondDirectory)
    }

    let firstJSON = firstDirectory.appendingPathComponent("twinkle.utab.json")
    let secondJSON = secondDirectory.appendingPathComponent("twinkle.utab.json")
    let firstMIDI = firstDirectory.appendingPathComponent("twinkle.mid")
    let secondMIDI = secondDirectory.appendingPathComponent("twinkle.mid")

    try UTabCompilerCommand.execute(["--emit", "utab-json", fixture.path, "-o", firstJSON.path])
    try UTabCompilerCommand.execute(["--emit", "utab-json", fixture.path, "-o", secondJSON.path])
    try UTabCompilerCommand.execute(["--emit", "midi", fixture.path, "-o", firstMIDI.path])
    try UTabCompilerCommand.execute(["--emit", "midi", fixture.path, "-o", secondMIDI.path])

    #expect(try Data(contentsOf: firstJSON) == Data(contentsOf: secondJSON))
    #expect(try Data(contentsOf: firstMIDI) == Data(contentsOf: secondMIDI))
    #expect(try Data(contentsOf: firstMIDI).prefix(4) == Data("MThd".utf8))
    let json = try String(contentsOf: firstJSON, encoding: .utf8)
    let escapedRepositoryPath = fixturesDirectory
        .deletingLastPathComponent()
        .path
        .replacingOccurrences(of: "/", with: "\\/")
    #expect(!json.contains(escapedRepositoryPath))
    #expect(json.contains("Tests\\/LanguageFixtures\\/twinkle.utab") || json.contains("twinkle.utab"))
}

@Test func looseDiagnosticFixtureSelfVerifiesThroughCLI() throws {
    try UTabCompilerCommand.execute(["--verify", fixturesDirectory.appendingPathComponent("expected-error.utab").path])
}

@Test func mismatchedLooseDiagnosticFixtureFailsVerification() {
    #expect(throws: UTabCompilerCommand.CompilationFailure.self) {
        try UTabCompilerCommand.execute(["--verify", fixturesDirectory.appendingPathComponent("mismatched-error.utab").path])
    }
}

private let fixturesDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("LanguageFixtures", isDirectory: true)

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
