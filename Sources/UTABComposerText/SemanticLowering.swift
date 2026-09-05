import UTABComposerCore

public struct TextSemanticResult: Sendable {
    public let composition: Composition?
    public let instruments: [TextInstrumentInstanceDeclaration]
    public let diagnostics: [TextDiagnostic]

    public var succeeded: Bool { composition != nil && !diagnostics.contains { $0.severity == .error } }
}

public struct TextInstrumentInstanceDeclaration: Sendable, Hashable {
    public let name: String
    public let model: String
    public let fingering: String?
    public let displayName: String?
    public let range: SourceRange
}

public struct TextSemanticLowerer: Sendable {
    public init() {}

    public func lower(_ syntax: TextCompositionSyntax) -> TextSemanticResult {
        let definitions = scaleKinds(in: [syntax])
        var worker = Worker(syntax: syntax, modules: [syntax], scaleKinds: definitions.kinds, bindings: [:], diagnostics: definitions.diagnostics)
        return worker.lower()
    }

    public func lower(_ modules: [TextLoadedModule]) -> TextSemanticResult {
        guard let root = modules.last(where: \.isRoot) else {
            return .init(composition: nil, instruments: [], diagnostics: [])
        }
        let definitions = scaleKinds(in: modules.map(\.syntax))
        var worker = Worker(syntax: root.syntax, modules: modules.map(\.syntax), scaleKinds: definitions.kinds, bindings: [:], diagnostics: definitions.diagnostics)
        return worker.lower()
    }

    /// Resolves catalogue pitch tokens through the same declaration-site naming rules as notes.
    public func resolvePitch(_ token: TextToken, notation: TextQualifiedNameSyntax, in modules: [TextLoadedModule]) -> (pitch: AbsolutePitch?, diagnostics: [TextDiagnostic]) {
        guard let owner = modules.first(where: { $0.syntax.range.fileID == token.range.fileID }) else { return (nil, []) }
        var worker = Worker(syntax: owner.syntax, modules: modules.map(\.syntax), scaleKinds: [:], bindings: [:], diagnostics: [])
        worker.validateNamingSystems()
        guard worker.diagnostics.isEmpty else { return (nil, worker.diagnostics) }
        if let (pitch, _) = worker.namedPitch(token, octave: nil, alteration: 0, notation: notation), case .absolute(let absolute) = pitch {
            return (absolute, worker.diagnostics)
        }
        worker.error("Catalogue pitches require an absolute naming system", at: token.range)
        return (nil, worker.diagnostics)
    }

    private func scaleKinds(in syntaxes: [TextCompositionSyntax]) -> (kinds: [String: ScaleKind], diagnostics: [TextDiagnostic]) {
        var result: [String: ScaleKind] = ["major": .major, "minor": .naturalMinor]
        var diagnostics: [TextDiagnostic] = []
        for definition in syntaxes.flatMap(\.scaleDefinitions) {
            let name = String(definition.symbol.lexeme)
            let intervals = definition.centIntervals.compactMap(\.integerValue)
            if result[name] != nil {
                diagnostics.append(.init(.error, message: "Duplicate scale definition '\(name)'", range: definition.range))
                continue
            }
            guard intervals.first == 0,
                  intervals.allSatisfy({ 0 <= $0 && $0 < 1_200 }),
                  zip(intervals, intervals.dropFirst()).allSatisfy(<) else {
                diagnostics.append(.init(.error, message: "Scale '\(name)' must start at 0 cents and contain strictly increasing offsets below 1200 cents", range: definition.range))
                continue
            }
            result[name] = .custom(name: name, centIntervals: intervals)
        }
        return (result, diagnostics)
    }

    private struct Worker {
        let syntax: TextCompositionSyntax
        let modules: [TextCompositionSyntax]
        let scaleKinds: [String: ScaleKind]
        var bindings: [String: TextConstantSyntax.Value]
        var diagnostics: [TextDiagnostic]

        mutating func lower() -> TextSemanticResult {
            validateNamingSystems()
            guard !diagnostics.contains(where: { $0.severity == .error }) else {
                return .init(composition: nil, instruments: lowerInstruments(), diagnostics: diagnostics)
            }
            prepareBindings()
            for pattern in modules.flatMap(\.performancePatterns) { _ = duration(pattern.subdivision) }
            let numerator: Int
            let denominator: Int
            if let meterTokens = syntax.meter,
               let parsedNumerator = meterTokens.numerator.integerValue,
               let parsedDenominator = meterTokens.denominator.integerValue,
               parsedNumerator > 0, parsedDenominator > 0 {
                numerator = parsedNumerator
                denominator = parsedDenominator
            } else {
                error("A composition requires a meter declaration", at: syntax.range)
                numerator = 4
                denominator = 4
            }
            let tempo: Double
            if let tempoToken = syntax.tempo, let parsedTempo = tempoToken.decimalValue, parsedTempo > 0 {
                tempo = parsedTempo
            } else {
                error("A composition requires a positive tempo declaration", at: syntax.tempo?.range ?? syntax.range)
                tempo = 120
            }
            let meter = TimeSignature(numerator, denominator)
            let phrases = modules.flatMap(\.phrases).map { lowerPhrase($0) }
            let sections = syntax.sections.map { lowerSection($0, meter: meter) }
            let main: MusicalExpression? = syntax.main.isEmpty ? nil : .sequence(syntax.main.map { token in
                .reference(.named("section", String(token.lexeme)), id: id("section-reference", token.range))
            })
            let scale = syntax.scale.flatMap { lowerScale($0.tonic, $0.mode) }
            guard !diagnostics.contains(where: { $0.severity == .error }) else {
                return .init(composition: nil, instruments: lowerInstruments(), diagnostics: diagnostics)
            }
            let title = syntax.title?.stringValue ?? "Untitled"
            return .init(
                composition: .init(
                    title: title,
                    id: id("composition", syntax.range),
                    meter: meter,
                    tempo: tempo,
                    scale: scale,
                    phrases: phrases,
                    sections: sections,
                    main: main,
                    source: syntax.range
                ),
                instruments: lowerInstruments(),
                diagnostics: diagnostics
            )
        }

