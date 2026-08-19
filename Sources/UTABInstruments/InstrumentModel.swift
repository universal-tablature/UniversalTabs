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

public enum FingeringResult: Sendable, Hashable {
    case pitch(AbsolutePitch)
    case effect(String)
}

public enum FingeringPreference: String, Sendable, Hashable {
    case preferred
    case alternate
}

/// One explicitly documented actuator configuration. A pattern contains `0`, `1`,
/// and optionally `x` for an actuator whose state does not affect this result.
public struct FingeringEntry: Sendable, Hashable {
    public let pattern: String
    public let result: FingeringResult
    public let register: Int?
    public let preference: FingeringPreference
    public let label: String?

    public init(pattern: String, result: FingeringResult, register: Int? = nil, preference: FingeringPreference = .preferred, label: String? = nil) {
        self.pattern = pattern
        self.result = result
        self.register = register
        self.preference = preference
        self.label = label
    }

    public func matches(_ bitmap: String) -> Bool {
        pattern.count == bitmap.count && zip(pattern, bitmap).allSatisfy { expected, actual in
            expected == "x" || expected == actual
        }
    }

    public var specificity: Int { pattern.reduce(0) { $1 == "x" ? $0 : $0 + 1 } }
}

public struct FingeringDefinition: Sendable, Hashable {
    public let id: InstrumentID
    public let name: String
    public let model: InstrumentID
    public let actuatorGroup: String
    public let bitOrder: [String]
    public let parent: InstrumentID?
    public let entries: [FingeringEntry]

    public init(id: InstrumentID, name: String, model: InstrumentID, actuatorGroup: String, bitOrder: [String], parent: InstrumentID? = nil, entries: [FingeringEntry]) {
        self.id = id; self.name = name; self.model = model; self.actuatorGroup = actuatorGroup
        self.bitOrder = bitOrder; self.parent = parent; self.entries = entries
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
    public let fingerings: [InstrumentID]
    public let defaultFingering: InstrumentID?
    public let defaults: [String: InstrumentValue]

    public init(id: InstrumentID, name: String, profile: InstrumentID, geometry: [InstrumentGeometry] = [], tunings: [InstrumentID] = [], defaultTuning: InstrumentID? = nil, fingerings: [InstrumentID] = [], defaultFingering: InstrumentID? = nil, defaults: [String: InstrumentValue] = [:]) {
        self.id = id; self.name = name; self.profile = profile
        self.geometry = geometry; self.tunings = tunings; self.defaultTuning = defaultTuning
        self.fingerings = fingerings; self.defaultFingering = defaultFingering; self.defaults = defaults
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
    public let fingerings: [FingeringDefinition]
    public let profiles: [InstrumentProfileDefinition]
    public let models: [InstrumentModelDefinition]
    public init(tunings: [InstrumentTuningDefinition] = [], fingerings: [FingeringDefinition] = [], profiles: [InstrumentProfileDefinition], models: [InstrumentModelDefinition]) {
        self.tunings = tunings; self.fingerings = fingerings; self.profiles = profiles; self.models = models
    }

    /// Returns nil for combinations the selected map does not claim to understand.
    public func fingeringResult(for bitmap: String, in fingeringID: InstrumentID) -> FingeringResult? {
        func candidates(_ id: InstrumentID, depth: Int, visited: Set<InstrumentID>) -> [(FingeringEntry, Int)] {
            guard !visited.contains(id), let map = fingerings.first(where: { $0.id == id }) else { return [] }
            let nextVisited = visited.union([id])
            let local = map.entries.filter { $0.matches(bitmap) }.map { ($0, depth) }
            let inherited = map.parent.map { candidates($0, depth: depth - 1, visited: nextVisited) } ?? []
            return local + inherited
        }
        let matches = candidates(fingeringID, depth: 0, visited: [])
        guard let specificity = matches.map({ $0.0.specificity }).max() else { return nil }
        let specific = matches.filter { $0.0.specificity == specificity }
        guard let nearestDepth = specific.map(\.1).max() else { return nil }
        let results = Set(specific.filter { $0.1 == nearestDepth }.map { $0.0.result })
        return results.count == 1 ? results.first : nil
    }
}
