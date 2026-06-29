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
    let json = #"{"utab":{"version":"0.1-draft"},"setup":{"profiles":[{"id":"p","name":"Xylophone","actuators":{"bars":{"members":[{"id":"c","pitch":"C4"}]}}}],"instruments":[{"id":"i","profile":"p"}]},"tracks":[{"id":"t","instrument":"i","events":[{"at":{"musical":{"measure":1,"beat":1}},"action":"strike","target":"c"}]}]}"#
    let result = try UTabMIDIConverter().convert(data: Data(json.utf8))
    #expect(result.midi.starts(with: Data("MThd".utf8)))
    #expect(result.diagnostics.isEmpty)
}