        func lowerInstruments() -> [TextInstrumentInstanceDeclaration] {
            syntax.instruments.map {
                .init(
                    name: String($0.name.lexeme),
                    model: $0.model.value,
                    fingering: $0.fingering?.value,
                    displayName: $0.displayName?.stringValue,
                    range: $0.range
                )
            }
        }

        func phraseID(_ phrase: TextPhraseSyntax) -> SemanticID {
            let module = modules.first { $0.range.fileID == phrase.range.fileID }
            let name = String(phrase.name.lexeme)
            return .named("phrase", module?.range.fileID == syntax.range.fileID ? name : (module?.module?.value ?? phrase.range.fileID) + "." + name)
        }

        mutating func resolvePhrase(_ token: TextToken) -> SemanticID {
            let owner = modules.first { $0.range.fileID == token.range.fileID } ?? syntax
            let local = owner.phrases.filter { $0.name.lexeme == token.lexeme }
            if local.count == 1 { return phraseID(local[0]) }
            let imports = Set(owner.imports.map { $0.name.value })
            let candidates = modules.filter { $0.range.fileID == owner.range.fileID || imports.contains($0.module?.value ?? "") }.flatMap { module in
                module.phrases.filter { phrase in
                    token.lexeme.contains(".") ? (module.module?.value ?? "") + "." + phrase.name.lexeme == token.lexeme : phrase.name.lexeme == token.lexeme
                }
            }
            if candidates.count == 1 { return phraseID(candidates[0]) }
            error(candidates.isEmpty ? "Unknown phrase '\(token.lexeme)'" : "Ambiguous phrase '\(token.lexeme)'", at: token.range)
            return .named("phrase", String(token.lexeme))
        }

        mutating func lowerPhrase(_ phrase: TextPhraseSyntax) -> Phrase {
            if !phrase.expressions.isEmpty, phrase.expressions.allSatisfy({ if case .bar = $0.kind { true } else { false } }) {
                let bars = phrase.expressions.map { expression -> Bar in
                    guard case .bar(let children) = expression.kind else { preconditionFailure() }
                    return .init(
                        expressionSequence(children, range: expression.range),
                        id: id("bar", expression.range),
                        source: expression.range
                    )
                }
                return .init(phraseID(phrase).rawValue.dropFirst("phrase:".count).description, id: phraseID(phrase), bars: bars, source: phrase.range)
            }

            let expression = lowerBoundarySequence(phrase.expressions, range: phrase.range)
            return .init(
                phraseID(phrase).rawValue.dropFirst("phrase:".count).description,
                id: phraseID(phrase),
                expression: expression,
                source: phrase.range
            )
        }

        mutating func lowerSection(_ section: TextSectionSyntax, meter: TimeSignature) -> Section {
            var duration: MusicalDuration?
            if let token = section.barCount {
                if let count = token.integerValue, count > 0,
                   let value = meter.duration.wholeNotes.multiplied(by: Rational(count)) {
                    duration = MusicalDuration(value.numerator, value.denominator)
                } else { error("Section length must be positive and fit rational score time", at: token.range) }
            }
            return .init(
                String(section.name.lexeme),
                id: .named("section", String(section.name.lexeme)),
                duration: duration,
                harmony: section.harmony.isEmpty ? nil : expressionSequence(section.harmony, range: section.range),
                parts: section.instruments.map { lowerInstrument($0) },
                source: section.range
            )
        }

        mutating func lowerInstrument(_ instrument: TextInstrumentSyntax) -> Part {
            let name = instrument.name.stringValue ?? String(instrument.name.lexeme)
            return .init(
                instrument: name,
                id: id("part", instrument.range),
                voices: instrument.voices.map { lowerVoice($0) },
                source: instrument.range
            )
        }

        mutating func lowerVoice(_ voice: TextVoiceSyntax) -> Voice {
            let lyricText = voice.lyrics.compactMap(\.stringValue).joined(separator: " ")
            let lyrics = lyricText.isEmpty ? [] : [LyricVerse(
                lyricText,
                id: id("lyrics", voice.lyrics.first?.range ?? voice.range)
            )]
            let lowered = lowerBoundaryContents(voice.expressions, range: voice.range)
            return .init(
                String(voice.name.lexeme),
                id: id("voice", voice.range),
                content: lowered,
                lyrics: lyrics,
                source: voice.range
            )
        }

        mutating func lowerVoiceContent(_ expression: TextExpressionSyntax) -> VoiceContent {
            if case .reference(let token) = expression.kind { return .reference(resolvePhrase(token)) }
            return .expression(lowerExpression(expression))
        }

        mutating func lowerBoundaryContents(_ expressions: [TextExpressionSyntax], range: SourceRange) -> [VoiceContent] {
            let lowered = expressions.map { lowerVoiceContent($0) }
            let durations = lowered.map { content -> MusicalDuration? in
                guard case .expression(let expression) = content else { return nil }
                return expression.duration
            }
            validateBoundaryBars(expressions, durations: durations, range: range)
            return lowered
        }

        mutating func lowerBoundarySequence(_ expressions: [TextExpressionSyntax], range: SourceRange) -> MusicalExpression {
            let lowered = expressions.map { lowerExpression($0) }
            validateBoundaryBars(expressions, durations: lowered.map(\.duration), range: range)
            return .sequence(lowered, id: id("sequence", range))
        }

