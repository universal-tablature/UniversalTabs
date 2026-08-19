public struct ActuatorAddress: Sendable, Hashable {
    public let group: String
    public let member: String?
    public let position: Int?

    public init(group: String, member: String? = nil, position: Int? = nil) {
        self.group = group
        self.member = member
        self.position = position
    }
}

public struct ActuatorExpression: Sendable, Hashable {
    public let action: String
    public let target: ActuatorAddress
    public let duration: MusicalDuration
    public let soundingPitch: MusicalPitch?
    public let parameters: [String: MetadataValue]

    public init(
        action: String,
        target: ActuatorAddress,
        duration: MusicalDuration,
        soundingPitch: MusicalPitch? = nil,
        parameters: [String: MetadataValue] = [:]
    ) {
        self.action = action
        self.target = target
        self.duration = duration
        self.soundingPitch = soundingPitch
        self.parameters = parameters
    }
}

public enum TechniqueForm: String, Sendable, Hashable {
    case unary
    case transition
    case scoped
}

public struct TechniqueApplication: Sendable, Hashable {
    public let technique: String
    public let form: TechniqueForm
    public let operands: [MusicalExpression]
    public let parameters: [String: MetadataValue]

    public init(
        _ technique: String,
        form: TechniqueForm,
        operands: [MusicalExpression],
        parameters: [String: MetadataValue] = [:]
    ) {
        self.technique = technique
        self.form = form
        self.operands = operands
        self.parameters = parameters
    }
}

public struct MusicalExpression: Sendable, Hashable {
    public indirect enum Kind: Sendable, Hashable {
        case note(MusicalPitch, duration: MusicalDuration, constraints: [PerformanceConstraint])
        case rest(MusicalDuration)
        case chord(ChordSymbol, duration: MusicalDuration, constraints: [PerformanceConstraint])
        case actuator(ActuatorExpression)
        case sequence([MusicalExpression])
        case parallel([MusicalExpression])
        case reference(SemanticID)
        case repeated(count: Int, MusicalExpression)
        case technique(TechniqueApplication)
    }

    public let id: SemanticID
    public let kind: Kind
    public let annotations: SemanticAnnotations

    public init(id: SemanticID, kind: Kind, annotations: SemanticAnnotations = .init()) {
        self.id = id
        self.kind = kind
        self.annotations = annotations
    }

    public var duration: MusicalDuration? {
        switch kind {
        case .note(_, let duration, _), .rest(let duration), .chord(_, let duration, _):
            return duration
        case .actuator(let actuator):
            return actuator.duration
        case .sequence(let children):
            var total = MusicalDuration.zero
            for child in children {
                guard let duration = child.duration else { return nil }
                total = total + duration
            }
            return total
        case .parallel(let children):
            guard children.allSatisfy({ $0.duration != nil }) else { return nil }
            return children.compactMap(\.duration).max() ?? .zero
        case .reference:
            return nil
        case .repeated(let count, let expression):
            guard count >= 0, let duration = expression.duration else { return nil }
            return duration * count
        case .technique(let application):
            switch application.form {
            case .unary, .scoped:
                return application.operands.first?.duration
            case .transition:
                var total = MusicalDuration.zero
                for operand in application.operands {
                    guard let duration = operand.duration else { return nil }
                    total = total + duration
                }
                return total
            }
        }
    }

    public static func note(
        _ pitch: MusicalPitch,
        duration: MusicalDuration,
        constraints: [PerformanceConstraint] = [],
        id: SemanticID? = nil,
        metadata: [String: MetadataValue] = [:],
        fileID: String = #fileID,
        line: UInt = #line,
        column: UInt = #column
    ) -> Self {
        leaf(kind: .note(pitch, duration: duration, constraints: constraints), id: id, metadata: metadata, fileID: fileID, line: line, column: column, kindName: "note")
    }

    public static func rest(
        _ duration: MusicalDuration,
        id: SemanticID? = nil,
        metadata: [String: MetadataValue] = [:],
        fileID: String = #fileID,
        line: UInt = #line,
        column: UInt = #column
    ) -> Self {
        leaf(kind: .rest(duration), id: id, metadata: metadata, fileID: fileID, line: line, column: column, kindName: "rest")
    }

    public static func chord(
        _ chord: ChordSymbol,
        duration: MusicalDuration,
        constraints: [PerformanceConstraint] = [],
        id: SemanticID? = nil,
        metadata: [String: MetadataValue] = [:],
        fileID: String = #fileID,
        line: UInt = #line,
        column: UInt = #column
    ) -> Self {
        leaf(kind: .chord(chord, duration: duration, constraints: constraints), id: id, metadata: metadata, fileID: fileID, line: line, column: column, kindName: "chord")
    }

