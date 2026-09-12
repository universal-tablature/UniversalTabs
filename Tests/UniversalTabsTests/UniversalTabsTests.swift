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

@Test func convertsRealizedStrumMembersToMIDINotes() throws {
    let json = #"{"utab":{"version":"0.1-draft"},"setup":{"profiles":[{"id":"strings","actuators":{"strings":{"count":6}},"interactions":{"strum":{"targets":["strings"]}}}],"instruments":[{"id":"guitar","profile":"strings","realization":{"midi":{"program":28}}}]},"tracks":[{"id":"rhythm","instrument":"guitar","events":[{"at":{"musical":{"measure":1,"beat":1}},"duration":{"quarterNotes":"1/4"},"action":"strum","target":"strings","parameters":{"spread":"24ms","members":[{"string":6,"position":2,"pitch":"E2"},{"string":5,"position":2,"pitch":"B2"}]}}]}]}"#
    let result = try UTabMIDIConverter().convert(data: Data(json.utf8))

    #expect(result.diagnostics.isEmpty)
    let bytes = Array(result.midi)
    #expect(bytes.filter { $0 & 0xF0 == 0x90 }.count == 2)
    #expect(bytes.contains(40))
    #expect(bytes.contains(47))
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
    #expect(document.tracks[0].events?.last?.parameters?["pitch"] == .string("G3"))
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
    let lilyPond = try LilyPondInterchange.exportDocument(imported.data)
    let lilyPondSource = try #require(String(data: lilyPond.data, encoding: .utf8))
    #expect(lilyPondSource.contains("\\version \"2.24.0\""))
    #expect(lilyPondSource.contains("g4"))
}

@Test func importsPitchedMusicXMLWithoutTablature() throws {
    let xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <score-partwise version="4.0">
      <part-list><score-part id="P1"><part-name>Piano</part-name></score-part></part-list>
      <part id="P1"><measure number="1"><attributes><divisions>4</divisions></attributes>
        <note><pitch><step>C</step><alter>1</alter><octave>4</octave></pitch><duration>2</duration><voice>1</voice></note>
      </measure></part>
    </score-partwise>
    """

    let imported = try MusicXMLInterchange.importDocument(Data(xml.utf8))
    let document = try JSONDecoder().decode(UTabDocument.self, from: imported.data)
    let event = try #require(document.tracks.first?.events?.first)

    #expect(event.action == "play")
    #expect(event.target == "notes")
    #expect(event.parameters?["pitch"] == .string("C#4"))
    #expect(event.duration?.quarterNotes == .string("0.5"))
    #expect(UTabValidator().validate(document).isEmpty)
}

@Test func importsMusicXMLRestsAndGraceNotes() throws {
    let xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <score-partwise version="4.0">
      <part-list><score-part id="P1"><part-name>Flute</part-name></score-part></part-list>
      <part id="P1"><measure number="1"><attributes><divisions>4</divisions></attributes>
        <note><rest/><duration>4</duration><voice>1</voice></note>
        <note><grace steal-time-following="10"/><pitch><step>D</step><octave>5</octave></pitch><voice>1</voice></note>
        <note><pitch><step>E</step><octave>5</octave></pitch><duration>4</duration><voice>1</voice></note>
      </measure></part>
    </score-partwise>
    """

    let imported = try MusicXMLInterchange.importDocument(Data(xml.utf8))
    let document = try JSONDecoder().decode(UTabDocument.self, from: imported.data)
    let events = try #require(document.tracks.first?.events)

    #expect(events.count == 3)
    #expect(events[0].type == "rest")
    #expect(events[0].duration?.quarterNotes == .string("1"))
    #expect(events[1].type == "grace")
    #expect(events[1].parameters?["pitch"] == .string("D5"))
    #expect(events[1].parameters?["grace"] == .object([
        "policy": .string("stealFollowing"),
        "steal-time-following": .number(10),
    ]))
    #expect(events[1].at.musical?.beat == 2)
    #expect(events[2].at.musical?.beat == 2)
    #expect(UTabValidator().validate(document).isEmpty)

    let exported = try MusicXMLInterchange.exportDocument(imported.data)
    let exportedXML = try #require(String(data: exported.data, encoding: .utf8))
    #expect(exportedXML.contains("<rest/><duration>480</duration>"))
    #expect(exportedXML.contains("<grace steal-time-following=\"10\"/><pitch><step>D</step><octave>5</octave></pitch>"))
    #expect(exportedXML.contains("<pitch><step>E</step><octave>5</octave></pitch><duration>480</duration>"))
}