        mutating func validateBoundaryBars(_ expressions: [TextExpressionSyntax], durations: [MusicalDuration?], range: SourceRange) {
            let pickups = expressions.indices.filter { if case .pickup = expressions[$0].kind { true } else { false } }
            let finals = expressions.indices.filter { if case .finalBar = expressions[$0].kind { true } else { false } }
            for index in pickups where index != expressions.startIndex { error("A pickup must be the first expression in its scope", at: expressions[index].range) }
            for index in finals where index != expressions.index(before: expressions.endIndex) { error("An incomplete final bar must be the last expression in its scope", at: expressions[index].range) }
            if pickups.count > 1 { error("A scope may contain only one pickup", at: range) }
            if finals.count > 1 { error("A scope may contain only one incomplete final bar", at: range) }
            if let pickup = pickups.first, let final = finals.first,
               let pickupDuration = durations[pickup], let finalDuration = durations[final],
               let meter = syntax.meter,
               let numerator = meter.numerator.integerValue,
               let denominator = meter.denominator.integerValue,
               pickupDuration + finalDuration != MusicalDuration(numerator, denominator) {
                error("Pickup and incomplete final bar durations must complement the active meter", at: expressions[final].range)
            }
        }

        mutating func expressionSequence(_ expressions: [TextExpressionSyntax], range: SourceRange) -> MusicalExpression {
            .sequence(expressions.map { lowerExpression($0) }, id: id("sequence", range))
        }

        mutating func lowerExpression(_ expression: TextExpressionSyntax) -> MusicalExpression {
            let result: MusicalExpression
            if expression.notation != nil, let named = lowerNamedExpression(expression) { result = named }
            else { switch expression.kind {
            case .note: result = lowerNoteExpression(expression)
            case .relativeNote: result = lowerRelativenoteExpression(expression)
            case .chord: result = lowerChordExpression(expression)
            case .relativeChord: result = lowerRelativechordExpression(expression)
            case .symbol: result = lowerSymbolExpression(expression)
            case .rest: result = lowerRestExpression(expression)
            case .actuator: result = lowerActuatorExpression(expression)
            case .reference: result = lowerReferenceExpression(expression)
            case .repeated: result = lowerRepeatedExpression(expression)
            case .proportional: result = lowerProportionalExpression(expression)
            case .bar: result = lowerBarExpression(expression)
            case .pickup, .finalBar: result = lowerPartialBarExpression(expression)
            case .tempo: result = lowerTempoExpression(expression)
            case .tempoRamp: result = lowerTempoRampExpression(expression)
            case .fermata: result = lowerFermataExpression(expression)
            case .rubato: result = lowerRubatoExpression(expression)
            case .damp:
                result = .init(
                    id: id("damp", expression.range),
                    kind: .rest(.zero),
                    annotations: .init(metadata: ["damp": .boolean(true)], source: expression.range)
                )
            case .technique: result = lowerTechniqueExpression(expression)
            case .sequence: result = lowerSequenceExpression(expression)
            case .parallel: result = lowerParallelExpression(expression)
            case .performed: result = lowerPerformedExpression(expression)
            }}
            var metadata = result.annotations.metadata
            if expression.tieToNext { metadata["tieToNext"] = .boolean(true) }
            for modifier in expression.modifiers { metadata[String(modifier.lexeme)] = .boolean(true) }
            var decorated = metadata == result.annotations.metadata ? result : MusicalExpression(
                id: result.id,
                kind: result.kind,
                annotations: .init(metadata: metadata, source: result.annotations.source)
            )
            for modifier in expression.modifiers.reversed() {
                decorated = .technique(.init(
                    String(modifier.lexeme),
                    form: .unary,
                    operands: [decorated]
                ), id: id("modifier:\(modifier.lexeme)", modifier.range))
            }
            return decorated
        }

        mutating func lowerTechniqueExpression(_ expression: TextExpressionSyntax) -> MusicalExpression {
            guard case .technique(let name, let expressions) = expression.kind else {
                preconditionFailure("Mismatched expression dispatch")
            }
            return .technique(.init(
                String(name.lexeme),
                form: .scoped,
                operands: [expressionSequence(expressions, range: expression.range)]
            ), id: id("technique:\(name.lexeme)", expression.range))
        }

        mutating func lowerNamedExpression(_ expression: TextExpressionSyntax) -> MusicalExpression? {
            if let notation = expression.notation {
                switch expression.kind {
                case .note(let name, let duration):
                    return namedNote(name, octave: nil, alteration: 0, duration: duration, notation: notation, expression: expression)
                case .symbol(let name, let alteration, let octave, let duration):
                    if lookupBinding(String(name.lexeme), at: name.range) != nil {
                        if let (system, _) = namingSystem(notation), system.entries.contains(where: { $0.name.lexeme == name.lexeme }) {
                            error("Musical constant '\(name.lexeme)' collides with the selected notation; rename the constant", at: name.range)
                        }
                        return lowerSymbolExpression(expression)
                    }
                    return namedNote(name, octave: octave, alteration: alteration, duration: duration, notation: notation, expression: expression)
                case .chord(let root, let quality, let durationToken, let shape):
                    guard let entry = namingEntry(String(root.lexeme), notation: notation, at: root.range),
                          let quality = chordQuality(quality) else { return .rest(.zero) }
                    let chord: ChordSymbol
                    switch entry.target {
                    case .letter(let letter, let alteration): chord = .init(.init(letter, accidental: alteration), quality)
                    case .degree(let degree, let alteration): chord = .init(scaleDegree: degree, alteration: alteration, quality)
                    }
                    return .init(id: id("named-chord", expression.range), kind: .chord(chord, duration: duration(durationToken), constraints: shape.map { [.chordShape(String($0.lexeme))] } ?? []), annotations: namingAnnotations(root, system: entry.system, range: expression.range))
                default: break
                }
            }

            return nil
        }

        mutating func lowerNoteExpression(_ expression: TextExpressionSyntax) -> MusicalExpression {
            switch expression.kind {
            case .note(let pitchToken, let durationToken):
                guard let pitch = parsePitch(pitchToken) else {
                    error("Invalid pitch '\(pitchToken.lexeme)'", at: pitchToken.range)
                    return .rest(.zero, id: id("invalid", expression.range))
                }
                return .init(
                    id: id("note", expression.range),
                    kind: .note(.absolute(pitch), duration: duration(durationToken), constraints: []),
                    annotations: .init(source: expression.range)
                )
            default: preconditionFailure("Mismatched expression dispatch")
            }
        }

