@_exported import UTABComposerCore

@resultBuilder
public enum ExpressionBuilder {
    public static func buildBlock(_ components: MusicalExpression...) -> MusicalExpression { .sequence(components) }
    public static func buildArray(_ components: [MusicalExpression]) -> MusicalExpression { .sequence(components) }
    public static func buildOptional(_ component: MusicalExpression?) -> MusicalExpression { component ?? .sequence([]) }
    public static func buildEither(first component: MusicalExpression) -> MusicalExpression { component }
    public static func buildEither(second component: MusicalExpression) -> MusicalExpression { component }
}

public func Rest(_ duration: MusicalDuration) -> MusicalExpression { .rest(duration) }

public func Note(
    _ pitch: MusicalPitch,
    _ duration: MusicalDuration,
    constraints: [PerformanceConstraint] = []
) -> MusicalExpression {
    .note(pitch, duration: duration, constraints: constraints)
}

public func Degree(_ degree: Int, octave: Int, _ duration: MusicalDuration) -> MusicalExpression {
    Note(.scaleDegree(degree, octave: octave), duration)
}

public func Chord(
    _ root: PitchClass,
    _ quality: ChordQuality,
    _ duration: MusicalDuration,
    constraints: [PerformanceConstraint] = []
) -> MusicalExpression {
    .chord(.init(root, quality), duration: duration, constraints: constraints)
}

public func Parallel(@ExpressionBuilder _ content: () -> MusicalExpression) -> MusicalExpression {
    switch content() {
    case .sequence(let children): .parallel(children)
    case let expression: .parallel([expression])
    }
}

public func C4(_ duration: MusicalDuration, constraints: [PerformanceConstraint] = []) -> MusicalExpression {
    Note(.absolute(.init(.c, octave: 4)), duration, constraints: constraints)
}
public func D4(_ duration: MusicalDuration, constraints: [PerformanceConstraint] = []) -> MusicalExpression {
    Note(.absolute(.init(.d, octave: 4)), duration, constraints: constraints)
}
public func E4(_ duration: MusicalDuration, constraints: [PerformanceConstraint] = []) -> MusicalExpression {
    Note(.absolute(.init(.e, octave: 4)), duration, constraints: constraints)
}
public func F4(_ duration: MusicalDuration, constraints: [PerformanceConstraint] = []) -> MusicalExpression {
    Note(.absolute(.init(.f, octave: 4)), duration, constraints: constraints)
}
public func G4(_ duration: MusicalDuration, constraints: [PerformanceConstraint] = []) -> MusicalExpression {
    Note(.absolute(.init(.g, octave: 4)), duration, constraints: constraints)
}
public func A4(_ duration: MusicalDuration, constraints: [PerformanceConstraint] = []) -> MusicalExpression {
    Note(.absolute(.init(.a, octave: 4)), duration, constraints: constraints)
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

public func Voice(
    _ name: String,
    constraints: [PerformanceConstraint] = [],
    @VoiceContentBuilder _ content: () -> [VoiceContent]
) -> UTABComposerCore.Voice {
    .init(name, content: content(), constraints: constraints)
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
    duration: MusicalDuration,
    @PartBuilder _ content: () -> [Part]
) -> UTABComposerCore.Section {
    .init(name, duration: duration, parts: content())
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
