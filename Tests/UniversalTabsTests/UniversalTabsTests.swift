import Foundation
import Testing
@testable import UniversalTabs

@Test func parsesNamedPitches() {
    #expect(Pitch.midiNote("C4") == 60)
    #expect(Pitch.midiNote("F#3") == 54)
    #expect(Pitch.midiNote("Bb2") == 46)
    #expect(Pitch.midiNote("not-a-pitch") == nil)
}

@Test func writesStandardMIDIHeader() {
    let data = StandardMIDIFile.make(conductor: [], tracks: [[]])
    #expect(String(data: data.prefix(4), encoding: .ascii) == "MThd")
    #expect(data.count >= 26)
}

@Test func convertsMinimalDocument() throws {
    let json = #"{"utab":{"version":"0.1-draft"},"setup":{"profiles":[{"id":"p","name":"Xylophone","actuators":{"bars":{"members":[{"id":"c","pitch":"C4"}]}},"interactions":{"strike":{}}}],"instruments":[{"id":"i","profile":"p"}]},"tracks":[{"id":"t","instrument":"i","events":[{"at":{"musical":{"measure":1,"beat":1}},"action":"strike","target":"c"}]}]}"#
    let result = try UTabMIDIConverter().convert(data: Data(json.utf8))
    #expect(result.midi.starts(with: Data("MThd".utf8)))
    #expect(result.diagnostics.isEmpty)
}

@Test func decodesAllDraftExamplesIntoTypedModels() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let examples = repositoryRoot.appendingPathComponent("Examples")
    let files = try FileManager.default.contentsOfDirectory(at: examples, includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.hasSuffix(".utab.json") }

    #expect(files.count == 7)
    for file in files {
        let document = try JSONDecoder().decode(UTabDocument.self, from: Data(contentsOf: file))
        #expect(!document.utab.version.isEmpty)
        #expect(!document.setup.instruments.isEmpty)
        #expect(!document.tracks.isEmpty)
        #expect(UTabValidator().validate(document).isEmpty)
    }
}

@Test func semanticValidatorReportsBrokenReferencesAndTargets() throws {
    let json = #"{"utab":{"version":"0.1-draft"},"setup":{"profiles":[{"id":"p","actuators":{"strings":{"count":1}},"interactions":{"pluck":{}}}],"instruments":[{"id":"i","profile":"p"}]},"tracks":[{"id":"t","instrument":"i","events":[{"at":{"musical":{"measure":1,"beat":1}},"action":"pluck","target":"strings[2]"},{"at":{"musical":{"measure":1,"beat":1}},"action":"unknown","target":"strings[1]"}]}]}"#
    let document = try JSONDecoder().decode(UTabDocument.self, from: Data(json.utf8))
    let diagnostics = UTabValidator().validate(document)
    #expect(diagnostics.count == 2)
    #expect(diagnostics.allSatisfy { $0.severity == .error })
}

@Test func expandsRepeatedSectionsAndEntrySpecificParts() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let example = repositoryRoot
        .appendingPathComponent("Examples")
        .appendingPathComponent("sectioned-song.utab.json")
    let result = try UTabMIDIConverter().convert(data: Data(contentsOf: example))

    #expect(result.diagnostics.isEmpty)
    #expect(result.midi.filter { $0 == 0x90 }.count == 4)
    #expect(result.midi.filter { $0 == 0x91 }.count == 4)
}
