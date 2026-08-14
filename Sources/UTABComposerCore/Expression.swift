public indirect enum MusicalExpression: Sendable, Hashable {
    case note(MusicalPitch, duration: MusicalDuration, constraints: [PerformanceConstraint] = [])
    case rest(MusicalDuration)
    case chord(ChordSymbol, duration: MusicalDuration, constraints: [PerformanceConstraint] = [])
    case sequence([MusicalExpression])
    case parallel([MusicalExpression])

    public var duration: MusicalDuration {
        switch self {
        case .note(_, let duration, _), .rest(let duration), .chord(_, let duration, _):
            duration
        case .sequence(let children):
            children.reduce(.zero) { $0 + $1.duration }
        case .parallel(let children):
            children.map(\.duration).max() ?? .zero
        }
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
    public let expression: MusicalExpression
    public init(_ expression: MusicalExpression) { self.expression = expression }
}

public struct Phrase: Sendable, Hashable {
    public let name: String
    public let bars: [Bar]
    public init(_ name: String, bars: [Bar]) { self.name = name; self.bars = bars }
    public var duration: MusicalDuration { bars.reduce(.zero) { $0 + $1.expression.duration } }
}

public enum VoiceContent: Sendable, Hashable {
    case expression(MusicalExpression)
    case phrase(String)
}

public struct Voice: Sendable, Hashable {
    public let name: String
    public let content: [VoiceContent]
    public let constraints: [PerformanceConstraint]

    public init(_ name: String, content: [VoiceContent], constraints: [PerformanceConstraint] = []) {
        self.name = name; self.content = content; self.constraints = constraints
    }
}

public struct Part: Sendable, Hashable {
    public let instrument: String
    public let voices: [Voice]
    public init(instrument: String, voices: [Voice]) { self.instrument = instrument; self.voices = voices }
}

public struct Section: Sendable, Hashable {
    public let name: String
    public let duration: MusicalDuration
    public let parts: [Part]

    public init(_ name: String, duration: MusicalDuration, parts: [Part]) {
        self.name = name; self.duration = duration; self.parts = parts
    }
}

public struct Composition: Sendable, Hashable {
    public let title: String
    public let meter: TimeSignature
    public let tempo: Double
    public let scale: Scale?
    public let phrases: [Phrase]
    public let sections: [Section]

    public init(title: String, meter: TimeSignature, tempo: Double, scale: Scale? = nil, phrases: [Phrase], sections: [Section]) {
        self.title = title; self.meter = meter; self.tempo = tempo; self.scale = scale
        self.phrases = phrases; self.sections = sections
    }
}

/// The stable boundary between high-level composition and an actuator-oriented format.
public protocol CompositionLowerer {
    associatedtype Output
    func lower(_ composition: Composition) throws -> Output
}
