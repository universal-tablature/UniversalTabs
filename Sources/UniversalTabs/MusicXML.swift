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
#if canImport(FoundationXML)
import FoundationXML
#endif

public struct MusicXMLResult: Sendable {
    public let data: Data
    public let diagnostics: [String]
}

public enum MusicXMLError: Error, CustomStringConvertible {
    case malformed(String)
    case unsupported(String)
    public var description: String {
        switch self { case .malformed(let value), .unsupported(let value): value }
    }
}

public enum MusicXMLInterchange {
    public static func importDocument(_ data: Data) throws -> MusicXMLResult {
        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse() else { throw MusicXMLError.malformed(parser.parserError?.localizedDescription ?? "invalid MusicXML") }
        guard reader.root == "score-partwise" else { throw MusicXMLError.unsupported("only score-partwise MusicXML is supported") }
        return MusicXMLResult(data: try reader.makeUTab(), diagnostics: reader.diagnostics)
    }

    public static func exportDocument(_ data: Data) throws -> MusicXMLResult {
        let document = try JSONDecoder().decode(UTabDocument.self, from: data)
        var diagnostics: [String] = []
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE score-partwise PUBLIC \"-//Recordare//DTD MusicXML 4.0 Partwise//EN\" \"http://www.musicxml.org/dtds/partwise.dtd\">\n<score-partwise version=\"4.0\">"
        xml += metadataXML(document.utab)
        xml += "<part-list>"
        for (index, track) in document.tracks.enumerated() {
            xml += "<score-part id=\"P\(index + 1)\"><part-name>\(escape(track.name ?? track.id))</part-name></score-part>"
        }
        xml += "</part-list>"
        for (index, track) in document.tracks.enumerated() {
            guard let events = track.events else { diagnostics.append("\(track.id): sectioned export is not yet supported"); continue }
            xml += "<part id=\"P\(index + 1)\"><measure number=\"1\"><attributes><divisions>480</divisions><time><beats>4</beats><beat-type>4</beat-type></time><clef><sign>TAB</sign><line>5</line></clef></attributes>"
            var frets: [Int: Int] = [:]
            var cursor = 0
            for event in events.sorted(by: { tick($0) < tick($1) }) {
                let eventTick = tick(event)
                if eventTick > cursor { xml += "<forward><duration>\(eventTick - cursor)</duration></forward>"; cursor = eventTick }
                for change in event.changes ?? [] {
                    if change.parameter == "fret", let string = targetIndex(change.target), case .number(let value) = change.value { frets[string] = Int(value) }
                }
                guard event.action == "pluck", let target = event.target, let string = targetIndex(target) else { continue }
                let fret = frets[string] ?? 0
                xml += "<note><pitch><step>C</step><octave>4</octave></pitch><duration>216</duration><voice>1</voice><type>eighth</type><notations><technical><string>\(string)</string><fret>\(fret)</fret></technical></notations></note>"
                cursor += 216
            }
            xml += "</measure></part>"
        }
        xml += "</score-partwise>"
        return MusicXMLResult(data: Data(xml.utf8), diagnostics: diagnostics)
    }