@Test func importsAndExportsUnpitchedMusicXMLNotes() throws {
    let xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <score-partwise version="4.0">
      <part-list><score-part id="P1"><part-name>Drums</part-name></score-part></part-list>
      <part id="P1"><measure number="1"><attributes><divisions>4</divisions></attributes>
        <note><unpitched><display-step>F</display-step><display-octave>4</display-octave></unpitched><instrument id="P1-I36"/><duration>1</duration><voice>1</voice></note>
      </measure></part>
    </score-partwise>
    """

    let imported = try MusicXMLInterchange.importDocument(Data(xml.utf8))
    let document = try JSONDecoder().decode(UTabDocument.self, from: imported.data)
    let event = try #require(document.tracks.first?.events?.first)
    #expect(event.parameters?["unpitched"] == .object([
        "displayStep": .string("F"),
        "displayOctave": .number(4),
        "instrumentID": .string("P1-I36"),
    ]))

    let exported = try MusicXMLInterchange.exportDocument(imported.data)
    let exportedXML = try #require(String(data: exported.data, encoding: .utf8))
    #expect(exportedXML.contains("<unpitched><display-step>F</display-step><display-octave>4</display-octave></unpitched>"))
    #expect(exportedXML.contains("<instrument id=\"P1-I36\"/>"))

    let roundTrip = try MusicXMLInterchange.importDocument(exported.data)
    let roundTripDocument = try JSONDecoder().decode(UTabDocument.self, from: roundTrip.data)
    #expect(roundTripDocument.tracks.first?.events?.first?.parameters?["unpitched"] == event.parameters?["unpitched"])
}

@Test func importsAndExportsMEI51NotesRestsAndChords() throws {
    let mei = """
    <?xml version="1.0" encoding="UTF-8"?>
    <mei xmlns="http://www.music-encoding.org/ns/mei" meiversion="5.1"><meiHead><fileDesc><titleStmt><title>MEI Study</title></titleStmt><pubStmt/></fileDesc></meiHead><music><body><mdiv><score><scoreDef meter.count="4" meter.unit="4"><staffGrp><staffDef n="1" lines="5"/></staffGrp></scoreDef><section><measure n="1"><staff n="1"><layer n="1"><note pname="c" oct="4" dur="4"/><rest dur="4"/><chord dur="2"><note pname="e" oct="4"/><note pname="g" oct="4"/></chord></layer></staff></measure></section></score></mdiv></body></music></mei>
    """
    let imported = try MEIInterchange.importDocument(Data(mei.utf8))
    let document = try JSONDecoder().decode(UTabDocument.self, from: imported.data)
    #expect(document.utab.title == "MEI Study")
    #expect(document.tracks.first?.events?.count == 4)
    #expect(document.tracks.first?.events?[1].type == "rest")
    let exported = try MEIInterchange.exportDocument(imported.data)
    let source = try #require(String(data: exported.data, encoding: .utf8))
    #expect(source.contains("meiversion=\"5.1\""))
    #expect(source.contains("<chord"))
}

@Test func importsVendoredMEI51Corpus() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let corpusRoot = repositoryRoot.appendingPathComponent("Vendor/mei-sample-encodings/MEI_5.1", isDirectory: true)
    let enumerator = try #require(FileManager.default.enumerator(
        at: corpusRoot,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ))
    let files = enumerator.compactMap { $0 as? URL }
        .filter { $0.pathExtension.lowercased() == "mei" }
        .sorted { $0.path < $1.path }
    #expect(files.count >= 150)

    var importedCount = 0
    var roundTripCount = 0
    var fragmentCount = 0
    for file in files {
        let relativePath = String(file.path.dropFirst(corpusRoot.path.count + 1))
        do {
            let imported = try MEIInterchange.importDocument(Data(contentsOf: file))
            let document = try JSONDecoder().decode(UTabDocument.self, from: imported.data)
            importedCount += 1
            if document.tracks.contains(where: { !($0.events?.isEmpty ?? true) }) {
                let exported = try MEIInterchange.exportDocument(imported.data)
                let reimported = try MEIInterchange.importDocument(exported.data)
                _ = try JSONDecoder().decode(UTabDocument.self, from: reimported.data)
                roundTripCount += 1
            }
        } catch MusicXMLError.unsupported {
            // The vendored 5.1 corpus also contains `mei-all_anyStart` element fragments.
            fragmentCount += 1
        } catch {
            Issue.record("Failed MEI 5.1 sample \(relativePath): \(error)")
        }
    }
    #expect(importedCount + fragmentCount == files.count)
    #expect(importedCount > 0)
    #expect(roundTripCount > 0)
}
