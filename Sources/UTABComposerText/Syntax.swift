import UTABComposerCore

public struct TextCompositionSyntax: Sendable, Hashable {
    public let module: TextQualifiedNameSyntax?
    public let imports: [TextImportSyntax]
    public let profiles: [TextInstrumentProfileSyntax]
    public let models: [TextInstrumentModelSyntax]
    public let extensions: [TextInstrumentExtensionSyntax]
    public let title: TextToken?
    public let meter: (numerator: TextToken, denominator: TextToken)?
    public let tempo: TextToken?
    public let scale: (tonic: TextToken, mode: TextToken)?
    public let instruments: [TextInstrumentInstanceSyntax]
    public let phrases: [TextPhraseSyntax]
    public let sections: [TextSectionSyntax]
    public let main: [TextToken]
    public let range: SourceRange

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.module == rhs.module && lhs.imports == rhs.imports && lhs.profiles == rhs.profiles && lhs.models == rhs.models && lhs.extensions == rhs.extensions
            && lhs.title == rhs.title && lhs.meter?.numerator == rhs.meter?.numerator
            && lhs.meter?.denominator == rhs.meter?.denominator && lhs.tempo == rhs.tempo
            && lhs.scale?.tonic == rhs.scale?.tonic && lhs.scale?.mode == rhs.scale?.mode
            && lhs.instruments == rhs.instruments && lhs.phrases == rhs.phrases && lhs.sections == rhs.sections && lhs.main == rhs.main && lhs.range == rhs.range
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(module); hasher.combine(imports); hasher.combine(profiles); hasher.combine(models); hasher.combine(extensions)
        hasher.combine(title); hasher.combine(meter?.numerator); hasher.combine(meter?.denominator)
        hasher.combine(tempo); hasher.combine(scale?.tonic); hasher.combine(scale?.mode)
        hasher.combine(instruments); hasher.combine(phrases); hasher.combine(sections); hasher.combine(main); hasher.combine(range)
    }
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
    public let value: TextToken
    public let range: SourceRange
}

public struct TextTuningSyntax: Sendable, Hashable {
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
    public let displayName: TextToken?
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
        case relativeNote(degree: TextToken, octave: TextToken, duration: TextToken)
        case chord(root: TextToken, quality: TextToken, duration: TextToken)
        case rest(duration: TextToken)
        case reference(TextToken)
        case repeated(count: TextToken, expressions: [TextExpressionSyntax])
        case bar([TextExpressionSyntax])
        case parallel([TextExpressionSyntax])
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