    private static func tick(_ event: PerformanceEvent) -> Int {
        guard let position = event.at.musical else { return 0 }
        let offset: Double
        if case .string(let text)? = position.offset {
            let parts = text.split(separator: "/"); offset = parts.count == 2 ? (Double(parts[0])! / Double(parts[1])!) : (Double(text) ?? 0)
        } else { offset = 0 }
        return ((position.measure - 1) * 4 + (position.beat ?? 1) - 1) * 480 + Int(offset * 480)
    }
    private static func targetIndex(_ target: String) -> Int? {
        guard let parsed = try? ActuatorTarget(parsing: target), case .index(let value) = parsed.selector, parsed.groupPath == "strings" else { return nil }; return value
    }
    private static func metadataXML(_ metadata: UTabMetadata) -> String {
        var xml = ""
        if let work = metadata.work {
            var body = ""
            if let value = work.number { body += "<work-number>\(escape(value))</work-number>" }
            if let value = work.title { body += "<work-title>\(escape(value))</work-title>" }
            if let value = work.opus { body += "<opus xlink:href=\"\(escape(value))\"/>" }
            if !body.isEmpty { xml += "<work>\(body)</work>" }
        }
        if let value = metadata.movement?.number { xml += "<movement-number>\(escape(value))</movement-number>" }
        if let value = metadata.movement?.title ?? (metadata.work?.title == nil ? metadata.title : nil) { xml += "<movement-title>\(escape(value))</movement-title>" }
        let contributors = metadata.contributors ?? metadata.authors?.map { UTabContributor(name: $0, role: nil) }
        let hasIdentification = contributors != nil || metadata.rights != nil || metadata.source != nil || metadata.relations != nil || metadata.encoding != nil || metadata.miscellaneous != nil
        if hasIdentification {
            xml += "<identification>"
            for contributor in contributors ?? [] {
                let type = contributor.role.map { " type=\"\(escape($0))\"" } ?? ""
                xml += "<creator\(type)>\(escape(contributor.name))</creator>"
            }
            for rights in metadata.rights ?? [] {
                let type = rights.type.map { " type=\"\(escape($0))\"" } ?? ""
                xml += "<rights\(type)>\(escape(rights.text))</rights>"
            }
            if let encoding = metadata.encoding {
                xml += "<encoding>"
                for encoder in encoding.encoders ?? [] { xml += "<encoder>\(escape(encoder))</encoder>" }
                if let value = encoding.date { xml += "<encoding-date>\(escape(value))</encoding-date>" }
                for software in encoding.software ?? [] { xml += "<software>\(escape(software))</software>" }
                if let value = encoding.description { xml += "<encoding-description>\(escape(value))</encoding-description>" }
                xml += "</encoding>"
            }
            if let value = metadata.source { xml += "<source>\(escape(value))</source>" }
            for relation in metadata.relations ?? [] { xml += "<relation>\(escape(relation))</relation>" }
            if let miscellaneous = metadata.miscellaneous, !miscellaneous.isEmpty {
                xml += "<miscellaneous>"
                for item in miscellaneous.sorted(by: { $0.key < $1.key }) { xml += "<miscellaneous-field name=\"\(escape(item.key))\">\(escape(item.value))</miscellaneous-field>" }
                xml += "</miscellaneous>"
            }
            xml += "</identification>"
        }
        return xml
    }
    private static func escape(_ value: String) -> String { value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;") }
}

private final class Reader: NSObject, XMLParserDelegate {
    struct Note { var measure = 1; var tick = 0; var duration = 0; var voice = 1; var staff = 1; var string: Int?; var fret: Int?; var chord = false; var rest = false; var grace = false }
    var root = ""; var diagnostics: [String] = []; var divisions = 1; var part = ""; var measure = 1; var measureOrdinal = 0; var cursor = 0; var lastStart = 0
    var notes: [String: [Note]] = [:]; var current: Note?; var text = ""; var stack: [String] = []; var attributeStack: [[String:String]] = []
    var workNumber: String?; var workTitle: String?; var opus: String?; var movementNumber: String?; var movementTitle: String?
    var contributors: [[String:String]] = []; var rights: [[String:String]] = []; var source: String?; var relations: [String] = []
    var encoders: [String] = []; var encodingDate: String?; var software: [String] = []; var encodingDescription: String?; var miscellaneous: [String:String] = [:]
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes attributeDict: [String:String] = [:]) {
        if root.isEmpty { root = name }; stack.append(name); attributeStack.append(attributeDict); text = ""
        if name == "opus" { opus = attributeDict["xlink:href"] ?? attributeDict["href"] }
        if name == "part" { part = attributeDict["id"] ?? "part"; notes[part, default: []] = []; measureOrdinal = 0 }
        if name == "measure" { measureOrdinal += 1; measure = measureOrdinal; cursor = 0 }
        if name == "note" { current = Note(measure: measure, tick: cursor) }
        if name == "chord" { current?.chord = true; current?.tick = lastStart }
        if name == "rest" { current?.rest = true }
        if name == "grace" { current?.grace = true }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let attributes = attributeStack.last ?? [:]
        let scoreLevel = !stack.contains("score-part")
        if scoreLevel && name == "work-number" && !value.isEmpty { workNumber = value }
        if scoreLevel && name == "work-title" && !value.isEmpty { workTitle = value }
        if scoreLevel && name == "movement-number" && !value.isEmpty { movementNumber = value }
        if scoreLevel && name == "movement-title" && !value.isEmpty { movementTitle = value }
        if scoreLevel && name == "creator" && !value.isEmpty { var item = ["name":value]; if let role = attributes["type"] { item["role"] = role }; contributors.append(item) }
        if scoreLevel && name == "rights" && !value.isEmpty { var item = ["text":value]; if let type = attributes["type"] { item["type"] = type }; rights.append(item) }
        if scoreLevel && name == "source" && !value.isEmpty { source = value }
        if scoreLevel && name == "relation" && !value.isEmpty { relations.append(value) }
        if scoreLevel && name == "encoder" && !value.isEmpty { encoders.append(value) }
        if scoreLevel && name == "encoding-date" && !value.isEmpty { encodingDate = value }
        if scoreLevel && name == "software" && !value.isEmpty { software.append(value) }
        if scoreLevel && name == "encoding-description" && !value.isEmpty { encodingDescription = value }
        if scoreLevel && name == "miscellaneous-field", let key = attributes["name"], !value.isEmpty { miscellaneous[key] = value }
        if name == "divisions", let number = Int(value) { divisions = number }
        if name == "duration", let number = Int(value) {
            if current != nil { current?.duration = number }
            else if stack.dropLast().last == "backup" { cursor = max(0, cursor - number) }
            else if stack.dropLast().last == "forward" { cursor += number }
        }
        if name == "string", let number = Int(value) { current?.string = number }
        if name == "fret", let number = Int(value) { current?.fret = number }
        if name == "voice", let number = Int(value) { current?.voice = number }
        if name == "staff", let number = Int(value) { current?.staff = number }
        if name == "note", let note = current { notes[part, default: []].append(note); lastStart = note.tick; if !note.chord { cursor += note.duration }; current = nil }
        _ = stack.popLast(); _ = attributeStack.popLast(); text = ""
    }
    func makeUTab() throws -> Data {
        var tracks: [[String:Any]] = []
        var instruments: [[String:Any]] = []
        let stringCount = max(1, notes.values.flatMap { $0 }.compactMap(\.string).max() ?? 6)
        for (index, entry) in notes.sorted(by: { $0.key < $1.key }).enumerated() {
            let instrument = "instrument-\(index + 1)"; instruments.append(["id":instrument,"profile":"profile:fretted-string","configuration":["tuning":["E2","A2","D3","G3","B3","E4"],"stringIndexOrder":"highest-to-lowest"]])
            let groups = Dictionary(grouping: entry.value, by: { "\($0.staff):\($0.voice)" })
            for voiceGroup in groups.sorted(by: { $0.key < $1.key }) {
                var events: [[String:Any]] = []
                var skippedWithoutTab = 0
                var skippedGrace = 0
                for note in voiceGroup.value where !note.rest {
                    if note.grace { skippedGrace += 1; continue }
                    guard let string = note.string, let fret = note.fret else { skippedWithoutTab += 1; continue }
                    let quarters = Double(note.tick) / Double(max(1, divisions)); let beat = Int(quarters.rounded(.down)) + 1; let fraction = quarters - floor(quarters)
                    var musical: [String:Any] = ["measure":note.measure,"beat":beat]; if fraction != 0 { musical["offset"] = String(format:"%.6g",fraction) }
                    let at: [String:Any] = ["musical":musical]
                    events.append(["at":at,"type":"state","changes":[["target":"strings[\(string)]","parameter":"fret","value":fret]]])
                    var pluck: [String:Any] = ["at":at,"action":"pluck","target":"strings[\(string)]"]
                    if note.duration > 0 { pluck["duration"] = ["quarterNotes":String(format:"%.6g",Double(note.duration)/Double(max(1,divisions)))] }
                    events.append(pluck)
                }
                if skippedWithoutTab > 0 { diagnostics.append("\(entry.key) staff/voice \(voiceGroup.key): skipped \(skippedWithoutTab) notes without tablature string/fret") }
                if skippedGrace > 0 { diagnostics.append("\(entry.key) staff/voice \(voiceGroup.key): skipped \(skippedGrace) grace notes because grace ordering is not yet defined") }
                if !events.isEmpty { tracks.append(["id":"track-\(index + 1)-staff-voice-\(voiceGroup.key.replacingOccurrences(of: ":", with: "-"))","instrument":instrument,"events":events]) }
            }
        }
        guard !tracks.isEmpty else { throw MusicXMLError.unsupported("MusicXML contains no importable string/fret tablature events") }
        var metadata: [String:Any] = ["version":"0.1-draft", "title":movementTitle ?? workTitle ?? "MusicXML import"]
        if workNumber != nil || workTitle != nil || opus != nil { metadata["work"] = compact(["number":workNumber,"title":workTitle,"opus":opus]) }
        if movementNumber != nil || movementTitle != nil { metadata["movement"] = compact(["number":movementNumber,"title":movementTitle]) }
        if !contributors.isEmpty { metadata["contributors"] = contributors }
        if !rights.isEmpty { metadata["rights"] = rights }
        if let source { metadata["source"] = source }
        if !relations.isEmpty { metadata["relations"] = relations }
        let encoding = compact(["date":encodingDate,"software":software.isEmpty ? nil : software,"encoders":encoders.isEmpty ? nil : encoders,"description":encodingDescription])
        if !encoding.isEmpty { metadata["encoding"] = encoding }
        if !miscellaneous.isEmpty { metadata["miscellaneous"] = miscellaneous }
        let root: [String:Any] = ["utab":metadata,"setup":["profiles":[["id":"profile:fretted-string","name":"Fretted String","actuators":["strings":["count":stringCount]],"interactions":["pluck":[:]]]],"instruments":instruments],"tracks":tracks]
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted,.sortedKeys])
    }
    private func compact(_ values: [String: Any?]) -> [String: Any] {
        values.reduce(into: [:]) { result, item in if let value = item.value { result[item.key] = value } }
    }
}
