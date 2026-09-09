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

public indirect enum JSONValue: Codable, Sendable, Equatable {
    case null
    case boolean(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .boolean(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .boolean(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

public struct UTabDocument: Codable, Sendable {
    public let utab: UTabMetadata
    public let setup: PerformanceSetup
    public let tracks: [EventTrack]
    public let harmony: [HarmonyEvent]?
    /// Optional structural provenance for authoring tools. Playback consumers can ignore this map.
    public let editingMap: UTabEditingMap?
}

public struct UTabEditingMap: Codable, Sendable {
    public let version: Int
    public let occurrences: [UTabEditingOccurrence]
    public let containers: [UTabEditingContainer]
    public let measures: [UTabEditingMeasure]
    public let scale: UTabEditingScale?

    public init(
        version: Int = 1,
        occurrences: [UTabEditingOccurrence],
        containers: [UTabEditingContainer],
        measures: [UTabEditingMeasure],
        scale: UTabEditingScale? = nil
    ) {
        self.version = version
        self.occurrences = occurrences
        self.containers = containers
        self.measures = measures
        self.scale = scale
    }
}

/// Optional authoring context used by editors to present scale-relative material.
public struct UTabEditingScale: Codable, Sendable {
    public let tonic: String
    public let name: String
    public let centIntervals: [Int]

    public init(tonic: String, name: String, centIntervals: [Int]) {
        self.tonic = tonic
        self.name = name
        self.centIntervals = centIntervals
    }
}

public struct UTabEditingPitchRepresentation: Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case absolute
        case scaleRelative
    }

    public let kind: Kind
    public let letter: String?
    public let accidental: Int?
    public let tuningOffsetCents: Int?
    public let degree: Int?
    public let alteration: Int?
    public let octave: Int
    public let resolvedMIDIPitch: Int?

    public init(
        kind: Kind,
        letter: String? = nil,
        accidental: Int? = nil,
        tuningOffsetCents: Int? = nil,
        degree: Int? = nil,
        alteration: Int? = nil,
        octave: Int,
        resolvedMIDIPitch: Int? = nil
    ) {
        self.kind = kind
        self.letter = letter
        self.accidental = accidental
        self.tuningOffsetCents = tuningOffsetCents
        self.degree = degree
        self.alteration = alteration
        self.octave = octave
        self.resolvedMIDIPitch = resolvedMIDIPitch
    }
}

public struct UTabEditingOccurrence: Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case note
        case rest
        case actuator
    }

    public let occurrenceID: String
    public let definitionID: String
    public let kind: Kind
    public let trackID: String
    public let sectionID: String
    public let at: EventTime
    public let duration: EventDuration
    public let pitchRepresentation: UTabEditingPitchRepresentation?
    public let source: SourceReference?

    public init(
        occurrenceID: String,
        definitionID: String,
        kind: Kind,
        trackID: String,
        sectionID: String,
        at: EventTime,
        duration: EventDuration,
        pitchRepresentation: UTabEditingPitchRepresentation? = nil,
        source: SourceReference? = nil
    ) {
        self.occurrenceID = occurrenceID
        self.definitionID = definitionID
        self.kind = kind
        self.trackID = trackID
        self.sectionID = sectionID
        self.at = at
        self.duration = duration
        self.pitchRepresentation = pitchRepresentation
        self.source = source
    }
}

public struct UTabEditingContainer: Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case sequence
        case parallel
        case technique
        case explicitBar
    }

    public let occurrenceID: String
    public let definitionID: String
    public let kind: Kind
    public let trackID: String
    public let sectionID: String
    public let childOccurrenceIDs: [String]
    public let source: SourceReference?

    public init(
        occurrenceID: String,
        definitionID: String,
        kind: Kind,
        trackID: String,
        sectionID: String,
        childOccurrenceIDs: [String],
        source: SourceReference? = nil
    ) {
        self.occurrenceID = occurrenceID
        self.definitionID = definitionID
        self.kind = kind
        self.trackID = trackID
        self.sectionID = sectionID
        self.childOccurrenceIDs = childOccurrenceIDs
        self.source = source
    }
}

public struct UTabEditingMeasure: Codable, Sendable {
    public let id: String
    public let trackID: String
    public let sectionID: String
    public let measure: Int
    public let contributorOccurrenceIDs: [String]
    /// Present only when the measure comes from an authored `bar { ... }` container.
    public let explicitBarSource: SourceReference?