        mutating func lowerRelativenoteExpression(_ expression: TextExpressionSyntax) -> MusicalExpression {
            switch expression.kind {
            case .relativeNote(let degree, let alteration, let octave, let durationToken):
                return .init(
                    id: id("relative-note", expression.range),
                    kind: .note(.scaleDegree(degree.integerValue ?? 0, octave: octave.integerValue ?? 0, alteration: alteration), duration: duration(durationToken), constraints: []),
                    annotations: .init(source: expression.range)
                )
            default: preconditionFailure("Mismatched expression dispatch")
            }
        }

        mutating func lowerChordExpression(_ expression: TextExpressionSyntax) -> MusicalExpression {
            switch expression.kind {
            case .chord(let root, let quality, let durationToken, let shape):
                guard let spelling = parsePitchClass(String(root.lexeme)) else {
                    error("Invalid chord root '\(root.lexeme)'", at: root.range)
                    return .rest(.zero, id: id("invalid", expression.range))
                }
                guard let chordQuality = chordQuality(quality) else {
                    error("Unsupported chord quality '\(quality.lexeme)'", at: quality.range)
                    return .rest(.zero, id: id("invalid", expression.range))
                }
                return .init(
                    id: id("chord", expression.range),
                    kind: .chord(.init(spelling, chordQuality), duration: duration(durationToken), constraints: shape.map { [.chordShape(String($0.lexeme))] } ?? []),
                    annotations: .init(source: expression.range)
                )
            default: preconditionFailure("Mismatched expression dispatch")
            }
        }

        mutating func lowerRelativechordExpression(_ expression: TextExpressionSyntax) -> MusicalExpression {
            switch expression.kind {
            case .relativeChord(let degree, let alteration, let quality, let durationToken, let shape):
                guard let chordQuality = chordQuality(quality) else {
                    error("Unsupported chord quality '\(quality.lexeme)'", at: quality.range)
                    return .rest(.zero, id: id("invalid", expression.range))
                }
                return .init(
                    id: id("relative-chord", expression.range),
                    kind: .chord(.init(scaleDegree: degree.integerValue ?? 0, alteration: alteration, chordQuality), duration: duration(durationToken), constraints: shape.map { [.chordShape(String($0.lexeme))] } ?? []),
                    annotations: .init(source: expression.range)
                )
            default: preconditionFailure("Mismatched expression dispatch")
            }
        }

        mutating func lowerSymbolExpression(_ expression: TextExpressionSyntax) -> MusicalExpression {
            switch expression.kind {
            case .symbol(let name, let useAlteration, let octave, let durationToken):
                if let octave, let register = octave.integerValue, lookupBinding(String(name.lexeme), at: name.range) == nil,
                   let spelling = parsePitchClass(String(name.lexeme)) {
                    return .init(id: id("bracketed-note", expression.range), kind: .note(.absolute(.init(.init(spelling.letter, accidental: spelling.accidental + useAlteration), octave: register)), duration: duration(durationToken), constraints: []), annotations: .init(source: expression.range))
                }
                let resolved = symbolicBinding(String(name.lexeme), useAlteration: useAlteration, at: name.range)
                guard let binding = resolved.binding else {
                    error("Unknown musical symbol '\(name.lexeme)'", at: name.range)
                    return .rest(.zero, id: id("invalid", expression.range))
                }
                let useAlteration = resolved.alteration
                switch binding {
                case .pitchClass(let pitchClass):
                    guard let octave, let spelling = parsePitchClass(String(pitchClass.lexeme)) else {
                        error("Pitch symbol '\(name.lexeme)' requires an octave", at: expression.range)
                        return .rest(.zero, id: id("invalid", expression.range))
                    }
                    let pitch = AbsolutePitch(.init(spelling.letter, accidental: spelling.accidental + useAlteration, tuningOffsetCents: spelling.tuningOffsetCents), octave: octave.integerValue ?? 0)
                    return .init(id: id("symbolic-note", expression.range), kind: .note(.absolute(pitch), duration: duration(durationToken), constraints: []), annotations: .init(source: expression.range))
                case .scaleDegree(let degree, let bindingAlteration):
                    guard let octave else {
                        error("Pitch symbol '\(name.lexeme)' requires an octave", at: expression.range)
                        return .rest(.zero, id: id("invalid", expression.range))
                    }
                    return .init(id: id("symbolic-relative-note", expression.range), kind: .note(.scaleDegree(degree.integerValue ?? 0, octave: octave.integerValue ?? 0, alteration: bindingAlteration + useAlteration), duration: duration(durationToken), constraints: []), annotations: .init(source: expression.range))
                case .chordAbsolute(let root, let quality):
                    guard octave == nil, useAlteration == 0, let spelling = parsePitchClass(String(root.lexeme)), let chordQuality = chordQuality(quality) else {
                        error("Invalid chord symbol '\(name.lexeme)'", at: expression.range)
                        return .rest(.zero, id: id("invalid", expression.range))
                    }
                    return .init(id: id("symbolic-chord", expression.range), kind: .chord(.init(spelling, chordQuality), duration: duration(durationToken), constraints: []), annotations: .init(source: expression.range))
                case .chordRelative(let degree, let bindingAlteration, let quality):
                    guard octave == nil, let chordQuality = chordQuality(quality) else {
                        error("Invalid relative chord symbol '\(name.lexeme)'", at: expression.range)
                        return .rest(.zero, id: id("invalid", expression.range))
                    }
                    return .init(id: id("symbolic-relative-chord", expression.range), kind: .chord(.init(scaleDegree: degree.integerValue ?? 0, alteration: bindingAlteration + useAlteration, chordQuality), duration: duration(durationToken), constraints: []), annotations: .init(source: expression.range))
                case .integer:
                    error("Integer constant '\(name.lexeme)' is not a musical value", at: expression.range)
                    return .rest(.zero, id: id("invalid", expression.range))
                }
            default: preconditionFailure("Mismatched expression dispatch")
            }
        }

