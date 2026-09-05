import UTABComposerCore

public struct TextCompositionSyntax: Sendable, Hashable {
    public let module: TextQualifiedNameSyntax?
    public let imports: [TextImportSyntax]
    public var notationUses: [TextQualifiedNameSyntax] = []
    public var defaultNotation: TextQualifiedNameSyntax? = nil
    public var namingSystems: [TextNamingSyntax] = []
    public let constants: [TextConstantSyntax]
    public let scaleDefinitions: [TextScaleDefinitionSyntax]
    public let profiles: [TextInstrumentProfileSyntax]
    public let models: [TextInstrumentModelSyntax]
    public let extensions: [TextInstrumentExtensionSyntax]
    public let title: TextToken?
    public let meter: (numerator: TextToken, denominator: TextToken)?
    public let tempo: TextToken?
    public let scale: (tonic: TextToken, mode: TextToken)?
    public let instruments: [TextInstrumentInstanceSyntax]
    public let performancePatterns: [TextPerformancePatternSyntax]
    public let phrases: [TextPhraseSyntax]
    public let sections: [TextSectionSyntax]
    public let main: [TextToken]
    public let range: SourceRange

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.notationUses == rhs.notationUses && lhs.defaultNotation == rhs.defaultNotation && lhs.namingSystems == rhs.namingSystems && lhs.module == rhs.module && lhs.imports == rhs.imports && lhs.constants == rhs.constants && lhs.scaleDefinitions == rhs.scaleDefinitions && lhs.profiles == rhs.profiles && lhs.models == rhs.models && lhs.extensions == rhs.extensions
            && lhs.title == rhs.title && lhs.meter?.numerator == rhs.meter?.numerator
            && lhs.meter?.denominator == rhs.meter?.denominator && lhs.tempo == rhs.tempo
            && lhs.scale?.tonic == rhs.scale?.tonic && lhs.scale?.mode == rhs.scale?.mode
            && lhs.instruments == rhs.instruments && lhs.performancePatterns == rhs.performancePatterns && lhs.phrases == rhs.phrases && lhs.sections == rhs.sections && lhs.main == rhs.main && lhs.range == rhs.range
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(notationUses); hasher.combine(defaultNotation); hasher.combine(namingSystems); hasher.combine(module); hasher.combine(imports); hasher.combine(constants); hasher.combine(scaleDefinitions); hasher.combine(profiles); hasher.combine(models); hasher.combine(extensions)
        hasher.combine(title); hasher.combine(meter?.numerator); hasher.combine(meter?.denominator)
        hasher.combine(tempo); hasher.combine(scale?.tonic); hasher.combine(scale?.mode)
        hasher.combine(instruments); hasher.combine(performancePatterns); hasher.combine(phrases); hasher.combine(sections); hasher.combine(main); hasher.combine(range)
    }
}

public struct TextConstantSyntax: Sendable, Hashable {
    public enum Value: Sendable, Hashable {
        case integer(TextToken)
        case pitchClass(TextToken)
        case scaleDegree(degree: TextToken, alteration: Int)
        case chordAbsolute(root: TextToken, quality: TextToken)
        case chordRelative(degree: TextToken, alteration: Int, quality: TextToken)
    }

    public let name: TextToken
    public var notation: TextQualifiedNameSyntax? = nil
    public let value: Value
    public let range: SourceRange
}

public struct TextScaleDefinitionSyntax: Sendable, Hashable {
    public let symbol: TextToken
    public let centIntervals: [TextToken]
    public let range: SourceRange
}

public struct TextQualifiedNameSyntax: Sendable, Hashable {
    public let components: [TextToken]
    public let range: SourceRange

    public var value: String { components.map { String($0.lexeme) }.joined(separator: ".") }
}

/// A catalogue symbol written either as an identifier path or as a quoted stable ID.
public struct TextSymbolReferenceSyntax: Sendable, Hashable {
    public let components: [TextToken]
    public let range: SourceRange