    public init(
        id: String,
        trackID: String,
        sectionID: String,
        measure: Int,
        contributorOccurrenceIDs: [String],
        explicitBarSource: SourceReference? = nil
    ) {
        self.id = id
        self.trackID = trackID
        self.sectionID = sectionID
        self.measure = measure
        self.contributorOccurrenceIDs = contributorOccurrenceIDs
        self.explicitBarSource = explicitBarSource
    }
}

public struct HarmonyEvent: Codable, Sendable {
    public let id: String?
    public let section: String?
    public let at: EventTime
    public let duration: EventDuration?
    public let value: HarmonyValue
    public let source: [String: JSONValue]?
}

public struct HarmonyValue: Codable, Sendable {
    public let symbol: String
    public let root: String?
    public let quality: String?
    public let bass: String?
}

public struct UTabMetadata: Codable, Sendable {
    public let version: String
    public let documentId: String?
    public let title: String?
    public let authors: [String]?
    public let work: UTabWorkMetadata?
    public let movement: UTabMovementMetadata?
    public let contributors: [UTabContributor]?
    public let rights: [UTabRights]?
    public let source: String?
    public let relations: [String]?
    public let encoding: UTabEncodingMetadata?
    public let miscellaneous: [String: String]?
}

public struct UTabWorkMetadata: Codable, Sendable {
    public let number: String?
    public let title: String?
    public let opus: String?
}

public struct UTabMovementMetadata: Codable, Sendable {
    public let number: String?
    public let title: String?
}

public struct UTabContributor: Codable, Sendable {
    public let name: String
    public let role: String?
}

public struct UTabRights: Codable, Sendable {
    public let text: String
    public let type: String?
}

public struct UTabEncodingMetadata: Codable, Sendable {
    public let date: String?
    public let software: [String]?
    public let encoders: [String]?
    public let description: String?
}

public struct PerformanceSetup: Codable, Sendable {
    public let profiles: [InstrumentProfile]
    public let instruments: [InstrumentInstance]
    public let performers: [Performer]?
    public let time: TimeSetup?
    public let sections: [SectionDefinition]?
    public let arrangement: [ArrangementEntry]?
    public let tunings: [TuningDefinition]?
}

public struct TuningDefinition: Codable, Sendable {
    public let id: String
    public let type: String
    public let periodRatio: String
    public let divisions: Int?
    public let degrees: [String]?
    public let reference: TuningReference
    public let names: [String: Int]?
}

public struct TuningReference: Codable, Sendable {
    public let pitch: TuningCoordinate
    public let frequencyHz: Double
}

public struct TuningCoordinate: Codable, Sendable {
    public let degree: Int
    public let period: Int
}

public struct PitchValue: Codable, Sendable {
    public let frequencyHz: Double?
    public let tuning: String?
    public let degree: Int?
    public let name: String?
    public let period: Int?
    public let legacyName: String?

    public init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let value = try? single.decode(String.self) {
            frequencyHz = nil; tuning = nil; degree = nil; name = nil; period = nil; legacyName = value
            return
        }
        let value = try single.decode(CanonicalPitch.self)
        frequencyHz = value.frequencyHz; tuning = value.tuning; degree = value.degree
        name = value.name; period = value.period; legacyName = nil
    }

    public func encode(to encoder: Encoder) throws {
        var single = encoder.singleValueContainer()
        if let legacyName { try single.encode(legacyName) }
        else { try single.encode(CanonicalPitch(frequencyHz: frequencyHz, tuning: tuning, degree: degree, name: name, period: period)) }
    }

    private struct CanonicalPitch: Codable {
        let frequencyHz: Double?
        let tuning: String?
        let degree: Int?
        let name: String?
        let period: Int?
    }
}

public struct SectionDefinition: Codable, Sendable {
    public let id: String
    public let name: String?
    public let role: String?
    public let length: SectionLength
    public let meterMap: [MeterChange]?
}

public struct SectionLength: Codable, Sendable {
    public let measures: Int
}

public struct ArrangementEntry: Codable, Sendable {
    public let id: String
    public let section: String
    public let playCount: Int?

    public var effectivePlayCount: Int { playCount ?? 1 }
}

