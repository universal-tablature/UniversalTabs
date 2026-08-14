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

public struct ActuatorGroup: Sendable, Hashable {
    public let id: String
    public let count: Int
    public let control: ActuatorControl
    public let members: [ActuatorMember]

    public init(_ id: String, count: Int, control: ActuatorControl = .discrete, members: [ActuatorMember] = []) {
        self.id = id; self.count = count; self.control = control; self.members = members
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
    public let defaults: [String: InstrumentValue]

    public init(id: InstrumentID, name: String, profile: InstrumentID, geometry: [InstrumentGeometry] = [], defaults: [String: InstrumentValue] = [:]) {
        self.id = id; self.name = name; self.profile = profile
        self.geometry = geometry; self.defaults = defaults
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
    public let profiles: [InstrumentProfileDefinition]
    public let models: [InstrumentModelDefinition]
    public init(profiles: [InstrumentProfileDefinition], models: [InstrumentModelDefinition]) {
        self.profiles = profiles; self.models = models
    }
}