        mutating func lowerRestExpression(_ expression: TextExpressionSyntax) -> MusicalExpression {
            switch expression.kind {
            case .rest(let token):
                return .init(id: id("rest", expression.range), kind: .rest(duration(token)), annotations: .init(source: expression.range))
            default: preconditionFailure("Mismatched expression dispatch")
            }
        }

        mutating func lowerActuatorExpression(_ expression: TextExpressionSyntax) -> MusicalExpression {
            switch expression.kind {
            case .actuator(let action, let target, let member, let durationToken):
                let memberValue: String?
                if let member {
                    memberValue = member.stringValue ?? String(member.lexeme)
                } else {
                    memberValue = nil
                }
                return .init(
                    id: id("actuator", expression.range),
                    kind: .actuator(.init(
                        action: String(action.lexeme),
                        target: .init(group: target.value, member: memberValue),
                        duration: duration(durationToken)
                    )),
                    annotations: .init(source: expression.range)
                )
            default: preconditionFailure("Mismatched expression dispatch")
            }
        }

        mutating func lowerReferenceExpression(_ expression: TextExpressionSyntax) -> MusicalExpression {
            switch expression.kind {
            case .reference(let token):
                return .reference(.named("phrase", String(token.lexeme)), id: id("phrase-reference", expression.range))
            default: preconditionFailure("Mismatched expression dispatch")
            }
        }

        mutating func lowerRepeatedExpression(_ expression: TextExpressionSyntax) -> MusicalExpression {
            switch expression.kind {
            case .repeated(let count, let expressions):
                guard let repetitions = count.integerValue else {
                    error("Repetition count exceeds the supported integer range", at: count.range)
                    return .rest(.zero)
                }
                return .repeated(count: repetitions, expressionSequence(expressions, range: expression.range), id: id("repeat", expression.range))
            default: preconditionFailure("Mismatched expression dispatch")
            }
        }

        mutating func lowerProportionalExpression(_ expression: TextExpressionSyntax) -> MusicalExpression {
            switch expression.kind {
            case .proportional(let numerator, let denominator, let tuplet, let expressions):
                guard let n = numerator.integerValue, let d = denominator.integerValue, n > 0, d > 0 else {
                    error("Duration ratios require positive representable integers", at: expression.range)
                    return .rest(.zero)
                }
                return .init(id: id("proportional", expression.range), kind: .proportional(Rational(tuplet ? d : n, tuplet ? n : d), expressionSequence(expressions, range: expression.range)), annotations: .init(metadata: ["ratio": .string("\(n)\(tuplet ? ":" : "/")\(d)"), "tuplet": .boolean(tuplet)], source: expression.range))
            default: preconditionFailure("Mismatched expression dispatch")
            }
        }

        mutating func lowerBarExpression(_ expression: TextExpressionSyntax) -> MusicalExpression {
            switch expression.kind {
            case .bar(let expressions):
                return .init(id: id("bar", expression.range), kind: .barAssertion(expressionSequence(expressions, range: expression.range)), annotations: .init(source: expression.range))
            default: preconditionFailure("Mismatched expression dispatch")
            }
        }

        mutating func lowerPartialBarExpression(_ expression: TextExpressionSyntax) -> MusicalExpression {
            let role: String
            let expressions: [TextExpressionSyntax]
            switch expression.kind {
            case .pickup(let children): role = "pickup"; expressions = children
            case .finalBar(let children): role = "final"; expressions = children
            default: preconditionFailure("Mismatched expression dispatch")
            }
            return .init(
                id: id("bar:\(role)", expression.range),
                kind: .barAssertion(expressionSequence(expressions, range: expression.range)),
                annotations: .init(metadata: ["barRole": .string(role)], source: expression.range)
            )
        }

        mutating func lowerTempoExpression(_ expression: TextExpressionSyntax) -> MusicalExpression {
            guard case .tempo(let unitSyntax, let bpmToken) = expression.kind,
                  let beatsPerMinute = bpmToken.decimalValue, beatsPerMinute > 0 else {
                error("Tempo must be a positive number", at: expression.range)
                return .rest(.zero, id: id("invalid-tempo", expression.range))
            }
            let unit = unitSyntax.map { duration($0) } ?? .quarter
            let quarterNotesPerMinute = beatsPerMinute * Double(unit.wholeNotes.numerator * 4) / Double(unit.wholeNotes.denominator)
            return .init(
                id: id("tempo", expression.range),
                kind: .rest(.zero),
                annotations: .init(metadata: [
                    "tempoQuarterNotesPerMinute": .decimal(quarterNotesPerMinute),
                    "tempoBeatUnit": .string(unit.description),
                ], source: expression.range)
            )
        }

        mutating func lowerTempoRampExpression(_ expression: TextExpressionSyntax) -> MusicalExpression {
            guard case .tempoRamp(let targetToken, let durationSyntax, let stepsToken) = expression.kind,
                  let target = targetToken.decimalValue, target > 0 else {
                error("Tempo ramp target must be a positive number", at: expression.range)
                return .rest(.zero, id: id("invalid-tempo-ramp", expression.range))
            }
            let span = duration(durationSyntax)
            let steps = stepsToken?.integerValue ?? 8
            guard steps > 0, steps <= 1_000 else {
                error("Tempo ramp steps must be in 1...1000", at: stepsToken?.range ?? expression.range)
                return .rest(.zero, id: id("invalid-tempo-ramp", expression.range))
            }
            return .init(
                id: id("tempo-ramp", expression.range),
                kind: .rest(.zero),
                annotations: .init(metadata: [
                    "tempoRampTarget": .decimal(target),
                    "tempoRampDurationNumerator": .integer(span.wholeNotes.numerator),
                    "tempoRampDurationDenominator": .integer(span.wholeNotes.denominator),
                    "tempoRampSteps": .integer(steps),
                ], source: expression.range)
            )
        }

