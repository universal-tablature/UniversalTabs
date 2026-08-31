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
