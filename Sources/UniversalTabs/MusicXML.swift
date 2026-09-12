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
        let divisions = 480
        let meter = document.setup.time?.meter
        let numerator = meter?.numerator ?? 4
        let denominator = meter?.denominator ?? 4
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE score-partwise PUBLIC \"-//Recordare//DTD MusicXML 4.0 Partwise//EN\" \"http://www.musicxml.org/dtds/partwise.dtd\">\n<score-partwise version=\"4.0\">"
        xml += metadataXML(document.utab)
        xml += "<part-list>"
        for (index, track) in document.tracks.enumerated() {
            xml += "<score-part id=\"P\(index + 1)\"><part-name>\(escape(track.name ?? track.id))</part-name></score-part>"
        }
        xml += "</part-list>"
        for (index, track) in document.tracks.enumerated() {
            let events = expandedEvents(for: track, setup: document.setup)
            if events.isEmpty, track.events == nil { diagnostics.append("\(track.id): sectioned track has no resolvable arrangement events") }
            xml += "<part id=\"P\(index + 1)\">"
            var frets: [Int: Int] = [:]
            let grouped = Dictionary(grouping: events, by: { $0.at.musical?.measure ?? 1 })
            for measure in grouped.keys.sorted() {
                xml += "<measure number=\"\(measure)\">"
                if measure == grouped.keys.min() {
                    xml += "<attributes><divisions>\(divisions)</divisions><time><beats>\(numerator)</beats><beat-type>\(denominator)</beat-type></time></attributes>"
                }
                var cursor = 0
                var lastSoundingTick: Int?
                let measureEvents = (grouped[measure] ?? []).enumerated().sorted {
                    let lhs = localTick($0.element, divisions: divisions, denominator: denominator)
                    let rhs = localTick($1.element, divisions: divisions, denominator: denominator)
                    if lhs != rhs { return lhs < rhs }
                    if ($0.element.changes != nil) != ($1.element.changes != nil) { return $0.element.changes != nil }
                    return $0.offset < $1.offset
                }.map(\.element)
                for event in measureEvents {
                    let eventTick = localTick(event, divisions: divisions, denominator: denominator)
                    for change in event.changes ?? [] {
                        if change.parameter == "fret", let string = targetIndex(change.target), case .number(let value) = change.value { frets[string] = Int(value) }
                    }
                    guard event.type == "rest" || event.action != nil || event.gesture != nil else { continue }
                    if eventTick > cursor { xml += "<forward><duration>\(eventTick - cursor)</duration></forward>"; cursor = eventTick }
                    let duration = durationTicks(event.duration, divisions: divisions)
                    let isGrace = event.type == "grace"
                    let isChordTone = !isGrace && lastSoundingTick == eventTick && event.type != "rest"
                    xml += "<note>"
                    if isChordTone { xml += "<chord/>" }
                    if isGrace { xml += graceXML(event.parameters?["grace"]) }
                    if event.type == "rest" {
                        xml += "<rest/>"
                    } else if let unpitched = unpitchedXML(event.parameters?["unpitched"]) {
                        xml += unpitched
                    } else if let pitch = pitchXML(event.parameters?["pitch"]) {
                        xml += pitch
                    } else {
                        diagnostics.append("\(track.id): event at measure \(measure) has no exportable pitch; using C4")
                        xml += "<pitch><step>C</step><octave>4</octave></pitch>"
                    }
                    if !isGrace { xml += "<duration>\(max(1, duration))</duration>" }
                    xml += "<voice>1</voice>"
                    if event.action == "pluck", let target = event.target, let string = targetIndex(target) {
                        xml += "<notations><technical><string>\(string)</string><fret>\(frets[string] ?? 0)</fret></technical></notations>"
                    }
                    xml += "</note>"
                    if !isGrace && !isChordTone { cursor = max(cursor, eventTick + max(1, duration)) }
                    if event.type != "rest" { lastSoundingTick = eventTick }
                }
                xml += "</measure>"
            }
            xml += "</part>"
        }
        xml += "</score-partwise>"
        return MusicXMLResult(data: Data(xml.utf8), diagnostics: diagnostics)
    }

    private static func localTick(_ event: PerformanceEvent, divisions: Int, denominator: Int) -> Int {
        guard let position = event.at.musical else { return 0 }
        let beatLength = 4.0 / Double(denominator)
        return Int((((Double(position.beat ?? 1) - 1) + rational(position.offset)) * beatLength * Double(divisions)).rounded())
    }
    private static func durationTicks(_ duration: EventDuration?, divisions: Int) -> Int {
        Int((rational(duration?.quarterNotes) * Double(divisions)).rounded())
    }
    private static func rational(_ value: JSONValue?) -> Double {
        switch value {
        case .number(let number): return number
        case .string(let text):
            let parts = text.split(separator: "/")
            if parts.count == 2, let numerator = Double(parts[0]), let denominator = Double(parts[1]), denominator != 0 { return numerator / denominator }
            return Double(text) ?? 0
        default: return 0
        }
    }
    private static func pitchXML(_ value: JSONValue?) -> String? {
        guard case .string(let pitch)? = value, let first = pitch.first else { return nil }
        let suffix = pitch.dropFirst()
        guard let octaveStart = suffix.firstIndex(where: { $0.isNumber || $0 == "-" }),
              let octave = Int(suffix[octaveStart...]) else { return nil }
        let accidentals = suffix[..<octaveStart]
        let alter = accidentals.reduce(0) { result, character in result + (character == "#" ? 1 : character == "b" ? -1 : 0) }
        let alterXML = alter == 0 ? "" : "<alter>\(alter)</alter>"
        return "<pitch><step>\(escape(String(first).uppercased()))</step>\(alterXML)<octave>\(octave)</octave></pitch>"
    }
    private static func unpitchedXML(_ value: JSONValue?) -> String? {
        guard case .object(let unpitched)? = value,
              case .string(let step)? = unpitched["displayStep"] else { return nil }
        var xml = "<unpitched><display-step>\(escape(step.uppercased()))</display-step>"
        if case .number(let octave)? = unpitched["displayOctave"] {
            xml += "<display-octave>\(Int(octave))</display-octave>"
        }
        xml += "</unpitched>"
        if case .string(let instrumentID)? = unpitched["instrumentID"] {
            xml += "<instrument id=\"\(escape(instrumentID))\"/>"
        }
        return xml
    }
    private static func graceXML(_ value: JSONValue?) -> String {
        guard case .object(let grace)? = value else { return "<grace/>" }
        var attributes = ""
        for key in ["steal-time-previous", "steal-time-following", "make-time"] {
            if case .number(let number)? = grace[key] { attributes += " \(key)=\"\(number.formatted(.number.grouping(.never)))\"" }
        }
        return "<grace\(attributes)/>"
    }
    private static func targetIndex(_ target: String) -> Int? {
        guard let parsed = try? ActuatorTarget(parsing: target), case .index(let value) = parsed.selector, parsed.groupPath == "strings" else { return nil }; return value
    }
    static func expandedEvents(for track: EventTrack, setup: PerformanceSetup) -> [PerformanceEvent] {
        if let events = track.events { return events }
        guard let parts = track.parts, let arrangement = setup.arrangement, let sections = setup.sections else { return [] }
        let sectionsByID = Dictionary(sections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let reusable = Dictionary(parts.compactMap { part in part.section.map { ($0, part) } }, uniquingKeysWith: { first, _ in first })
        let specific = Dictionary(parts.compactMap { part in part.entry.map { ($0, part) } }, uniquingKeysWith: { first, _ in first })
        var measureOffset = 0
        var result: [PerformanceEvent] = []
        for entry in arrangement {
            guard let section = sectionsByID[entry.section] else { continue }
            for _ in 0..<entry.effectivePlayCount {
                let entryPart = specific[entry.id]
                let selected: [TrackPart]
                if let entryPart { selected = entryPart.mode == .overlay ? [reusable[entry.section], entryPart].compactMap { $0 } : [entryPart] }
                else { selected = reusable[entry.section].map { [$0] } ?? [] }
                for part in selected {
                    result += part.events.map { event in
                        guard let position = event.at.musical else { return event }
                        return PerformanceEvent(
                            id: event.id,
                            at: EventTime(musical: MusicalPosition(measure: position.measure + measureOffset, beat: position.beat, offset: position.offset)),
                            duration: event.duration,
                            type: event.type,
                            action: event.action,
                            gesture: event.gesture,
                            target: event.target,
                            targets: event.targets,
                            parameter: event.parameter,
                            parameters: event.parameters,
                            techniques: event.techniques,
                            source: event.source,
                            changes: event.changes,
                            curve: event.curve
                        )
                    }
                }
                measureOffset += section.length.measures
            }
        }
        return result
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
    struct Note {
        var measure = 1
        var tick = 0
        var duration = 0
        var voice = 1
        var staff = 1
        var string: Int?
        var fret: Int?
        var step: String?
        var alter: Double = 0
        var octave: Int?
        var unpitchedStep: String?
        var unpitchedOctave: Int?
        var instrumentID: String?
        var chord = false
        var rest = false
        var grace = false
        var graceAttributes: [String: String] = [:]

        var pitch: String? {
            guard let step, let octave else { return nil }
            let roundedAlter = alter.rounded()
            guard alter == roundedAlter else { return nil }
            let accidental: String
            if roundedAlter > 0 { accidental = String(repeating: "#", count: Int(roundedAlter)) }
            else if roundedAlter < 0 { accidental = String(repeating: "b", count: Int(-roundedAlter)) }
            else { accidental = "" }
            return "\(step.uppercased())\(accidental)\(octave)"
        }
    }
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
        if name == "grace" {
            current?.grace = true
            current?.graceAttributes = attributeDict
        }
        if name == "instrument", current != nil { current?.instrumentID = attributeDict["id"] }
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
        if name == "step", !value.isEmpty { current?.step = value }
        if name == "alter", let number = Double(value) { current?.alter = number }
        if name == "octave", let number = Int(value) { current?.octave = number }
        if name == "display-step", !value.isEmpty { current?.unpitchedStep = value }
        if name == "display-octave", let number = Int(value) { current?.unpitchedOctave = number }
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
                var skippedWithoutPitchOrTab = 0
                for note in voiceGroup.value {
                    let quarters = Double(note.tick) / Double(max(1, divisions)); let beat = Int(quarters.rounded(.down)) + 1; let fraction = quarters - floor(quarters)
                    var musical: [String:Any] = ["measure":note.measure,"beat":beat]; if fraction != 0 { musical["offset"] = String(format:"%.6g",fraction) }
                    let at: [String:Any] = ["musical":musical]
                    if note.rest {
                        var restEvent: [String: Any] = ["at": at, "type": "rest"]
                        if note.duration > 0 { restEvent["duration"] = ["quarterNotes":String(format:"%.6g",Double(note.duration)/Double(max(1,divisions)))] }
                        events.append(restEvent)
                        continue
                    }
                    guard note.pitch != nil || note.unpitchedStep != nil || (note.string != nil && note.fret != nil) else {
                        skippedWithoutPitchOrTab += 1
                        continue
                    }
                    var soundingEvent: [String: Any]
                    if let string = note.string, let fret = note.fret {
                        events.append(["at":at,"type":"state","changes":[["target":"strings[\(string)]","parameter":"fret","value":fret]]])
                        soundingEvent = ["at":at,"action":"pluck","target":"strings[\(string)]"]
                    } else {
                        soundingEvent = ["at":at,"action":"play","target":"notes"]
                    }
                    var parameters: [String: Any] = [:]
                    if let pitch = note.pitch { parameters["pitch"] = pitch }
                    if let displayStep = note.unpitchedStep {
                        var unpitched: [String: Any] = ["displayStep": displayStep]
                        if let displayOctave = note.unpitchedOctave { unpitched["displayOctave"] = displayOctave }
                        if let instrumentID = note.instrumentID { unpitched["instrumentID"] = instrumentID }
                        parameters["unpitched"] = unpitched
                    }
                    if note.grace {
                        var grace: [String: Any] = ["policy": musicXMLGracePolicy(note.graceAttributes)]
                        for key in ["steal-time-previous", "steal-time-following", "make-time"] {
                            if let value = note.graceAttributes[key], let number = Double(value) { grace[key] = number }
                        }
                        parameters["grace"] = grace
                        soundingEvent["type"] = "grace"
                    }
                    if !parameters.isEmpty { soundingEvent["parameters"] = parameters }
                    if note.pitch == nil, note.step != nil {
                        diagnostics.append("\(entry.key) staff/voice \(voiceGroup.key): preserved tablature but omitted unsupported microtonal pitch spelling")
                    }
                    if note.duration > 0 { soundingEvent["duration"] = ["quarterNotes":String(format:"%.6g",Double(note.duration)/Double(max(1,divisions)))] }
                    events.append(soundingEvent)
                }
                if skippedWithoutPitchOrTab > 0 { diagnostics.append("\(entry.key) staff/voice \(voiceGroup.key): skipped \(skippedWithoutPitchOrTab) notes without pitch or tablature string/fret") }
                if !events.isEmpty { tracks.append(["id":"track-\(index + 1)-staff-voice-\(voiceGroup.key.replacingOccurrences(of: ":", with: "-"))","instrument":instrument,"events":events]) }
            }
        }
        guard !tracks.isEmpty else { throw MusicXMLError.unsupported("MusicXML contains no importable pitched, tablature, or rest events") }
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
        let root: [String:Any] = ["utab":metadata,"setup":["profiles":[["id":"profile:fretted-string","name":"Fretted String","actuators":["strings":["count":stringCount],"notes":[:]],"interactions":["pluck":[:],"play":[:]]]],"instruments":instruments],"tracks":tracks]
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted,.sortedKeys])
    }
    private func compact(_ values: [String: Any?]) -> [String: Any] {
        values.reduce(into: [:]) { result, item in if let value = item.value { result[item.key] = value } }
    }

    private func musicXMLGracePolicy(_ attributes: [String: String]) -> String {
        if attributes["steal-time-following"] != nil { return "stealFollowing" }
        if attributes["steal-time-previous"] != nil { return "stealPrevious" }
        if attributes["make-time"] != nil { return "makeTime" }
        return "unspecified"
    }
}