        mutating func lowerFermataExpression(_ expression: TextExpressionSyntax) -> MusicalExpression {
            guard case .fermata(let durationSyntax, let factorToken) = expression.kind,
                  let factor = factorToken.decimalValue, factor > 1 else {
                error("Fermata factor must be greater than one", at: expression.range)
                return .rest(.zero, id: id("invalid-fermata", expression.range))
            }
            let span = duration(durationSyntax)
            return .init(
                id: id("fermata", expression.range),
                kind: .rest(.zero),
                annotations: .init(metadata: [
                    "fermataFactor": .decimal(factor),
                    "fermataDurationNumerator": .integer(span.wholeNotes.numerator),
                    "fermataDurationDenominator": .integer(span.wholeNotes.denominator),
                ], source: expression.range)
            )
        }

        mutating func lowerRubatoExpression(_ expression: TextExpressionSyntax) -> MusicalExpression {
            guard case .rubato(let durationSyntax, let factorToken) = expression.kind,
                  let factor = factorToken.decimalValue, factor > 0 else {
                error("Rubato factor must be positive", at: expression.range)
                return .rest(.zero, id: id("invalid-rubato", expression.range))
            }
            let span = duration(durationSyntax)
            return .init(
                id: id("rubato", expression.range),
                kind: .rest(.zero),
                annotations: .init(metadata: [
                    "rubatoFactor": .decimal(factor),
                    "rubatoDurationNumerator": .integer(span.wholeNotes.numerator),
                    "rubatoDurationDenominator": .integer(span.wholeNotes.denominator),
                ], source: expression.range)
            )
        }

        mutating func lowerSequenceExpression(_ expression: TextExpressionSyntax) -> MusicalExpression {
            switch expression.kind {
            case .sequence(let expressions):
                return expressionSequence(expressions, range: expression.range)
            default: preconditionFailure("Mismatched expression dispatch")
            }
        }

        mutating func lowerParallelExpression(_ expression: TextExpressionSyntax) -> MusicalExpression {
            switch expression.kind {
            case .parallel(let expressions):
                return .parallel(expressions.map { lowerExpression($0) }, id: id("parallel", expression.range))
            default: preconditionFailure("Mismatched expression dispatch")
            }
        }

        mutating func lowerPerformedExpression(_ expression: TextExpressionSyntax) -> MusicalExpression {
            switch expression.kind {
            case .performed(let patternToken, let chords):
                let patternName = String(patternToken.lexeme)
                guard let pattern = syntax.performancePatterns.first(where: { $0.name.lexeme == patternToken.lexeme }) else {
                    error("Unknown performance pattern '\(patternName)'", at: patternToken.range)
                    return expressionSequence(chords, range: expression.range)
                }
                let operands = chords.map { lowerExpression($0) }
                if !chords.allSatisfy({ if case .chord = $0.kind { true } else { false } }) {
                    error("A performance pattern currently requires a chord progression", at: expression.range)
                }
                let subdivision = duration(pattern.subdivision).wholeNotes
                return .technique(.init(
                    "__performancePattern",
                    form: .scoped,
                    operands: [.sequence(operands, id: id("performed-chords", expression.range))],
                    parameters: [
                        "name": .string(patternName),
                        "subdivisionNumerator": .integer(subdivision.numerator),
                        "subdivisionDenominator": .integer(subdivision.denominator),
                        "steps": .list(pattern.steps.map(performanceStep)),
                    ]
                ), id: id("performance", expression.range))
            default: preconditionFailure("Mismatched expression dispatch")
            }
        }

        mutating func prepareBindings() {
            for module in modules {
                for constant in module.constants {
                    let key = module.range.fileID + ":" + constant.name.lexeme
                    if bindings[key] != nil { error("Duplicate musical constant '\(constant.name.lexeme)'", at: constant.range); continue }
                    var value = constant.value
                    if let notation = constant.notation {
                        let token: TextToken?
                        let quality: TextToken?
                        switch value {
                        case .pitchClass(let pitch): token = pitch; quality = nil
                        case .chordAbsolute(let root, let q): token = root; quality = q
                        default: token = nil; quality = nil
                        }
                        if let token, let entry = namingEntry(String(token.lexeme), notation: notation, at: token.range) {
                            switch entry.target {
                            case .letter(let letter, let steps):
                                let letterName = ["C", "D", "E", "F", "G", "A", "B"][NoteLetter.allCases.firstIndex(of: letter)!]
                                let text = letterName + String(repeating: steps < 0 ? "b" : "#", count: abs(steps))
                                let canonical = TextToken(kind: .identifier, lexeme: Substring(text), range: token.range)
                                value = quality.map { .chordAbsolute(root: canonical, quality: $0) } ?? .pitchClass(canonical)
                            case .degree(let degree, let steps):
                                let canonical = TextToken(kind: .integerLiteral, lexeme: Substring(String(degree)), range: token.range)
                                value = quality.map { .chordRelative(degree: canonical, alteration: steps, quality: $0) } ?? .scaleDegree(degree: canonical, alteration: steps)
                            }
                        }
                    }
                    bindings[key] = value
                }
            }
        }

        mutating func lookupBinding(_ name: String, at range: SourceRange) -> TextConstantSyntax.Value? {
            let owner = modules.first { $0.range.fileID == range.fileID } ?? syntax
            if let value = bindings[owner.range.fileID + ":" + name] { return value }
            let imports = Set(owner.imports.map { $0.name.value })
            let candidates = modules.filter { imports.contains($0.module?.value ?? "") }.compactMap { bindings[$0.range.fileID + ":" + name] }
            if candidates.count > 1 { error("Ambiguous musical constant '\(name)'", at: range); return nil }
            return candidates.first
        }

