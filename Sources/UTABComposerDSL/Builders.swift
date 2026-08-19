@_exported import UTABComposerCore

@resultBuilder
public enum ExpressionBuilder {
    public static func buildBlock(_ components: MusicalExpression...) -> MusicalExpression { .sequence(components) }
    public static func buildArray(_ components: [MusicalExpression]) -> MusicalExpression { .sequence(components) }
    public static func buildOptional(_ component: MusicalExpression?) -> MusicalExpression { component ?? .sequence([]) }
    public static func buildEither(first component: MusicalExpression) -> MusicalExpression { component }
    public static func buildEither(second component: MusicalExpression) -> MusicalExpression { component }
}

public func Rest(
    _ duration: MusicalDuration,
    fileID: String = #fileID,
    line: UInt = #line,
    column: UInt = #column
) -> MusicalExpression {
    .rest(duration, fileID: fileID, line: line, column: column)
}

public func Note(
    _ pitch: MusicalPitch,
    _ duration: MusicalDuration,
    constraints: [PerformanceConstraint] = [],
    fileID: String = #fileID,
    line: UInt = #line,
    column: UInt = #column
) -> MusicalExpression {
    .note(pitch, duration: duration, constraints: constraints, fileID: fileID, line: line, column: column)
}

public func Degree(
    _ degree: Int,
    octave: Int,
    _ duration: MusicalDuration,
    fileID: String = #fileID,
    line: UInt = #line,
    column: UInt = #column
) -> MusicalExpression {
    Note(.scaleDegree(degree, octave: octave), duration, fileID: fileID, line: line, column: column)
}

public func Chord(
    _ root: PitchClass,
    _ quality: ChordQuality,
    _ duration: MusicalDuration,
    constraints: [PerformanceConstraint] = [],
    fileID: String = #fileID,
    line: UInt = #line,
    column: UInt = #column
) -> MusicalExpression {
    .chord(.init(root, quality), duration: duration, constraints: constraints, fileID: fileID, line: line, column: column)
}

public func DegreeChord(
    _ degree: Int,
    _ quality: ChordQuality,
    _ duration: MusicalDuration,
    constraints: [PerformanceConstraint] = [],
    fileID: String = #fileID,
    line: UInt = #line,
    column: UInt = #column
) -> MusicalExpression {
    .chord(
        .init(scaleDegree: degree, quality),
        duration: duration,
        constraints: constraints,
        fileID: fileID,
        line: line,
        column: column
    )
}

public func Parallel(@ExpressionBuilder _ content: () -> MusicalExpression) -> MusicalExpression {
    let expression = content()
    switch expression.kind {
    case .sequence(let children): return MusicalExpression.parallel(children)
    default: return MusicalExpression.parallel([expression])
    }
}

public func Repeat(_ count: Int, _ expression: MusicalExpression) -> MusicalExpression {
    .repeated(count: count, expression)
}

public func Actuate(
    _ action: String,
    group: String,
    member: String? = nil,
    position: Int? = nil,
    duration: MusicalDuration,
    soundingPitch: MusicalPitch? = nil,
    parameters: [String: MetadataValue] = [:],
    fileID: String = #fileID,
    line: UInt = #line,
    column: UInt = #column
) -> MusicalExpression {
    .actuator(
        .init(
            action: action,
            target: .init(group: group, member: member, position: position),
            duration: duration,
            soundingPitch: soundingPitch,
            parameters: parameters
        ),
        fileID: fileID,
        line: line,
        column: column
    )
}

public func Apply(
    _ technique: String,
    form: TechniqueForm = .unary,
    parameters: [String: MetadataValue] = [:],
    to operands: [MusicalExpression]
) -> MusicalExpression {
    .technique(.init(technique, form: form, operands: operands, parameters: parameters))
}