public struct InstrumentProfile: Codable, Sendable {
    public let id: String
    public let name: String?
    public let profileVersion: String?
    public let source: String?
    public let actuators: [String: ActuatorDefinition]?
    public let geometry: [String: JSONValue]?
    public let interactions: [String: JSONValue]?
    public let techniques: [String: JSONValue]?
    public let performerDefaults: [String: JSONValue]?
    public let constraints: [JSONValue]?
}

public struct ActuatorDefinition: Codable, Sendable {
    public let type: String?
    public let count: Int?
    public let representation: String?
    public let width: Int?
    public let positionControl: String?
    public let directlyActuated: Bool?
    public let range: [Double]?
    public let members: [ActuatorMember]?
    public let bits: [ActuatorBit]?
    public let bitValue: [String: String]?
}

public struct ActuatorMember: Codable, Sendable {
    public let id: String
    public let type: String?
    public let pitch: PitchValue?
    public let basePitch: PitchValue?
}

public struct ActuatorBit: Codable, Sendable {
    public let index: Int
    public let actuator: String
    public let effects: [ActuatorEffect]?
}

public struct ActuatorEffect: Codable, Sendable {
    public let target: String
    public let pitch: PitchValue?
}

public struct InstrumentInstance: Codable, Sendable {
    public let id: String
    public let name: String?
    public let profile: String
    public let configuration: [String: JSONValue]?
    public let realization: InstrumentRealization?
}

public struct InstrumentRealization: Codable, Sendable {
    public let midi: MIDIRealization?
}

public struct MIDIRealization: Codable, Sendable {
    /// General MIDI program number in the documented 1...128 range.
    public let program: Int?
    public let percussion: Bool?
}

public struct Performer: Codable, Sendable {
    public let id: String
    public let name: String?
}

public struct TimeSetup: Codable, Sendable {
    public let meter: MeterChange?
    public let tempo: TempoChange?
    public let meterMap: [MeterChange]?
    public let tempoMap: [TempoChange]?
    public let absoluteOrigin: Quantity?
}

public struct MeterChange: Codable, Sendable {
    public let at: [String: JSONValue]?
    public let numerator: Int
    public let denominator: Int
}

public struct TempoChange: Codable, Sendable {
    public let at: [String: JSONValue]?
    public let quarterNotesPerMinute: Double
}

public struct Quantity: Codable, Sendable {
    public let value: Double
    public let unit: String
}

public struct EventTrack: Codable, Sendable {
    public let id: String
    public let name: String?
    public let instrument: String
    public let performer: String?
    public let role: String?
    public let events: [PerformanceEvent]?
    public let parts: [TrackPart]?
}

public struct TrackPart: Codable, Sendable {
    public let section: String?
    public let entry: String?
    public let mode: PartMode?
    public let source: SourceReference?
    public let events: [PerformanceEvent]
}

public enum PartMode: String, Codable, Sendable {
    case replace
    case overlay
}

public struct PerformanceEvent: Codable, Sendable {
    public let id: String?
    public let at: EventTime
    public let duration: EventDuration?
    public let type: String?
    public let action: String?
    public let gesture: String?
    public let target: String?
    public let targets: [String]?
    public let parameter: String?
    public let parameters: [String: JSONValue]?
    public let techniques: [String]?
    public let source: SourceReference?
    public let changes: [StateChange]?
    public let curve: [JSONValue]?
}

public struct SourceReference: Codable, Sendable {
    public let id: String
    public let file: String?
    public let line: Int?
    public let column: Int?
    public let endLine: Int?
    public let endColumn: Int?
    public let ancestry: [String]?
    public let path: [String]?
}

public struct StateChange: Codable, Sendable {
    public let target: String
    public let parameter: String
    public let value: JSONValue
}

public struct EventTime: Codable, Sendable {
    public let musical: MusicalPosition?
    public let absolute: Quantity?
}

public struct MusicalPosition: Codable, Sendable {
    public let measure: Int
    public let beat: Int?
    public let offset: JSONValue?

    public init(measure: Int, beat: Int?, offset: JSONValue? = nil) {
        self.measure = measure
        self.beat = beat
        self.offset = offset
    }
}

public struct EventDuration: Codable, Sendable {
    public let quarterNotes: JSONValue?
    public let value: Double?
    public let unit: String?
}
