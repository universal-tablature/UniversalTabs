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
}

public struct UTabMetadata: Codable, Sendable {
    public let version: String
    public let documentId: String?
    public let title: String?
    public let authors: [String]?
}

public struct PerformanceSetup: Codable, Sendable {
    public let profiles: [InstrumentProfile]
    public let instruments: [InstrumentInstance]
    public let performers: [Performer]?
    public let time: TimeSetup?
    public let sections: [SectionDefinition]?
    public let arrangement: [ArrangementEntry]?
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
    public let pitch: String?
    public let basePitch: String?
}

public struct ActuatorBit: Codable, Sendable {
    public let index: Int
    public let actuator: String
    public let effects: [ActuatorEffect]?
}

public struct ActuatorEffect: Codable, Sendable {
    public let target: String
    public let pitch: String?
}

public struct InstrumentInstance: Codable, Sendable {
    public let id: String
    public let name: String?
    public let profile: String
    public let configuration: [String: JSONValue]?
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
    public let target: JSONValue?
    public let parameter: String?
    public let parameters: [String: JSONValue]?
    public let techniques: [String]?
    public let changes: [StateChange]?
    public let curve: [JSONValue]?
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
