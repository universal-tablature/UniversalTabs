import Foundation
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
    case scale(InstrumentID)
}

private extension InstrumentValue {
    var numericValue: Double? {
        switch self {
        case .integer(let value): Double(value)
        case .decimal(let value): value
        default: nil
        }
    }

    var integerValue: Int? {
        guard case .integer(let value) = self else { return nil }
        return value
    }
}

/// A named octave-repeating pitch collection published by an instrument catalogue.
/// Intervals are measured in cents above the tonic and exclude the repeated octave.
public struct InstrumentScaleDefinition: Sendable, Hashable {
    public let id: InstrumentID
    public let name: String
    public let centIntervals: [Int]

    public init(id: InstrumentID, name: String, centIntervals: [Int]) {
        self.id = id
        self.name = name
        self.centIntervals = centIntervals
    }

    public var kind: ScaleKind { .custom(name: name, centIntervals: centIntervals) }
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

/// One explicitly documented actuator configuration. A pattern contains `0` (open),
/// `1` (closed), `h` (half/partially closed), and optionally `x` (state-independent).
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

    public func overlaps(_ other: FingeringEntry) -> Bool {
        pattern.count == other.pattern.count && zip(pattern, other.pattern).allSatisfy { lhs, rhs in
            lhs == "x" || rhs == "x" || lhs == rhs
        }
    }
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

/// A pitch resolved from a continuous slide coordinate and a selected harmonic.
/// `namedPosition` is present only while the slide is within the authored tolerance
/// of one of the conventional position landmarks.
public struct SlidePitchResolution: Sendable, Hashable {
    public let pitch: AbsolutePitch
    public let frequency: Double
    public let harmonicPartial: Int
    public let slidePosition: Double
    public let namedPosition: String?
    public let positionDeviation: Double?
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
    public let fingering: InstrumentID?
    public let configuration: [String: InstrumentValue]

    public init(id: InstrumentID, name: String? = nil, model: InstrumentID, fingering: InstrumentID? = nil, configuration: [String: InstrumentValue] = [:]) {
        self.id = id; self.name = name; self.model = model; self.fingering = fingering; self.configuration = configuration
    }
}

public struct InstrumentCatalog: Sendable, Hashable {
    public let scales: [InstrumentScaleDefinition]
    public let tunings: [InstrumentTuningDefinition]
    public let fingerings: [FingeringDefinition]
    public let profiles: [InstrumentProfileDefinition]
    public let models: [InstrumentModelDefinition]
    public init(scales: [InstrumentScaleDefinition] = [], tunings: [InstrumentTuningDefinition] = [], fingerings: [FingeringDefinition] = [], profiles: [InstrumentProfileDefinition], models: [InstrumentModelDefinition]) {
        self.scales = scales; self.tunings = tunings; self.fingerings = fingerings; self.profiles = profiles; self.models = models
    }

    public func scale(_ id: InstrumentID) -> InstrumentScaleDefinition? {
        scales.first { $0.id == id }
    }

