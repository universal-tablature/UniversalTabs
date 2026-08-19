import UTABComposerCore

public struct TextCompositionSyntax: Sendable, Hashable {
    public let title: TextToken?
    public let meter: (numerator: TextToken, denominator: TextToken)?
    public let tempo: TextToken?
    public let scale: (tonic: TextToken, mode: TextToken)?
    public let phrases: [TextPhraseSyntax]
    public let sections: [TextSectionSyntax]
    public let main: [TextToken]
    public let range: SourceRange

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.title == rhs.title && lhs.meter?.numerator == rhs.meter?.numerator
            && lhs.meter?.denominator == rhs.meter?.denominator && lhs.tempo == rhs.tempo
            && lhs.scale?.tonic == rhs.scale?.tonic && lhs.scale?.mode == rhs.scale?.mode
            && lhs.phrases == rhs.phrases && lhs.sections == rhs.sections && lhs.main == rhs.main && lhs.range == rhs.range
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(title); hasher.combine(meter?.numerator); hasher.combine(meter?.denominator)
        hasher.combine(tempo); hasher.combine(scale?.tonic); hasher.combine(scale?.mode)
        hasher.combine(phrases); hasher.combine(sections); hasher.combine(main); hasher.combine(range)
    }
}

public struct TextPhraseSyntax: Sendable, Hashable {
    public let name: TextToken
    public let expressions: [TextExpressionSyntax]
    public let range: SourceRange
}

public struct TextSectionSyntax: Sendable, Hashable {
    public let name: TextToken
    public let barCount: TextToken?
    public let instruments: [TextInstrumentSyntax]
    public let range: SourceRange
}

public struct TextInstrumentSyntax: Sendable, Hashable {
    public let name: TextToken
    public let voices: [TextVoiceSyntax]
    public let range: SourceRange
}

public struct TextVoiceSyntax: Sendable, Hashable {
    public let name: TextToken
    public let lyrics: [TextToken]
    public let expressions: [TextExpressionSyntax]
    public let range: SourceRange
}

public struct TextExpressionSyntax: Sendable, Hashable {
    public indirect enum Kind: Sendable, Hashable {
        case note(pitch: TextToken, duration: TextToken)
        case rest(duration: TextToken)
        case reference(TextToken)
        case repeated(count: TextToken, expressions: [TextExpressionSyntax])
        case bar([TextExpressionSyntax])
    }

    public let kind: Kind
    public let range: SourceRange
}

public struct TextParseResult: Sendable {
    public let syntax: TextCompositionSyntax?
    public let tokens: [TextToken]
    public let diagnostics: [TextDiagnostic]

    public var succeeded: Bool { syntax != nil && !diagnostics.contains { $0.severity == .error } }
}
