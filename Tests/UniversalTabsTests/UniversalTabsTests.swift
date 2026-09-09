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
@testable import UniversalTabs

@Test func parsesNamedPitches() {
    #expect(Pitch.midiNote("C4") == 60)
    #expect(Pitch.midiNote("F#3") == 54)
    #expect(Pitch.midiNote("Bb2") == 46)
    #expect(Pitch.midiNote("not-a-pitch") == nil)
}

@Test func parsesCanonicalActuatorTargets() throws {
    #expect(try ActuatorTarget(parsing: "strings").selector == nil)
    #expect(try ActuatorTarget(parsing: "strings[2]").selector == .index(2))
    #expect(try ActuatorTarget(parsing: "strings[1..5]").selector == .range(1...5))
    #expect(try ActuatorTarget(parsing: "toneFields[\"ding\"]").selector == .member("ding"))
    #expect(try ActuatorTarget(parsing: "manuals.upper.keys[3]").groupPath == "manuals.upper.keys")
    #expect(throws: ActuatorTargetError.self) { try ActuatorTarget(parsing: "strings[0]") }
    #expect(throws: ActuatorTargetError.self) { try ActuatorTarget(parsing: "strings[5..1]") }
    #expect(throws: ActuatorTargetError.self) { try ActuatorTarget(parsing: "ding field") }
}

@Test func writesStandardMIDIHeader() {
    let data = StandardMIDIFile.make(conductor: [], tracks: [[]])
    #expect(String(data: data.prefix(4), encoding: .ascii) == "MThd")
    #expect(data.count >= 26)
}

@Test func convertsMinimalDocument() throws {
    let json = #"{"utab":{"version":"0.1-draft"},"setup":{"profiles":[{"id":"p","name":"Xylophone","actuators":{"bars":{"members":[{"id":"c","pitch":"C4"}]}},"interactions":{"strike":{}}}],"instruments":[{"id":"i","profile":"p"}]},"tracks":[{"id":"t","instrument":"i","events":[{"at":{"musical":{"measure":1,"beat":1}},"action":"strike","target":"bars[\"c\"]"}]}]}"#
    let result = try UTabMIDIConverter().convert(data: Data(json.utf8))
    #expect(result.midi.starts(with: Data("MThd".utf8)))
    #expect(result.diagnostics.isEmpty)
}

@Test func convertsUsingTypedMIDIRealizationInsteadOfProfileName() throws {
    let json = #"{"utab":{"version":"0.1-draft"},"setup":{"profiles":[{"id":"p","name":"Misleading Guitar Name","actuators":{"bars":{"members":[{"id":"c","pitch":"C4"}]}},"interactions":{"strike":{}}}],"instruments":[{"id":"i","profile":"p","realization":{"midi":{"program":41}}}]},"tracks":[{"id":"t","instrument":"i","events":[{"at":{"musical":{"measure":1,"beat":1}},"action":"strike","target":"bars[\"c\"]"}]}]}"#
    let result = try UTabMIDIConverter().convert(data: Data(json.utf8))

    let bytes = Array(result.midi)
    #expect(bytes.indices.dropLast().contains { bytes[$0] == 0xC0 && bytes[$0 + 1] == 40 })
}

@Test func convertsCanonicalDrumKitPlayingSurfaceTargets() throws {
    let json = #"{"utab":{"version":"0.1-draft"},"setup":{"profiles":[{"id":"drums","actuators":{"playingSurfaces":{"members":[{"id":"kick"},{"id":"snare-head"}]}},"interactions":{"strike":{"targets":["playingSurfaces"]}}}],"instruments":[{"id":"kit","profile":"drums","realization":{"midi":{"percussion":true}}}]},"tracks":[{"id":"groove","instrument":"kit","events":[{"at":{"musical":{"measure":1,"beat":1}},"action":"strike","target":"playingSurfaces[\"kick\"]"},{"at":{"musical":{"measure":1,"beat":2}},"action":"strike","target":"playingSurfaces[\"snare-head\"]"}]}]}"#
    let result = try UTabMIDIConverter().convert(data: Data(json.utf8))

    #expect(result.diagnostics.isEmpty)
    let bytes = Array(result.midi)
    #expect(bytes.contains(36))
    #expect(bytes.contains(38))
}