    /// Resolves a continuously adjustable slide against named position landmarks.
    /// Position values and harmonic bounds are catalog data, so this works without
    /// hard-coding a seven-position or equal-tempered trombone into the runtime.
    public func slidePitch(
        for modelID: InstrumentID,
        position: Double,
        harmonicPartial: Int,
        adjustmentCents: Double = 0
    ) -> SlidePitchResolution? {
        guard let model = models.first(where: { $0.id == modelID }),
              let slide = model.geometry.first(where: { $0.id == "slide" }),
              let fundamental = model.geometry.lazy.compactMap({ geometry -> AbsolutePitch? in
                  guard case .pitch(let pitch)? = geometry.properties["fundamental"] else { return nil }
                  return pitch
              }).first,
              let minimum = slide.properties["minimum"]?.numericValue,
              let maximum = slide.properties["maximum"]?.numericValue,
              position >= minimum,
              position <= maximum else { return nil }

        let harmonics = model.geometry.first { $0.id == "harmonics" }
        let lowestPartial = harmonics?.properties["lowestPartial"]?.integerValue ?? 1
        let highestPartial = harmonics?.properties["highestPartial"]?.integerValue ?? Int.max
        guard harmonicPartial >= lowestPartial, harmonicPartial <= highestPartial else { return nil }

        let landmarks = model.geometry.compactMap { geometry -> (value: Double, semitones: Double, name: String)? in
            guard geometry.id.hasPrefix("slidePosition"),
                  let value = geometry.properties["value"]?.numericValue,
                  let semitones = geometry.properties["semitoneOffset"]?.numericValue else { return nil }
            let name: String
            if case .text(let authoredName)? = geometry.properties["name"] {
                name = authoredName
            } else {
                name = geometry.id
            }
            return (value, semitones, name)
        }.sorted { $0.value < $1.value }
        guard !landmarks.isEmpty else { return nil }

        let semitoneOffset: Double
        if position <= landmarks[0].value {
            semitoneOffset = landmarks[0].semitones
        } else if position >= landmarks[landmarks.count - 1].value {
            semitoneOffset = landmarks[landmarks.count - 1].semitones
        } else {
            guard let upperIndex = landmarks.indices.dropFirst().first(where: { landmarks[$0].value >= position }) else { return nil }
            let lower = landmarks[upperIndex - 1]
            let upper = landmarks[upperIndex]
            let progress = (position - lower.value) / (upper.value - lower.value)
            semitoneOffset = lower.semitones + progress * (upper.semitones - lower.semitones)
        }

        let tolerance = slide.properties["positionTolerance"]?.numericValue ?? 0
        let nearest = landmarks.min { abs($0.value - position) < abs($1.value - position) }
        let deviation = nearest.map { position - $0.value }
        let namedPosition = deviation.flatMap { abs($0) <= tolerance ? nearest?.name : nil }
        let acousticCents = Double(fundamental.acousticCents)
            - semitoneOffset * 100
            + 1_200 * log2(Double(harmonicPartial))
            + adjustmentCents
        let pitch = AbsolutePitch(acousticCents: Int(acousticCents.rounded()))

        return SlidePitchResolution(
            pitch: pitch,
            frequency: fundamental.frequency() * pow(2, (-semitoneOffset * 100 + adjustmentCents) / 1_200) * Double(harmonicPartial),
            harmonicPartial: harmonicPartial,
            slidePosition: position,
            namedPosition: namedPosition,
            positionDeviation: namedPosition == nil ? nil : deviation
        )
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

    /// Resolves a physical configuration within a requested harmonic register.
    /// Entries without a register remain available as register-independent fallbacks.
    public func fingeringResult(for bitmap: String, register: Int, in fingeringID: InstrumentID) -> FingeringResult? {
        func candidates(_ id: InstrumentID, depth: Int, visited: Set<InstrumentID>) -> [(FingeringEntry, Int)] {
            guard !visited.contains(id), let map = fingerings.first(where: { $0.id == id }) else { return [] }
            let nextVisited = visited.union([id])
            let local = map.entries.filter {
                $0.matches(bitmap) && ($0.register == nil || $0.register == register)
            }.map { ($0, depth) }
            let inherited = map.parent.map { candidates($0, depth: depth - 1, visited: nextVisited) } ?? []
            return local + inherited
        }
        let matches = candidates(fingeringID, depth: 0, visited: [])
        guard let registerSpecificity = matches.map({ $0.0.register == register ? 1 : 0 }).max() else { return nil }
        let registered = matches.filter { ($0.0.register == register ? 1 : 0) == registerSpecificity }
        guard let specificity = registered.map({ $0.0.specificity }).max() else { return nil }
        let specific = registered.filter { $0.0.specificity == specificity }
        guard let nearestDepth = specific.map(\.1).max() else { return nil }
        let results = Set(specific.filter { $0.1 == nearestDepth }.map { $0.0.result })
        return results.count == 1 ? results.first : nil
    }

    /// Returns effective local and inherited entries, with a child entry replacing
    /// an inherited entry that has the same pattern and register.
    public func fingeringEntries(in fingeringID: InstrumentID) -> [FingeringEntry] {
        func collect(_ id: InstrumentID, visited: Set<InstrumentID>) -> [FingeringEntry] {
            guard !visited.contains(id), let map = fingerings.first(where: { $0.id == id }) else { return [] }
            var entries = map.parent.map { collect($0, visited: visited.union([id])) } ?? []
            for entry in map.entries {
                entries.removeAll { $0.pattern == entry.pattern && $0.register == entry.register }
                entries.append(entry)
            }
            return entries
        }
        return collect(fingeringID, visited: [])
    }

    /// Finds every documented physical configuration for a pitch, preferred first.
    public func fingerings(for pitch: AbsolutePitch, in fingeringID: InstrumentID) -> [FingeringEntry] {
        fingeringEntries(in: fingeringID).filter {
            if case .pitch(let value) = $0.result { return value == pitch }
            return false
        }.sorted {
            if $0.preference != $1.preference { return $0.preference == .preferred }
            if $0.specificity != $1.specificity { return $0.specificity > $1.specificity }
            if $0.register != $1.register { return ($0.register ?? 0) < ($1.register ?? 0) }
            return $0.pattern < $1.pattern
        }
    }
}
