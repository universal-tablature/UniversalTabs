import UTABComposerCore

public struct InstrumentID: RawRepresentable, Sendable, Hashable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }
}

public enum InstrumentValue: Sendable, Hashable {
    case integer(Int)
    case decimal(Double)
    case boolean(Bool)
    case text(String)
    case pitch(AbsolutePitch)
    case pitches([AbsolutePitch])
    case list([InstrumentValue])
    case object([String: InstrumentValue])
}

public enum ActuatorControl: Sendable, Hashable {
    case discrete
    case continuous(range: ClosedRange<Double>?)
    case binary
    case orderedBitset(width: Int)
}

public enum ActuatorCardinality: Sendable, Hashable {
    case unconstrained
    case exact(Int)
    case range(ClosedRange<Int>)

    public func contains(_ count: Int) -> Bool {
        switch self {
        case .unconstrained: true
        case .exact(let expected): count == expected
        case .range(let range): range.contains(count)
        }
    }
}

public struct ActuatorGroup: Sendable, Hashable {
    public let id: String
    public let cardinality: ActuatorCardinality
    public let control: ActuatorControl
    public let members: [ActuatorMember]

    public init(_ id: String, cardinality: ActuatorCardinality = .unconstrained, control: ActuatorControl = .discrete, members: [ActuatorMember] = []) {
        self.id = id; self.cardinality = cardinality; self.control = control; self.members = members
    }

    public init(_ id: String, count: Int, control: ActuatorControl = .discrete, members: [ActuatorMember] = []) {
        self.init(id, cardinality: .exact(count), control: control, members: members)
    }
}

/// One playable course. A course may contain one string, doubled unison strings,
/// or strings tuned in octaves. Course order is preserved and instrument-defined.
public struct TuningCourse: Sendable, Hashable {
    public let pitches: [AbsolutePitch]
    public init(_ pitches: [AbsolutePitch]) { self.pitches = pitches }
}

public struct InstrumentTuningDefinition: Sendable, Hashable {
    public let id: InstrumentID
    public let name: String
    public let courses: [TuningCourse]
    public let tags: Set<String>

    public init(id: InstrumentID, name: String, courses: [TuningCourse], tags: Set<String> = []) {
        self.id = id; self.name = name; self.courses = courses; self.tags = tags
    }
}

public struct ActuatorMember: Sendable, Hashable {
    public let id: String
    public let pitch: AbsolutePitch?
    public init(_ id: String, pitch: AbsolutePitch? = nil) { self.id = id; self.pitch = pitch }
}

public struct InstrumentGeometry: Sendable, Hashable {
    public let id: String
    public let properties: [String: InstrumentValue]
    public init(_ id: String, properties: [String: InstrumentValue]) { self.id = id; self.properties = properties }
}

public struct Interaction: Sendable, Hashable {
    public let id: String
    public let targets: [String]
    public let effectors: [String]
    public init(_ id: String, targets: [String], effectors: [String] = []) {
        self.id = id; self.targets = targets; self.effectors = effectors
    }
}

public struct InstrumentTechnique: Sendable, Hashable {
    public let id: String
    public let target: String?
    public let parameters: [String: InstrumentValue]
    public init(_ id: String, target: String? = nil, parameters: [String: InstrumentValue] = [:]) {
        self.id = id; self.target = target; self.parameters = parameters
    }
}

/// A reusable capability contract. Profiles describe how an instrument may be controlled,
/// but do not provide a concrete tuning or construction.
public struct InstrumentProfileDefinition: Sendable, Hashable {
    public let id: InstrumentID
    public let version: String
    public let actuators: [ActuatorGroup]
    public let interactions: [Interaction]
    public let techniques: [InstrumentTechnique]

    public init(id: InstrumentID, version: String, actuators: [ActuatorGroup], interactions: [Interaction], techniques: [InstrumentTechnique] = []) {
        self.id = id; self.version = version; self.actuators = actuators
        self.interactions = interactions; self.techniques = techniques
    }
}

/// A concrete instrument type based on a capability profile, including geometry and defaults.
public struct InstrumentModelDefinition: Sendable, Hashable {
    public let id: InstrumentID
    public let name: String
    public let profile: InstrumentID
    public let geometry: [InstrumentGeometry]
    public let tunings: [InstrumentID]
    public let defaultTuning: InstrumentID?
    public let defaults: [String: InstrumentValue]

    public init(id: InstrumentID, name: String, profile: InstrumentID, geometry: [InstrumentGeometry] = [], tunings: [InstrumentID] = [], defaultTuning: InstrumentID? = nil, defaults: [String: InstrumentValue] = [:]) {
        self.id = id; self.name = name; self.profile = profile
        self.geometry = geometry; self.tunings = tunings; self.defaultTuning = defaultTuning; self.defaults = defaults
    }
}

/// A configured instrument used by a project or arrangement.
public struct InstrumentInstanceDefinition: Sendable, Hashable {
    public let id: InstrumentID
    public let name: String?
    public let model: InstrumentID
    public let configuration: [String: InstrumentValue]

    public init(id: InstrumentID, name: String? = nil, model: InstrumentID, configuration: [String: InstrumentValue] = [:]) {
        self.id = id; self.name = name; self.model = model; self.configuration = configuration
    }
}

public struct InstrumentCatalog: Sendable, Hashable {
    public let tunings: [InstrumentTuningDefinition]
    public let profiles: [InstrumentProfileDefinition]
    public let models: [InstrumentModelDefinition]
    public init(tunings: [InstrumentTuningDefinition] = [], profiles: [InstrumentProfileDefinition], models: [InstrumentModelDefinition]) {
        self.tunings = tunings; self.profiles = profiles; self.models = models
    }
}