    public static func actuator(
        _ actuator: ActuatorExpression,
        id: SemanticID? = nil,
        metadata: [String: MetadataValue] = [:],
        fileID: String = #fileID,
        line: UInt = #line,
        column: UInt = #column
    ) -> Self {
        leaf(kind: .actuator(actuator), id: id, metadata: metadata, fileID: fileID, line: line, column: column, kindName: "actuator")
    }

    public static func sequence(_ children: [Self], id: SemanticID? = nil) -> Self {
        Self(id: id ?? .derived(kind: "sequence", components: children.map(\.id)), kind: .sequence(children))
    }

    public static func parallel(_ children: [Self], id: SemanticID? = nil) -> Self {
        Self(id: id ?? .derived(kind: "parallel", components: children.map(\.id)), kind: .parallel(children))
    }

    public static func reference(_ declaration: SemanticID, id: SemanticID? = nil) -> Self {
        Self(id: id ?? .derived(kind: "reference", components: [declaration]), kind: .reference(declaration))
    }

    public static func repeated(count: Int, _ expression: Self, id: SemanticID? = nil) -> Self {
        Self(id: id ?? .derived(kind: "repeat:\(count)", components: [expression.id]), kind: .repeated(count: count, expression))
    }

    public static func technique(_ application: TechniqueApplication, id: SemanticID? = nil) -> Self {
        Self(id: id ?? .derived(kind: "technique:\(application.technique):\(application.form.rawValue)", components: application.operands.map(\.id)), kind: .technique(application))
    }

    private static func leaf(
        kind: Kind,
        id: SemanticID?,
        metadata: [String: MetadataValue],
        fileID: String,
        line: UInt,
        column: UInt,
        kindName: String
    ) -> Self {
        let source = SourceRange.point(fileID: fileID, line: line, column: column)
        return Self(
            id: id ?? .source(kind: kindName, fileID: fileID, line: line, column: column),
            kind: kind,
            annotations: .init(metadata: metadata, source: source)
        )
    }
}

public struct TimeSignature: Sendable, Hashable {
    public let numerator: Int
    public let denominator: Int

    public init(_ numerator: Int, _ denominator: Int) {
        precondition(numerator > 0 && denominator > 0)
        self.numerator = numerator
        self.denominator = denominator
    }

    public var duration: MusicalDuration { MusicalDuration(numerator, denominator) }
}

public struct Bar: Sendable, Hashable {
    public let id: SemanticID
    public let expression: MusicalExpression
    public let meter: TimeSignature?
    public let annotations: SemanticAnnotations

    public init(_ expression: MusicalExpression, id: SemanticID? = nil, meter: TimeSignature? = nil, metadata: [String: MetadataValue] = [:]) {
        self.init(expression, id: id, meter: meter, metadata: metadata, source: nil)
    }

    public init(_ expression: MusicalExpression, id: SemanticID? = nil, meter: TimeSignature? = nil, metadata: [String: MetadataValue] = [:], source: SourceRange?) {
        self.id = id ?? .derived(kind: "bar", components: [expression.id])
        self.expression = expression
        self.meter = meter
        self.annotations = .init(metadata: metadata, source: source)
    }
}

public struct Phrase: Sendable, Hashable {
    public let id: SemanticID
    public let name: String
    public let expression: MusicalExpression
    public let bars: [Bar]
    public let annotations: SemanticAnnotations

    public init(_ name: String, id: SemanticID? = nil, bars: [Bar], metadata: [String: MetadataValue] = [:]) {
        self.init(name, id: id, bars: bars, metadata: metadata, source: nil)
    }

    public init(_ name: String, id: SemanticID? = nil, bars: [Bar], metadata: [String: MetadataValue] = [:], source: SourceRange?) {
        self.id = id ?? .named("phrase", name)
        self.name = name
        self.bars = bars
        self.expression = .sequence(bars.map(\.expression), id: .derived(kind: "phrase-body", components: bars.map(\.id)))
        self.annotations = .init(metadata: metadata, source: source)
    }

    public init(_ name: String, id: SemanticID? = nil, expression: MusicalExpression, metadata: [String: MetadataValue] = [:]) {
        self.init(name, id: id, expression: expression, metadata: metadata, source: nil)
    }

    public init(_ name: String, id: SemanticID? = nil, expression: MusicalExpression, metadata: [String: MetadataValue] = [:], source: SourceRange?) {
        self.id = id ?? .named("phrase", name)
        self.name = name
        self.expression = expression
        self.bars = []
        self.annotations = .init(metadata: metadata, source: source)
    }