        mutating func symbolicBinding(_ rawName: String, useAlteration: Int, at range: SourceRange) -> (binding: TextConstantSyntax.Value?, alteration: Int) {
            if let binding = lookupBinding(rawName, at: range) { return (binding, useAlteration) }
            var name = rawName
            var alteration = useAlteration
            while let suffix = name.last, suffix == "#" || suffix == "b" {
                alteration += suffix == "#" ? 1 : -1
                name.removeLast()
            }
            return (lookupBinding(name, at: range), alteration)
        }

        func performanceStep(_ step: TextPerformanceStepSyntax) -> MetadataValue {
            switch step.kind {
            case .interaction(let words):
                return .object(["words": .list(words.map { .string(String($0.lexeme)) })])
            case .parallel(let children):
                return .object(["parallel": .list(children.map(performanceStep))])
            }
        }

        enum NamingTarget {
            case letter(NoteLetter, Int)
            case degree(Int, Int)
        }

        mutating func validateNamingSystems() {
            for notation in modules.flatMap(\.notationUses) { _ = namingSystem(notation) }
            var names = Set<String>()
            for module in modules {
                for system in module.namingSystems {
                    let qualified = qualifiedSystem(system, module: module)
                    if !names.insert(qualified).inserted { error("Duplicate naming system '\(qualified)'", at: system.range) }
                    let relative = system.register.lexeme == "relativeRegister"
                    if !relative && system.register.lexeme != "absoluteOctave" {
                        error("Expected absoluteOctave or relativeRegister", at: system.register.range)
                    }
                    var entries = Set<String>()
                    for entry in system.entries {
                        if !entries.insert(String(entry.name.lexeme)).inserted { error("Duplicate note name '\(entry.name.lexeme)'", at: entry.name.range) }
                        guard entry.relative == relative, let alteration = entry.alteration.integerValue,
                              (-1_000...1_000).contains(alteration) else {
                            error("Naming target must match register policy and use accidental steps in -1000...1000", at: entry.name.range)
                            continue
                        }
                        if relative {
                            if let degree = entry.target.integerValue, (1...1_000_000).contains(degree) {} else {
                                error("Degree target must be in 1...1000000", at: entry.target.range)
                            }
                        } else if entry.target.lexeme.count != 1 || entry.target.lexeme.first.flatMap(noteLetter) == nil {
                            error("Letter target must be a canonical A–G letter", at: entry.target.range)
                        }
                    }
                }
            }
        }

        func qualifiedSystem(_ system: TextNamingSyntax, module: TextCompositionSyntax) -> String {
            [module.module?.value, String(system.name.lexeme)].compactMap { $0 }.joined(separator: ".")
        }

        mutating func namingSystem(_ notation: TextQualifiedNameSyntax) -> (TextNamingSyntax, TextCompositionSyntax)? {
            let owner = modules.first { $0.range.fileID == notation.range.fileID } ?? syntax
            let local = owner.namingSystems.filter { String($0.name.lexeme) == notation.value }
            let imports = Set(owner.imports.map { $0.name.value })
            let candidates: [(TextNamingSyntax, TextCompositionSyntax)]
            if notation.components.count == 1 && !local.isEmpty {
                candidates = local.map { ($0, owner) }
            } else {
                candidates = modules.flatMap { module in
                    module.namingSystems.compactMap { system in
                        let visible = module.range.fileID == owner.range.fileID || imports.contains(module.module?.value ?? "")
                        let matches = notation.components.count > 1 ? qualifiedSystem(system, module: module) == notation.value : String(system.name.lexeme) == notation.value
                        return visible && matches ? (system, module) : nil
                    }
                }
            }
            guard candidates.count == 1, let (system, module) = candidates.first else {
                error(candidates.isEmpty ? "Unknown naming system '\(notation.value)'" : "Ambiguous naming system '\(notation.value)': \(candidates.map { qualifiedSystem($0.0, module: $0.1) }.sorted().joined(separator: ", "))", at: notation.range)
                return nil
            }
            return (system, module)
        }

        mutating func namingEntry(_ rawName: String, notation: TextQualifiedNameSyntax, at range: SourceRange) -> (target: NamingTarget, system: String)? {
            guard let (system, module) = namingSystem(notation) else { return nil }
            var name = rawName
            var alteration = 0
            var entry = system.entries.first { $0.name.lexeme == name }
            while entry == nil, let suffix = name.last, suffix == "#" || suffix == "b" {
                alteration += suffix == "#" ? 1 : -1
                name.removeLast()
                entry = system.entries.first { $0.name.lexeme == name }
            }
            guard let entry, let base = entry.alteration.integerValue else {
                error("Unknown note name '\(rawName)' in \(notation.value)", at: range)
                return nil
            }
            let qualified = qualifiedSystem(system, module: module)
            if entry.relative, let degree = entry.target.integerValue { return (.degree(degree, base + alteration), qualified) }
            guard let letter = entry.target.lexeme.first.flatMap(noteLetter) else { return nil }
            return (.letter(letter, base + alteration), qualified)
        }

        func namingAnnotations(_ token: TextToken, system: String, range: SourceRange) -> SemanticAnnotations {
            .init(metadata: ["authoredPitch": .string(String(token.lexeme)), "namingSystem": .string(system)], source: range)
        }

        mutating func namedNote(_ token: TextToken, octave: TextToken?, alteration: Int, duration durationSyntax: TextDurationSyntax, notation: TextQualifiedNameSyntax, expression: TextExpressionSyntax) -> MusicalExpression {
            guard let (pitch, system) = namedPitch(token, octave: octave, alteration: alteration, notation: notation) else { return .rest(.zero) }
            return .init(id: id("named-note", expression.range), kind: .note(pitch, duration: duration(durationSyntax), constraints: []), annotations: namingAnnotations(token, system: system, range: expression.range))
        }