    public var value: String {
        if components.count == 1, let value = components[0].stringValue { return value }
        return components.map { String($0.lexeme) }.joined(separator: ".")
    }

    public var isStableID: Bool { components.count == 1 && components[0].kind == .stringLiteral }
    public var isQualified: Bool { !isStableID && components.count > 1 }
}

public struct TextImportSyntax: Sendable, Hashable {
    public let name: TextQualifiedNameSyntax
    public let range: SourceRange
}

public struct TextInstrumentProfileSyntax: Sendable, Hashable {
    public let symbol: TextToken
    public let properties: [TextPropertySyntax]
    public let actuators: [TextActuatorSyntax]
    public let interactions: [TextInteractionSyntax]
    public let techniques: [TextTechniqueSyntax]
    public let range: SourceRange
}

public struct TextActuatorSyntax: Sendable, Hashable {
    public let name: TextToken
    public let properties: [TextPropertySyntax]
    public let range: SourceRange
}

public struct TextInteractionSyntax: Sendable, Hashable {
    public let name: TextToken
    public let targets: [TextToken]
    public let effectors: [TextToken]
    public let arguments: [TextInteractionArgumentSyntax]
    public let modifiers: [TextToken]
    public let parameters: [TextInteractionParameterSyntax]
    public let range: SourceRange
}

public struct TextInteractionArgumentSyntax: Sendable, Hashable {
    public let name: TextToken
    public let values: [TextToken]
    public let isRequired: Bool
    public let range: SourceRange
}

public struct TextInteractionParameterSyntax: Sendable, Hashable {
    public let name: TextToken
    public let properties: [TextPropertySyntax]
    public let range: SourceRange
}

public struct TextTechniqueSyntax: Sendable, Hashable {
    public let name: TextToken
    public let properties: [TextPropertySyntax]
    public let range: SourceRange
}

public struct TextInstrumentModelSyntax: Sendable, Hashable {
    public let symbol: TextToken
    public let profile: TextSymbolReferenceSyntax
    public let properties: [TextPropertySyntax]
    public let geometries: [TextGeometrySyntax]
    public let range: SourceRange
}

public struct TextInstrumentExtensionSyntax: Sendable, Hashable {
    public let model: TextSymbolReferenceSyntax
    public let tunings: [TextTuningSyntax]
    public let fingerings: [TextFingeringSyntax]
    public let chordShapes: [TextChordShapeSyntax]
    public let range: SourceRange
}

public struct TextChordShapeSyntax: Sendable, Hashable {
    public let symbol: TextToken
    public let root: TextToken
    public let quality: TextToken
    public let strings: [TextChordShapeStringSyntax]
    public let range: SourceRange
}

public struct TextChordShapeStringSyntax: Sendable, Hashable {
    public let number: TextToken
    public let fret: TextToken
    public let range: SourceRange
}

public struct TextFingeringSyntax: Sendable, Hashable {
    public let symbol: TextToken
    public let isDefault: Bool
    public let properties: [TextPropertySyntax]
    public let bitOrder: [TextToken]
    public let entries: [TextFingeringEntrySyntax]
    public let range: SourceRange
}

public struct TextFingeringEntrySyntax: Sendable, Hashable {
    public let pitch: TextToken?
    public let effect: TextToken?
    public let pattern: TextToken
    public let register: TextToken?
    public let preference: TextToken?
    public let label: TextToken?
    public let range: SourceRange
}

public struct TextGeometrySyntax: Sendable, Hashable {
    public let name: TextToken
    public let properties: [TextPropertySyntax]
    public let range: SourceRange
}

public struct TextPropertySyntax: Sendable, Hashable {
    public let name: TextToken
    public let values: [TextToken]
    public let range: SourceRange

    public var value: TextToken { values[0] }
    public var reference: String? {
        guard values.count > 1, values.allSatisfy({ $0.kind == .identifier }) else { return nil }
        return values.map { String($0.lexeme) }.joined(separator: ".")
    }
}