    public var duration: MusicalDuration? { expression.duration }
}

public enum VoiceContent: Sendable, Hashable {
    case expression(MusicalExpression)
    case phrase(String)
    case reference(SemanticID)
}

public struct Voice: Sendable, Hashable {
    public let id: SemanticID
    public let name: String
    public let content: [VoiceContent]
    public let constraints: [PerformanceConstraint]
    public let lyrics: [LyricVerse]
    public let annotations: SemanticAnnotations

    public init(_ name: String, id: SemanticID? = nil, content: [VoiceContent], constraints: [PerformanceConstraint] = [], lyrics: [LyricVerse] = [], metadata: [String: MetadataValue] = [:]) {
        self.init(name, id: id, content: content, constraints: constraints, lyrics: lyrics, metadata: metadata, source: nil)
    }

    public init(_ name: String, id: SemanticID? = nil, content: [VoiceContent], constraints: [PerformanceConstraint] = [], lyrics: [LyricVerse] = [], metadata: [String: MetadataValue] = [:], source: SourceRange?) {
        self.id = id ?? .named("voice", name)
        self.name = name
        self.content = content
        self.constraints = constraints
        self.lyrics = lyrics
        self.annotations = .init(metadata: metadata, source: source)
    }
}

public struct Part: Sendable, Hashable {
    public let id: SemanticID
    public let instrument: String
    public let voices: [Voice]
    public let annotations: SemanticAnnotations

    public init(instrument: String, id: SemanticID? = nil, voices: [Voice], metadata: [String: MetadataValue] = [:]) {
        self.init(instrument: instrument, id: id, voices: voices, metadata: metadata, source: nil)
    }

    public init(instrument: String, id: SemanticID? = nil, voices: [Voice], metadata: [String: MetadataValue] = [:], source: SourceRange?) {
        self.id = id ?? .named("part", instrument)
        self.instrument = instrument
        self.voices = voices
        self.annotations = .init(metadata: metadata, source: source)
    }
}

public struct Section: Sendable, Hashable {
    public let id: SemanticID
    public let name: String
    public let expectedDuration: MusicalDuration?
    public let parts: [Part]
    public let meter: TimeSignature?
    public let annotations: SemanticAnnotations

    public var duration: MusicalDuration? { expectedDuration }

    public init(_ name: String, id: SemanticID? = nil, duration: MusicalDuration? = nil, meter: TimeSignature? = nil, parts: [Part], metadata: [String: MetadataValue] = [:]) {
        self.init(name, id: id, duration: duration, meter: meter, parts: parts, metadata: metadata, source: nil)
    }

    public init(_ name: String, id: SemanticID? = nil, duration: MusicalDuration? = nil, meter: TimeSignature? = nil, parts: [Part], metadata: [String: MetadataValue] = [:], source: SourceRange?) {
        self.id = id ?? .named("section", name)
        self.name = name
        self.expectedDuration = duration
        self.parts = parts
        self.meter = meter
        self.annotations = .init(metadata: metadata, source: source)
    }
}

public struct Composition: Sendable, Hashable {
    public let id: SemanticID
    public let title: String
    public let meter: TimeSignature
    public let tempo: Double
    public let scale: Scale?
    public let phrases: [Phrase]
    public let sections: [Section]
    public let main: MusicalExpression?
    public let annotations: SemanticAnnotations

    public init(title: String, id: SemanticID? = nil, meter: TimeSignature, tempo: Double, scale: Scale? = nil, phrases: [Phrase], sections: [Section], main: MusicalExpression? = nil, metadata: [String: MetadataValue] = [:]) {
        self.init(title: title, id: id, meter: meter, tempo: tempo, scale: scale, phrases: phrases, sections: sections, main: main, metadata: metadata, source: nil)
    }

    public init(title: String, id: SemanticID? = nil, meter: TimeSignature, tempo: Double, scale: Scale? = nil, phrases: [Phrase], sections: [Section], main: MusicalExpression? = nil, metadata: [String: MetadataValue] = [:], source: SourceRange?) {
        self.id = id ?? .named("composition", title)
        self.title = title
        self.meter = meter
        self.tempo = tempo
        self.scale = scale
        self.phrases = phrases
        self.sections = sections
        self.main = main
        self.annotations = .init(metadata: metadata, source: source)
    }
}

/// The stable boundary between high-level composition and an actuator-oriented format.
public protocol CompositionLowerer {
    associatedtype Output
    func lower(_ composition: Composition) throws -> Output
}