@Test func convertsGenericFrequencyBasedPlayEvents() throws {
    let json = #"{"utab":{"version":"0.1-draft"},"setup":{"time":{"tempo":{"quarterNotesPerMinute":60}},"profiles":[{"id":"fretless","actuators":{"notes":{"minimumCount":1}},"interactions":{"play":{"targets":["notes"]}}}],"instruments":[{"id":"oud","profile":"fretless"}]},"tracks":[{"id":"melody","instrument":"oud","events":[{"at":{"musical":{"measure":1,"beat":1}},"duration":{"quarterNotes":"4/1"},"action":"play","target":"notes","parameters":{"pitch":{"frequencyHz":452.892984}}}]}]}"#
    let result = try UTabMIDIConverter().convert(data: Data(json.utf8))

    #expect(result.diagnostics.isEmpty)
    let bytes = Array(result.midi)
    #expect(bytes.contains(69) || bytes.contains(70))
    #expect(bytes.contains { $0 & 0xF0 == 0xE0 })
    #expect(result.midi.count > 60)
}

@Test func convertsKeyboardPressEventsWithTheirAuthoredDuration() throws {
    let json = #"{"utab":{"version":"0.1-draft"},"setup":{"time":{"tempo":{"quarterNotesPerMinute":60}},"profiles":[{"id":"keyboard","actuators":{"keys":{"count":88}},"interactions":{"press":{"targets":["keys"]}}}],"instruments":[{"id":"piano","profile":"keyboard"}]},"tracks":[{"id":"melody","instrument":"piano","events":[{"at":{"musical":{"measure":1,"beat":1}},"duration":{"quarterNotes":"4/1"},"action":"press","target":"keys[40]","parameters":{"pitch":"C4"}}]}]}"#
    let result = try UTabMIDIConverter().convert(data: Data(json.utf8))

    #expect(result.diagnostics.isEmpty)
    let bytes = Array(result.midi)
    #expect(bytes.contains { $0 & 0xF0 == 0x90 })
    #expect(bytes.contains { $0 & 0xF0 == 0x80 })
    #expect(result.midi.count > 60)
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

@Test func importsAndExportsSimpleMusicXMLTab() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let fixture = root.appendingPathComponent("Tests/Fixtures/simple-tab.musicxml")
    let imported = try MusicXMLInterchange.importDocument(Data(contentsOf: fixture))
    let document = try JSONDecoder().decode(UTabDocument.self, from: imported.data)
    #expect(document.tracks.count == 1)
    #expect(document.tracks[0].events?.count == 2)
    #expect(document.utab.title == "Prelude")
    #expect(document.utab.work?.title == "Tab Studies")
    #expect(document.utab.work?.number == "Op. 1")
    #expect(document.utab.movement?.number == "1")
    #expect(document.utab.contributors?.first?.name == "Example Composer")
    #expect(document.utab.contributors?.first?.role == "composer")
    #expect(document.utab.rights?.first?.type == "music")
    #expect(document.utab.source == "Example source")
    #expect(document.utab.encoding?.software == ["TestApp"])
    #expect(document.utab.miscellaneous?["difficulty"] == "1")
    let exported = try MusicXMLInterchange.exportDocument(imported.data)
    let xml = String(data: exported.data, encoding: .utf8)
    #expect(xml?.contains("<string>3</string><fret>5</fret>") == true)
    #expect(xml?.contains("<creator type=\"composer\">Example Composer</creator>") == true)
    #expect(xml?.contains("<work-title>Tab Studies</work-title>") == true)
    #expect(xml?.contains("<miscellaneous-field name=\"difficulty\">1</miscellaneous-field>") == true)
}
