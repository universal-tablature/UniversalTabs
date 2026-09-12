import Foundation
import Testing
import UTABConversion
import UniversalTabs

private let source = """
title "Conversion test"
meter 4/4
tempo 100
profile Notes { id "profile:conversion-test"; version "1"; actuator notes; interaction play { targets notes } }
model TestInstrument : Notes { id "instrument:conversion-test"; name "Test instrument" }
instrument part : TestInstrument as "Part"
phrase material { bar { C4 q, E4 q; rest q; G4 h } }
section music : 1 bars { part { voice notes { material } } }
main { music }
"""

@Test func detectsEveryImportableConversionFormatByContent() throws {
    let converter = UTabConverter()
    let composer = Data(source.utf8)
    #expect(try converter.detectFormat(data: composer) == .uTab)

    let json = try converter.convert(composer, to: .uTabJSON).data
    #expect(try converter.detectFormat(data: json) == .uTabJSON)
    for format in [UTabConversionFormat.musicXML, .mei, .mnx] {
        let encoded = try converter.convert(json, from: .uTabJSON, to: format).data
        #expect(try converter.detectFormat(data: encoded) == format)
    }
}

@Test func convertsAllSupportedImportsThroughUTabJSONAndBackToSource() throws {
    let converter = UTabConverter()
    let json = try converter.convert(Data(source.utf8), to: .uTabJSON).data
    for format in [UTabConversionFormat.uTabJSON, .musicXML, .mei, .mnx] {
        let input = format == .uTabJSON ? json : try converter.convert(json, from: .uTabJSON, to: format).data
        let result = try converter.convert(input, from: format, to: .uTab)
        #expect(String(decoding: result.data, as: UTF8.self).contains("main { imported }"))
    }
    let lilyPond = try converter.convert(json, from: .uTabJSON, to: .lilyPond)
    #expect(String(decoding: lilyPond.data, as: UTF8.self).contains("\\score"))
}

@Test func rejectsLilyPondAsAnInputFormat() {
    #expect(throws: UTabGeneralConversionError.self) {
        try UTabConverter().convert(Data("\\version \"2.24.0\"".utf8), from: .lilyPond, to: .uTabJSON)
    }
}