        mutating func namedPitch(_ token: TextToken, octave: TextToken?, alteration: Int, notation: TextQualifiedNameSyntax) -> (MusicalPitch, String)? {
            var name = String(token.lexeme)
            var register = octave?.integerValue
            let compact = octave == nil
            if compact {
                let digits = name.reversed().prefix { $0.isNumber }.reversed()
                if !digits.isEmpty {
                    name.removeLast(digits.count)
                    var text = String(digits)
                    if name.last == "-" { name.removeLast(); text = "-" + text }
                    register = Int(text)
                }
            }
            guard let register, (-1_000...1_000).contains(register) else {
                error("Named note requires a representable register in -1000...1000", at: token.range)
                return nil
            }
            guard let entry = namingEntry(name, notation: notation, at: token.range) else { return nil }
            let pitch: MusicalPitch
            switch entry.target {
            case .letter(let letter, let steps):
                pitch = .absolute(.init(.init(letter, accidental: steps + alteration), octave: register))
            case .degree(let degree, let steps):
                if compact { error("Relative note names require a bracketed register", at: token.range) }
                pitch = .scaleDegree(degree, octave: register, alteration: steps + alteration)
            }
            return (pitch, entry.system)
        }

        mutating func duration(_ syntax: TextDurationSyntax) -> MusicalDuration {
            var value: Rational?
            switch syntax.kind {
            case .fraction(let n, let d):
                if let n = n.integerValue, let d = d.integerValue, n > 0, d > 0 { value = Rational(n, d) }
            case .named(let token, let dots):
                let denominators = ["w": 1, "h": 2, "q": 4, "e": 8, "s": 16]
                if let denominator = denominators[String(token.lexeme)] {
                    value = Rational(1, denominator)
                    var addition = value
                    for _ in 0..<dots {
                        addition = addition?.multiplied(by: Rational(1, 2))
                        guard let next = addition else { value = nil; break }
                        value = value?.adding(next)
                        if value == nil { break }
                    }
                }
            }
            guard let value else {
                error("Invalid duration: expected a positive representable rational duration or w, h, q, e, s with optional dots", at: syntax.range)
                return .zero
            }
            return MusicalDuration(value.numerator, value.denominator)
        }

        mutating func parsePitch(_ token: TextToken) -> AbsolutePitch? {
            let text = String(token.lexeme)
            guard let first = text.first, let letter = noteLetter(first) else { return nil }
            var cursor = text.index(after: text.startIndex)
            var accidental = 0
            while cursor < text.endIndex, text[cursor] == "#" || text[cursor] == "b" {
                accidental += text[cursor] == "#" ? 1 : -1
                cursor = text.index(after: cursor)
            }
            guard cursor < text.endIndex, let octave = Int(text[cursor...]) else { return nil }
            return .init(.init(letter, accidental: accidental), octave: octave)
        }

        mutating func lowerScale(_ tonic: TextToken, _ mode: TextToken) -> Scale? {
            let spelling: SpelledPitchClass
            if let notation = syntax.defaultNotation {
                guard let entry = namingEntry(String(tonic.lexeme), notation: notation, at: tonic.range),
                      case .letter(let letter, let steps) = entry.target else {
                    error("Scale tonic requires an absolute letter naming system", at: tonic.range)
                    return nil
                }
                spelling = .init(letter, accidental: steps)
            } else if let value = parsePitchClass(String(tonic.lexeme)) { spelling = value }
            else { error("Invalid scale tonic '\(tonic.lexeme)'", at: tonic.range); return nil }
            let kind = scaleKinds[String(mode.lexeme)]
            guard let kind else { error("Unsupported scale mode '\(mode.lexeme)'", at: mode.range); return nil }
            guard isValid(kind) else { error("Scale '\(mode.lexeme)' must start at 0 cents and contain strictly increasing offsets below 1200 cents", at: mode.range); return nil }
            return .init(spelling, kind)
        }

        func isValid(_ kind: ScaleKind) -> Bool {
            let intervals = kind.centIntervals
            return intervals.first == 0 && intervals.allSatisfy { 0 <= $0 && $0 < 1_200 }
                && zip(intervals, intervals.dropFirst()).allSatisfy(<)
        }

        func parsePitchClass(_ text: String) -> SpelledPitchClass? {
            guard let first = text.first, let letter = noteLetter(first) else { return nil }
            var accidental = 0
            for character in text.dropFirst() {
                if character == "#" { accidental += 1 } else if character == "b" { accidental -= 1 } else { return nil }
            }
            return .init(letter, accidental: accidental)
        }

        func chordQuality(_ token: TextToken) -> ChordQuality? {
            switch token.lexeme {
            case "major": .major
            case "minor": .minor
            case "diminished": .diminished
            case "sus4": .suspendedFourth
            default: nil
            }
        }

        func noteLetter(_ character: Character) -> NoteLetter? {
            switch character.uppercased() {
            case "C": .c; case "D": .d; case "E": .e; case "F": .f
            case "G": .g; case "A": .a; case "B": .b; default: nil
            }
        }

        func id(_ kind: String, _ range: SourceRange) -> SemanticID {
            .source(kind: kind, fileID: range.fileID, line: UInt(range.start.line), column: UInt(range.start.column))
        }

        mutating func error(_ message: String, at range: SourceRange) {
            diagnostics.append(.init(.error, message: message, range: range))
        }
    }
}

public struct TextCompositionFrontend: Sendable {
    public init() {}

    public func compile(_ source: TextSource) -> TextSemanticResult {
        let parsed = TextParser().parse(source)
        guard let syntax = parsed.syntax else { return .init(composition: nil, instruments: [], diagnostics: parsed.diagnostics) }
        let lowered = TextSemanticLowerer().lower(syntax)
        return .init(composition: lowered.composition, instruments: lowered.instruments, diagnostics: parsed.diagnostics + lowered.diagnostics)
    }
}
