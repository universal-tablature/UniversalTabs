import Foundation
import UniversalTabs

public struct UTabScore: Sendable {
    public struct Section: Identifiable, Sendable {
        public let id: String
        public let name: String
        public let startMeasure: Int
        public let measureCount: Int
        public let events: [Event]
    }

    public struct Event: Identifiable, Sendable {
        public let id: String
        public let sourcePath: String
        public let measure: Int
        public let beat: Double
        public let stringNumber: Int?
        public let fret: Int?
        public let midiPitch: Int?
        public let staffStep: Int?
        public let label: String
    }

    public let title: String
    public let stringCount: Int
    public let supportsTablature: Bool
    public let sections: [Section]

    public init(document: UTabDocument, instrumentID: String? = nil) {
        let instrument = document.setup.instruments.first { instrumentID == nil || $0.id == instrumentID }
        let profile = document.setup.profiles.first { $0.id == instrument?.profile }
        supportsTablature = profile?.actuators?["strings"] != nil
        stringCount = max(1, profile?.actuators?["strings"]?.count ?? 6)
        title = document.utab.title ?? document.utab.movement?.title ?? document.utab.work?.title ?? "Untitled"
        let tuning = Self.tuningMIDI(instrument?.configuration?["tuning"], count: stringCount)
        let meter = document.setup.time?.meterMap?.first ?? document.setup.time?.meter
        let beatsPerMeasure = max(1, meter?.numerator ?? 4)
        let definitions = document.setup.sections ?? []
        var nextSectionMeasure = 1
        var sectionMeasureOffsets: [String: Int] = [:]
        for definition in definitions {
            sectionMeasureOffsets[definition.id] = nextSectionMeasure - 1
            nextSectionMeasure += definition.length.measures
        }
        var prepared: [Event] = []

        for (trackIndex, track) in document.tracks.enumerated() where instrument == nil || track.instrument == instrument?.id {
            var frets = Array(repeating: 0, count: stringCount)
            let directEvents: [(event: PerformanceEvent, sectionID: String?)] =
                (track.events ?? []).map { ($0, nil) }
            let partEvents: [(event: PerformanceEvent, sectionID: String?)] =
                (track.parts ?? []).flatMap { part in
                    part.events.map { ($0, part.section) }
                }
            let sourceEvents = directEvents + partEvents
            let ordered = sourceEvents.enumerated().sorted {
                let firstOffset = sectionMeasureOffsets[$0.element.sectionID ?? ""] ?? 0
                let secondOffset = sectionMeasureOffsets[$1.element.sectionID ?? ""] ?? 0
                return Self.position($0.element.event, beatsPerMeasure: beatsPerMeasure)
                    + Double(firstOffset * beatsPerMeasure)
                    < Self.position($1.element.event, beatsPerMeasure: beatsPerMeasure)
                    + Double(secondOffset * beatsPerMeasure)
            }
            for (eventIndex, sourceEvent) in ordered {
                let event = sourceEvent.event
                guard let position = event.at.musical else { continue }
                let measureOffset = sectionMeasureOffsets[sourceEvent.sectionID ?? ""] ?? 0
                let displayMeasure = position.measure + measureOffset
                let beat = Double(position.beat ?? 1) + Self.number(position.offset)
                let path = "tracks[\(trackIndex)].events[\(eventIndex)]"
                let eventID = event.id ?? "\(track.id):event:\(eventIndex)"
                for change in event.changes ?? [] where change.parameter == "fret" || change.parameter == "position" {
                    if let string = Self.stringNumber(change.target), frets.indices.contains(string - 1), let fret = Self.integer(change.value) {
                        frets[string - 1] = fret
                    }
                }
                if let string = Self.stringNumber(event.target), frets.indices.contains(string - 1) {
                    if let fret = Self.integer(event.parameters?["fret"] ?? event.parameters?["position"]) { frets[string - 1] = fret }
                    prepared.append(Self.event(eventID, path, displayMeasure, beat, string, frets[string - 1], tuning, event))
                } else if event.gesture == "strum" || event.action == "strum" {
                    for string in 1...stringCount {
                        prepared.append(Self.event("\(eventID):string:\(string)", path, displayMeasure, beat, string, frets[string - 1], tuning, event))
                    }
                } else if let pitch = Self.pitch(event.parameters?["pitch"]) {
                    prepared.append(Event(
                        id: eventID,
                        sourcePath: path,
                        measure: displayMeasure,
                        beat: beat,
                        stringNumber: nil,
                        fret: nil,
                        midiPitch: pitch.midi,
                        staffStep: pitch.staffStep,
                        label: event.action ?? event.gesture ?? event.type ?? "event"
                    ))
                }
            }
        }

        if definitions.isEmpty {
            let end = max(1, prepared.map(\.measure).max() ?? 1)
            sections = [Section(id: "score", name: title, startMeasure: 1, measureCount: end, events: prepared)]
        } else {
            var start = 1
            sections = definitions.map { definition in
                defer { start += definition.length.measures }
                let range = start..<(start + definition.length.measures)
                return Section(id: definition.id, name: definition.name ?? definition.id, startMeasure: start,
                               measureCount: definition.length.measures, events: prepared.filter { range.contains($0.measure) })
            }
        }
    }