public func C4(_ duration: MusicalDuration, constraints: [PerformanceConstraint] = [], fileID: String = #fileID, line: UInt = #line, column: UInt = #column) -> MusicalExpression {
    Note(.absolute(.init(.c, octave: 4)), duration, constraints: constraints, fileID: fileID, line: line, column: column)
}
public func D4(_ duration: MusicalDuration, constraints: [PerformanceConstraint] = [], fileID: String = #fileID, line: UInt = #line, column: UInt = #column) -> MusicalExpression {
    Note(.absolute(.init(.d, octave: 4)), duration, constraints: constraints, fileID: fileID, line: line, column: column)
}
public func E4(_ duration: MusicalDuration, constraints: [PerformanceConstraint] = [], fileID: String = #fileID, line: UInt = #line, column: UInt = #column) -> MusicalExpression {
    Note(.absolute(.init(.e, octave: 4)), duration, constraints: constraints, fileID: fileID, line: line, column: column)
}
public func F4(_ duration: MusicalDuration, constraints: [PerformanceConstraint] = [], fileID: String = #fileID, line: UInt = #line, column: UInt = #column) -> MusicalExpression {
    Note(.absolute(.init(.f, octave: 4)), duration, constraints: constraints, fileID: fileID, line: line, column: column)
}
public func G4(_ duration: MusicalDuration, constraints: [PerformanceConstraint] = [], fileID: String = #fileID, line: UInt = #line, column: UInt = #column) -> MusicalExpression {
    Note(.absolute(.init(.g, octave: 4)), duration, constraints: constraints, fileID: fileID, line: line, column: column)
}
public func A4(_ duration: MusicalDuration, constraints: [PerformanceConstraint] = [], fileID: String = #fileID, line: UInt = #line, column: UInt = #column) -> MusicalExpression {
    Note(.absolute(.init(.a, octave: 4)), duration, constraints: constraints, fileID: fileID, line: line, column: column)
}

public extension MusicalDuration {
    static func dotted(_ base: Self) -> Self { base + Self(base.wholeNotes.numerator, base.wholeNotes.denominator * 2) }
}

@resultBuilder
public enum BarBuilder {
    public static func buildBlock(_ components: Bar...) -> [Bar] { components }
    public static func buildArray(_ components: [[Bar]]) -> [Bar] { components.flatMap { $0 } }
}

public func Bar(@ExpressionBuilder _ content: () -> MusicalExpression) -> UTABComposerCore.Bar {
    .init(content())
}

public func Phrase(_ name: String, @BarBuilder _ content: () -> [UTABComposerCore.Bar]) -> UTABComposerCore.Phrase {
    .init(name, bars: content())
}

@resultBuilder
public enum VoiceContentBuilder {
    public static func buildBlock(_ components: VoiceContent...) -> [VoiceContent] { components }
    public static func buildArray(_ components: [[VoiceContent]]) -> [VoiceContent] { components.flatMap { $0 } }
    public static func buildExpression(_ content: VoiceContent) -> VoiceContent { content }
    public static func buildExpression(_ expression: MusicalExpression) -> VoiceContent { .expression(expression) }
}

public func Play(_ phrase: String) -> VoiceContent { .phrase(phrase) }
public func Play(_ declaration: SemanticID) -> VoiceContent { .reference(declaration) }

public func Voice(
    _ name: String,
    constraints: [PerformanceConstraint] = [],
    lyrics: [LyricVerse] = [],
    @VoiceContentBuilder _ content: () -> [VoiceContent]
) -> UTABComposerCore.Voice {
    .init(name, content: content(), constraints: constraints, lyrics: lyrics)
}

@resultBuilder
public enum VoiceBuilder {
    public static func buildBlock(_ components: UTABComposerCore.Voice...) -> [UTABComposerCore.Voice] { components }
}

public func Instrument(_ name: String, @VoiceBuilder _ content: () -> [UTABComposerCore.Voice]) -> Part {
    .init(instrument: name, voices: content())
}

@resultBuilder
public enum PartBuilder {
    public static func buildBlock(_ components: Part...) -> [Part] { components }
}

public func Section(
    _ name: String,
    duration: MusicalDuration? = nil,
    meter: TimeSignature? = nil,
    @PartBuilder _ content: () -> [Part]
) -> UTABComposerCore.Section {
    .init(name, duration: duration, meter: meter, parts: content())
}

public enum SongComponent: Sendable {
    case phrase(UTABComposerCore.Phrase)
    case section(UTABComposerCore.Section)
}

@resultBuilder
public enum SongBuilder {
    public static func buildBlock(_ components: SongComponent...) -> [SongComponent] { components }
    public static func buildExpression(_ phrase: UTABComposerCore.Phrase) -> SongComponent { .phrase(phrase) }
    public static func buildExpression(_ section: UTABComposerCore.Section) -> SongComponent { .section(section) }
}

public func Song(
    _ title: String,
    meter: TimeSignature,
    tempo: Double,
    scale: Scale? = nil,
    @SongBuilder _ content: () -> [SongComponent]
) -> Composition {
    var phrases: [UTABComposerCore.Phrase] = []
    var sections: [UTABComposerCore.Section] = []
    for component in content() {
        switch component {
        case .phrase(let phrase): phrases.append(phrase)
        case .section(let section): sections.append(section)
        }
    }
    return Composition(title: title, meter: meter, tempo: tempo, scale: scale, phrases: phrases, sections: sections)
}