public struct TextTuningSyntax: Sendable, Hashable {
    public var notation: TextQualifiedNameSyntax? = nil
    public let symbol: TextToken
    public let isDefault: Bool
    public let properties: [TextPropertySyntax]
    public let tags: [TextToken]
    public let courses: [[TextToken]]
    public let range: SourceRange
}

public struct TextInstrumentInstanceSyntax: Sendable, Hashable {
    public let name: TextToken
    public let model: TextSymbolReferenceSyntax
    public let fingering: TextSymbolReferenceSyntax?
    public let displayName: TextToken?
    public let range: SourceRange
}

public struct TextPerformancePatternSyntax: Sendable, Hashable {
    public let name: TextToken
    public let subdivision: TextDurationSyntax
    public let steps: [TextPerformanceStepSyntax]
    public let range: SourceRange
}

public struct TextPerformanceStepSyntax: Sendable, Hashable {
    public indirect enum Kind: Sendable, Hashable {
        case interaction([TextToken])
        case parallel([TextPerformanceStepSyntax])
    }
    public let kind: Kind
    public let range: SourceRange
}

public struct TextPhraseSyntax: Sendable, Hashable {
    public let name: TextToken
    public let expressions: [TextExpressionSyntax]
    public let range: SourceRange
}

public struct TextSectionSyntax: Sendable, Hashable {
    public let name: TextToken
    public let barCount: TextToken?
    public let harmony: [TextExpressionSyntax]
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
        case note(pitch: TextToken, duration: TextDurationSyntax)
        case relativeNote(degree: TextToken, alteration: Int, octave: TextToken, duration: TextDurationSyntax)
        case chord(root: TextToken, quality: TextToken, duration: TextDurationSyntax, shape: TextToken?)
        case relativeChord(degree: TextToken, alteration: Int, quality: TextToken, duration: TextDurationSyntax, shape: TextToken?)
        case symbol(name: TextToken, alteration: Int, octave: TextToken?, duration: TextDurationSyntax)
        case actuator(action: TextToken, target: TextQualifiedNameSyntax, member: TextToken?, duration: TextDurationSyntax)
        case rest(duration: TextDurationSyntax)
        case reference(TextToken)
        case repeated(count: TextToken, expressions: [TextExpressionSyntax])
        case bar([TextExpressionSyntax])
        case pickup([TextExpressionSyntax])
        case finalBar([TextExpressionSyntax])
        case tempo(unit: TextDurationSyntax?, beatsPerMinute: TextToken)
        case tempoRamp(target: TextToken, duration: TextDurationSyntax, steps: TextToken?)
        case fermata(duration: TextDurationSyntax, factor: TextToken)
        case sequence([TextExpressionSyntax])
        case parallel([TextExpressionSyntax])
        case proportional(numerator: TextToken, denominator: TextToken, tuplet: Bool, expressions: [TextExpressionSyntax])
        case performed(pattern: TextToken, chords: [TextExpressionSyntax])
    }

    public let kind: Kind
    public let range: SourceRange
    public var notation: TextQualifiedNameSyntax? = nil
    public var tieToNext = false
}

public struct TextParseResult: Sendable {
    public let syntax: TextCompositionSyntax?
    public let tokens: [TextToken]
    public let diagnostics: [TextDiagnostic]

    public var succeeded: Bool { syntax != nil && !diagnostics.contains { $0.severity == .error } }
}

public struct TextDurationSyntax: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case named(TextToken, dots: Int)
        case fraction(TextToken, TextToken)
    }
    public let kind: Kind
    public let range: SourceRange
}

public struct TextNamingSyntax: Sendable, Hashable {
    public struct Entry: Sendable, Hashable {
        public let name: TextToken
        public let target: TextToken
        public let alteration: TextToken
        public let relative: Bool
    }
    public let name: TextToken
    public let register: TextToken
    public let entries: [Entry]
    public let range: SourceRange
}