    private static func event(_ id: String, _ path: String, _ measure: Int, _ beat: Double, _ string: Int,
                              _ fret: Int, _ tuning: [Int], _ event: PerformanceEvent) -> Event {
        let realizedPitch = pitch(event.parameters?["pitch"])
        let fallbackMIDI = tuning.indices.contains(string - 1) ? tuning[string - 1] + fret : nil
        let midiPitch = realizedPitch?.midi ?? fallbackMIDI
        return Event(id: id, sourcePath: path, measure: measure, beat: beat, stringNumber: string, fret: fret,
                     midiPitch: midiPitch,
                     staffStep: realizedPitch?.staffStep ?? midiPitch.map(staffStep),
                     label: event.action ?? event.gesture ?? event.type ?? "event")
    }

    private static func pitch(_ value: JSONValue?) -> (midi: Int, staffStep: Int)? {
        guard case .object(let pitch) = value else { return nil }
        if let degree = integer(pitch["degree"]),
           let period = integer(pitch["period"]) {
            let midi = (period + 1) * 12 + degree
            return (midi, period * 7 + diatonicDegree(degree))
        }
        if case .number(let frequency) = pitch["frequencyHz"], frequency > 0 {
            let midi = Int((69 + 12 * log2(frequency / 440)).rounded())
            return (midi, staffStep(midi))
        }
        return nil
    }

    private static func staffStep(_ midi: Int) -> Int {
        let octave = midi / 12 - 1
        return octave * 7 + diatonicDegree(midi % 12)
    }

    private static func diatonicDegree(_ pitchClass: Int) -> Int {
        [0, 0, 1, 1, 2, 3, 3, 4, 4, 5, 5, 6][((pitchClass % 12) + 12) % 12]
    }

    private static func position(_ event: PerformanceEvent, beatsPerMeasure: Int) -> Double {
        guard let musical = event.at.musical else { return .greatestFiniteMagnitude }
        return Double((musical.measure - 1) * beatsPerMeasure + (musical.beat ?? 1) - 1) + number(musical.offset)
    }

    private static func stringNumber(_ target: String?) -> Int? {
        guard let target, target.hasPrefix("strings["), target.hasSuffix("]") else { return nil }
        return Int(target.dropFirst(8).dropLast())
    }

    private static func number(_ value: JSONValue?) -> Double {
        switch value {
        case .number(let number): return number
        case .string(let text):
            let parts = text.split(separator: "/")
            if parts.count == 2, let top = Double(parts[0]), let bottom = Double(parts[1]), bottom != 0 { return top / bottom }
            return Double(text) ?? 0
        default: return 0
        }
    }

    private static func integer(_ value: JSONValue?) -> Int? {
        guard case .number(let number) = value else { return nil }
        return Int(exactly: number)
    }

    private static func tuningMIDI(_ value: JSONValue?, count: Int) -> [Int] {
        guard case .array(let values) = value else { return Array(repeating: 60, count: count) }
        let pitches = values.compactMap { value -> Int? in guard case .string(let name) = value else { return nil }; return midi(name) }
        return pitches.count == count ? pitches : Array(repeating: 60, count: count)
    }

    private static func midi(_ name: String) -> Int? {
        let chars = Array(name)
        guard let letter = chars.first, let last = chars.last, let octave = Int(String(last)) else { return nil }
        let classes: [Character: Int] = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]
        guard var pitch = classes[Character(letter.uppercased())] else { return nil }
        if chars.count > 2 { if chars[1] == "#" { pitch += 1 }; if chars[1] == "b" { pitch -= 1 } }
        return (octave + 1) * 12 + pitch
    }
}
