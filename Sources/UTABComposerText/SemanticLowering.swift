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
    public let tuning: String?
    public let fingering: String?
    public let displayName: String?
    public let range: SourceRange
}

public struct TextSemanticLowerer: Sendable {
    public init() {}

    public func lower(_ syntax: TextCompositionSyntax) -> TextSemanticResult {
        let definitions = scaleKinds(in: [syntax])
        let qualities = chordQualities(in: [syntax])
        var worker = Worker(syntax: syntax, modules: [syntax], scaleKinds: definitions.kinds, chordQualities: qualities.qualities, bindings: [:], diagnostics: definitions.diagnostics + qualities.diagnostics, activeMeter: nil)
        return worker.lower()
    }

    public func lower(_ modules: [TextLoadedModule]) -> TextSemanticResult {
        guard let root = modules.last(where: \.isRoot) else {
            return .init(composition: nil, instruments: [], diagnostics: [])
        }
        let definitions = scaleKinds(in: modules.map(\.syntax))
        let qualities = chordQualities(in: modules.map(\.syntax))
        var worker = Worker(syntax: root.syntax, modules: modules.map(\.syntax), scaleKinds: definitions.kinds, chordQualities: qualities.qualities, bindings: [:], diagnostics: definitions.diagnostics + qualities.diagnostics, activeMeter: nil)
        return worker.lower()
    }

    /// Resolves catalogue pitch tokens through the same declaration-site naming rules as notes.
    public func resolvePitch(_ token: TextToken, notation: TextQualifiedNameSyntax, in modules: [TextLoadedModule]) -> (pitch: AbsolutePitch?, diagnostics: [TextDiagnostic]) {
        guard let owner = modules.first(where: { $0.syntax.range.fileID == token.range.fileID }) else { return (nil, []) }
        var worker = Worker(syntax: owner.syntax, modules: modules.map(\.syntax), scaleKinds: [:], chordQualities: [:], bindings: [:], diagnostics: [], activeMeter: nil)
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

    private func chordQualities(in syntaxes: [TextCompositionSyntax]) -> (qualities: [String: ChordQuality], diagnostics: [TextDiagnostic]) {
        var result: [String: ChordQuality] = [
            "major": .major, "minor": .minor, "diminished": .diminished, "sus4": .suspendedFourth,
            "major7": .majorSeventh, "minor7": .minorSeventh, "dominant7": .dominantSeventh,
        ]
        var declared: Set<String> = []
        var diagnostics: [TextDiagnostic] = []
        for definition in syntaxes.flatMap(\.chordQualityDefinitions) {
            let name = String(definition.symbol.lexeme)
            let degrees = definition.degrees.compactMap(\.integerValue)
            let semitones = definition.semitones.compactMap(\.integerValue)
            guard !declared.contains(name) else {
                diagnostics.append(.init(.error, message: "Duplicate chord quality '\(name)'", range: definition.range)); continue
            }
            declared.insert(name)
            guard degrees.first == 1, semitones.first == 0, degrees.count == semitones.count,
                  zip(degrees, degrees.dropFirst()).allSatisfy(<),
                  zip(semitones, semitones.dropFirst()).allSatisfy(<),
                  degrees.allSatisfy({ (1...13).contains($0) }), semitones.allSatisfy({ (0..<24).contains($0) }) else {
                diagnostics.append(.init(.error, message: "Chord quality '\(name)' requires matching ascending degrees/semitones beginning with 1 and 0", range: definition.range)); continue
            }
            result[name] = .init(name: name, degrees: degrees, intervals: semitones)
        }
        return (result, diagnostics)
    }

    private struct Worker {
        let syntax: TextCompositionSyntax
        let modules: [TextCompositionSyntax]
        let scaleKinds: [String: ScaleKind]
        let chordQualities: [String: ChordQuality]
        var bindings: [String: TextConstantSyntax.Value]
        var diagnostics: [TextDiagnostic]
        var activeMeter: TimeSignature?
        var pitchParameters: [String: MusicalPitch] = [:]
        var integerParameters: [String: Int] = [:]
        var phraseCallStack: [SemanticID] = []

        mutating func lower() -> TextSemanticResult {
            validateNamingSystems()
            validatePhraseParameters()
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
            activeMeter = meter
            let phrases = modules.flatMap(\.phrases).filter(\.parameters.isEmpty).map { phrase in
                activeMeter = meter
                return lowerPhrase(phrase)
            }
            activeMeter = meter
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
                    tuning: $0.tuning?.value,
                    fingering: $0.fingering?.value,
                    displayName: $0.displayName?.stringValue,
                    range: $0.range
                )
            }
        }

        mutating func validatePhraseParameters() {
            for phrase in modules.flatMap(\.phrases) {
                var names: Set<String> = []
                for parameter in phrase.parameters {
                    let name = String(parameter.name.lexeme)
                    if !names.insert(name).inserted {
                        error("Duplicate phrase parameter '\(name)'", at: parameter.name.range)
                    }
                    if parameter.type.lexeme != "pitch" && parameter.type.lexeme != "integer" {
                        error("Unsupported phrase parameter type '\(parameter.type.lexeme)'; expected 'pitch' or 'integer'", at: parameter.type.range)
                    }
                }
            }
        }

        func phraseID(_ phrase: TextPhraseSyntax) -> SemanticID {
            let module = modules.first { $0.range.fileID == phrase.range.fileID }
            let name = String(phrase.name.lexeme)
            return .named("phrase", module?.range.fileID == syntax.range.fileID ? name : (module?.module?.value ?? phrase.range.fileID) + "." + name)
        }

        mutating func resolvePhrase(_ token: TextToken) -> SemanticID {
            guard let phrase = resolvePhraseSyntax(token) else { return .named("phrase", String(token.lexeme)) }
            return phraseID(phrase)
        }

        mutating func resolvePhraseSyntax(_ token: TextToken) -> TextPhraseSyntax? {
            let owner = modules.first { $0.range.fileID == token.range.fileID } ?? syntax
            let local = owner.phrases.filter { $0.name.lexeme == token.lexeme }
            if local.count == 1 { return local[0] }
            let imports = Set(owner.imports.map { $0.name.value })
            let candidates = modules.filter { $0.range.fileID == owner.range.fileID || imports.contains($0.module?.value ?? "") }.flatMap { module in
                module.phrases.filter { phrase in
                    token.lexeme.contains(".") ? (module.module?.value ?? "") + "." + phrase.name.lexeme == token.lexeme : phrase.name.lexeme == token.lexeme
                }
            }
            if candidates.count == 1 { return candidates[0] }
            error(candidates.isEmpty ? "Unknown phrase '\(token.lexeme)'" : "Ambiguous phrase '\(token.lexeme)'", at: token.range)
            return nil
        }

        mutating func lowerPhrase(_ phrase: TextPhraseSyntax) -> Phrase {
            if !phrase.expressions.isEmpty, phrase.expressions.allSatisfy({ if case .bar = $0.kind { true } else { false } }) {
                let bars = phrase.expressions.map { expression -> Bar in
                    guard case .bar(let children) = expression.kind else { preconditionFailure() }
                    return .init(
                        expressionSequence(children, range: expression.range),
                        id: id("bar", expression.range),
                        metadata: ["inheritsMeterAtUseSite": .boolean(true)],
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
            if case .reference(let token, let arguments) = expression.kind,
               arguments.isEmpty,
               resolvePhraseSyntax(token)?.parameters.isEmpty == true {
                return .reference(resolvePhrase(token))
            }
            return .expression(lowerExpression(expression))
        }

        mutating func lowerBoundaryContents(_ expressions: [TextExpressionSyntax], range: SourceRange) -> [VoiceContent] {
            let inherited = activeMeter
            defer { activeMeter = inherited }
            var lowered: [VoiceContent] = []
            for expression in expressions {
                lowered.append(lowerVoiceContent(expression))
                if case .meter(let numerator, let denominator) = expression.kind,
                   let n = numerator.integerValue, let d = denominator.integerValue, n > 0, d > 0 {
                    activeMeter = .init(n, d)
                }
            }
            let durations = lowered.map { content -> MusicalDuration? in
                guard case .expression(let expression) = content else { return nil }
                return expression.duration
            }
            validateBoundaryBars(expressions, lowered: lowered.map { content in
                guard case .expression(let expression) = content else { return nil }
                return expression
            }, durations: durations, range: range)
            return lowered
        }

        mutating func lowerBoundarySequence(_ expressions: [TextExpressionSyntax], range: SourceRange) -> MusicalExpression {
            let lowered = lowerScopedExpressions(expressions)
            validateBoundaryBars(expressions, lowered: lowered.map(Optional.some), durations: lowered.map(\.duration), range: range)
            return .sequence(lowered, id: id("sequence", range))
        }

        mutating func validateBoundaryBars(_ expressions: [TextExpressionSyntax], lowered: [MusicalExpression?], durations: [MusicalDuration?], range: SourceRange) {
            let pickups = expressions.indices.filter { if case .pickup = expressions[$0].kind { true } else { false } }
            let finals = expressions.indices.filter { if case .finalBar = expressions[$0].kind { true } else { false } }
            let musicalIndices = expressions.indices.filter { if case .meter = expressions[$0].kind { false } else { true } }
            for index in pickups where index != musicalIndices.first { error("A pickup must be the first musical expression in its scope", at: expressions[index].range) }
            for index in finals where index != musicalIndices.last { error("An incomplete final bar must be the last musical expression in its scope", at: expressions[index].range) }
            if pickups.count > 1 { error("A scope may contain only one pickup", at: range) }
            if finals.count > 1 { error("A scope may contain only one incomplete final bar", at: range) }
            if let pickup = pickups.first, let final = finals.first,
               let pickupDuration = durations[pickup], let finalDuration = durations[final],
               case .integer(let pickupNumerator)? = lowered[pickup]?.annotations.metadata["expectedMeterNumerator"],
               case .integer(let pickupDenominator)? = lowered[pickup]?.annotations.metadata["expectedMeterDenominator"],
               case .integer(let finalNumerator)? = lowered[final]?.annotations.metadata["expectedMeterNumerator"],
               case .integer(let finalDenominator)? = lowered[final]?.annotations.metadata["expectedMeterDenominator"],
               pickupNumerator == finalNumerator, pickupDenominator == finalDenominator,
               pickupDuration + finalDuration != MusicalDuration(pickupNumerator, pickupDenominator) {
                error("Pickup and incomplete final bar durations must complement the active meter", at: expressions[final].range)
            }
        }

        mutating func expressionSequence(_ expressions: [TextExpressionSyntax], range: SourceRange) -> MusicalExpression {
            .sequence(lowerScopedExpressions(expressions), id: id("sequence", range))
        }

        mutating func lowerScopedExpressions(_ expressions: [TextExpressionSyntax]) -> [MusicalExpression] {
            let inherited = activeMeter
            defer { activeMeter = inherited }
            var result: [MusicalExpression] = []
            for expression in expressions {
                let lowered = lowerExpression(expression)
                result.append(lowered)
                if case .meter(let numerator, let denominator) = expression.kind,
                   let n = numerator.integerValue, let d = denominator.integerValue, n > 0, d > 0 {
                    activeMeter = .init(n, d)
                }
            }
            return result
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
            case .rhythmicTransform(let kind, let numerator, let denominator, let expressions):
                guard let n = numerator.integerValue, let d = denominator.integerValue, n > 0, d > 0 else {
                    error("Rhythmic transform ratios require positive representable integers", at: expression.range)
                    result = .rest(.zero)
                    break
                }
                let factor = kind.lexeme == "augment" ? Rational(n, d) : Rational(d, n)
                result = .init(
                    id: id("\(kind.lexeme):\(n)/\(d)", expression.range),
                    kind: .proportional(factor, expressionSequence(expressions, range: expression.range)),
                    annotations: .init(metadata: ["rhythmicTransform": .string(String(kind.lexeme)), "ratio": .string("\(n)/\(d)")], source: expression.range)
                )
            case .transposePitch(let semitones, let expressions):
                guard let amount = integerValue(semitones), (-127...127).contains(amount) else {
                    error("Pitch transposition requires an integer semitone count in -127...127", at: semitones.range)
                    result = expressionSequence(expressions, range: expression.range)
                    break
                }
                let operand = expressionSequence(expressions, range: expression.range)
                result = .technique(.init(
                    "__transposePitch",
                    form: .scoped,
                    operands: [operand],
                    parameters: ["semitones": .integer(amount)]
                ), id: id("transpose-pitch:\(amount)", expression.range))
            case .transposeDegree(let degrees, let expressions):
                guard let amount = integerValue(degrees), (-127...127).contains(amount) else {
                    error("Degree transposition requires an integer scale-degree count in -127...127", at: degrees.range)
                    result = expressionSequence(expressions, range: expression.range)
                    break
                }
                let operand = expressionSequence(expressions, range: expression.range)
                result = .technique(.init(
                    "__transposeDegree",
                    form: .scoped,
                    operands: [operand],
                    parameters: ["degrees": .integer(amount)]
                ), id: id("transpose-degree:\(amount)", expression.range))
            case .bar: result = lowerBarExpression(expression)
            case .pickup, .finalBar: result = lowerPartialBarExpression(expression)
            case .meter: result = lowerMeterExpression(expression)
            case .scale(let tonic, let mode):
                guard let scale = lowerScale(tonic, mode) else {
                    result = .rest(.zero, id: id("invalid-scale-change", expression.range))
                    break
                }
                result = .init(id: id("scale", expression.range), kind: .rest(.zero), annotations: .init(metadata: [
                    "scaleTonicLetter": .integer(scale.tonicSpelling.letter.rawValue),
                    "scaleTonicAccidental": .integer(scale.tonicSpelling.accidental),
                    "scaleTonicTuningCents": .integer(scale.tonicSpelling.tuningOffsetCents),
                    "scaleName": .string(String(mode.lexeme)),
                    "scaleIntervals": .list(scale.kind.centIntervals.map(MetadataValue.integer)),
                ], source: expression.range))
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
            case .dynamic: result = lowerDynamicExpression(expression)
            case .dynamicEnvelope: result = lowerDynamicEnvelopeExpression(expression)
            case .pedal(let expressions):
                result = .technique(.init(
                    "__sustainPedal",
                    form: .scoped,
                    operands: [expressionSequence(expressions, range: expression.range)]
                ), id: id("pedal", expression.range))
            case .grace(let policy, let budgetSyntax, let expressions):
                var parameters: [String: MetadataValue] = ["policy": .string(String(policy.lexeme))]
                if let budgetSyntax {
                    let budget = duration(budgetSyntax).wholeNotes
                    parameters["graceBudgetNumerator"] = .integer(budget.numerator)
                    parameters["graceBudgetDenominator"] = .integer(budget.denominator)
                }
                result = .technique(.init(
                    "__grace",
                    form: .scoped,
                    operands: [expressionSequence(expressions, range: expression.range)],
                    parameters: parameters
                ), id: id("grace:\(policy.lexeme)", expression.range))
            case .ornament(let name, let subdivisionSyntax, let expressions):
                let supported = ["trill", "mordent", "turn", "appoggiatura"]
                guard supported.contains(String(name.lexeme)) else {
                    error("Unknown ornament '\(name.lexeme)'; expected trill, mordent, turn, or appoggiatura", at: name.range)
                    result = expressionSequence(expressions, range: expression.range)
                    break
                }
                let subdivision = duration(subdivisionSyntax).wholeNotes
                result = .technique(.init(
                    "__ornament",
                    form: .scoped,
                    operands: [expressionSequence(expressions, range: expression.range)],
                    parameters: [
                        "name": .string(String(name.lexeme)),
                        "subdivisionNumerator": .integer(subdivision.numerator),
                        "subdivisionDenominator": .integer(subdivision.denominator),
                    ]
                ), id: id("ornament:\(name.lexeme)", expression.range))
            case .bass(let pattern, let subdivisionSyntax, let octaveToken, let chords):
                let matches = modules.flatMap(\.bassPatterns).filter { $0.name.lexeme == pattern.lexeme }
                guard let definition = matches.first else {
                    error("Unknown bass pattern '\(pattern.lexeme)'; import or define it before use", at: pattern.range)
                    result = expressionSequence(chords, range: expression.range)
                    break
                }
                if matches.count > 1 { error("Ambiguous bass pattern '\(pattern.lexeme)'", at: pattern.range) }
                let degrees = definition.degrees.compactMap { token -> Int? in
                    let degree = token.lexeme == "root" ? 1 : token.integerValue
                    guard let degree, [1, 3, 5, 7, 9, 11, 13].contains(degree) else {
                        error("Bass-pattern degrees must be root or an odd chord degree through 13", at: token.range)
                        return nil
                    }
                    return degree
                }
                guard let octave = octaveToken.integerValue, (0...9).contains(octave) else {
                    error("Bass octave must be in 0...9", at: octaveToken.range)
                    result = expressionSequence(chords, range: expression.range)
                    break
                }
                if !chords.allSatisfy({ if case .chord = $0.kind { true } else { false } }) {
                    error("A bass pattern requires a chord progression", at: expression.range)
                }
                let subdivision = duration(subdivisionSyntax).wholeNotes
                result = .technique(.init(
                    "__bassPattern",
                    form: .scoped,
                    operands: [.sequence(chords.map { lowerExpression($0) }, id: id("bass-chords", expression.range))],
                    parameters: [
                        "pattern": .string(String(pattern.lexeme)),
                        "degrees": .list(degrees.map(MetadataValue.integer)),
                        "octave": .integer(octave),
                        "subdivisionNumerator": .integer(subdivision.numerator),
                        "subdivisionDenominator": .integer(subdivision.denominator),
                    ]
                ), id: id("bass:\(pattern.lexeme)", expression.range))
            case .voiceLeading(let policy, let expressions):
                guard policy.lexeme == "nearest" else {
                    error("Unknown voice-leading policy '\(policy.lexeme)'; expected nearest", at: policy.range)
                    result = expressionSequence(expressions, range: expression.range)
                    break
                }
                result = .technique(.init(
                    "__voiceLeading",
                    form: .scoped,
                    operands: [expressionSequence(expressions, range: expression.range)],
                    parameters: ["policy": .string("nearest")]
                ), id: id("voice-leading:nearest", expression.range))
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

        mutating func lowerDynamicExpression(_ expression: TextExpressionSyntax) -> MusicalExpression {
            guard case .dynamic(let level, let expressions) = expression.kind else {
                preconditionFailure("Mismatched expression dispatch")
            }
            let intensities: [String: Double] = [
                "ppp": 0.18, "pp": 0.28, "p": 0.38, "mp": 0.52,
                "mf": 0.66, "f": 0.78, "ff": 0.90, "fff": 1.0,
            ]
            guard let intensity = intensities[String(level.lexeme)] else {
                error("Unknown dynamic level '\(level.lexeme)'; expected ppp, pp, p, mp, mf, f, ff, or fff", at: level.range)
                return expressionSequence(expressions, range: expression.range)
            }
            return .technique(.init(
                "__dynamic",
                form: .scoped,
                operands: [expressionSequence(expressions, range: expression.range)],
                parameters: ["level": .string(String(level.lexeme)), "intensity": .decimal(intensity)]
            ), id: id("dynamic:\(level.lexeme)", expression.range))
        }

        mutating func lowerDynamicEnvelopeExpression(_ expression: TextExpressionSyntax) -> MusicalExpression {
            guard case .dynamicEnvelope(let direction, let target, let expressions) = expression.kind else {
                preconditionFailure("Mismatched expression dispatch")
            }
            let intensities: [String: Double] = [
                "ppp": 0.18, "pp": 0.28, "p": 0.38, "mp": 0.52,
                "mf": 0.66, "f": 0.78, "ff": 0.90, "fff": 1.0,
            ]
            guard let intensity = intensities[String(target.lexeme)] else {
                error("Unknown dynamic level '\(target.lexeme)'; expected ppp, pp, p, mp, mf, f, ff, or fff", at: target.range)
                return expressionSequence(expressions, range: expression.range)
            }
            return .technique(.init(
                "__dynamicEnvelope",
                form: .scoped,
                operands: [expressionSequence(expressions, range: expression.range)],
                parameters: ["direction": .string(String(direction.lexeme)), "target": .decimal(intensity)]
            ), id: id("dynamic-envelope:\(direction.lexeme)", expression.range))
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
                case .chord(let root, let quality, let durationToken, let shape, let bass, let inversion, _, _, _, _, _):
                    guard let entry = namingEntry(String(root.lexeme), notation: notation, at: root.range),
                          let quality = chordQuality(quality) else { return .rest(.zero) }
                    let chord: ChordSymbol
                    switch entry.target {
                    case .letter(let letter, let alteration): chord = .init(.init(letter, accidental: alteration), quality, bass: bass.flatMap { parsePitchClass(String($0.lexeme)) }, inversion: inversion?.integerValue)
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
                if (degree.integerValue ?? 0) <= 0 {
                    error("Scale-relative note degrees must be positive", at: degree.range)
                }
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
            case .chord(let root, let quality, let durationToken, let shape, let bass, let inversion, let omissions, let doublings, let additions, let alterations, let range):
                guard let spelling = parsePitchClass(String(root.lexeme)) else {
                    error("Invalid chord root '\(root.lexeme)'", at: root.range)
                    return .rest(.zero, id: id("invalid", expression.range))
                }
                guard let chordQuality = chordQuality(quality) else {
                    error("Unsupported chord quality '\(quality.lexeme)'", at: quality.range)
                    return .rest(.zero, id: id("invalid", expression.range))
                }
                let bassPitch = bass.flatMap { parsePitchClass(String($0.lexeme)) }
                if bass != nil && bassPitch == nil { error("Invalid chord bass '\(bass!.lexeme)'", at: bass!.range) }
                let inversionValue = inversion?.integerValue
                if let inversionValue, !chordQuality.intervals.indices.contains(inversionValue) {
                    error("Chord inversion must be in 0...\(chordQuality.intervals.count - 1)", at: inversion!.range)
                }
                if let bassPitch, let inversionValue, chordQuality.intervals.indices.contains(inversionValue),
                   (spelling.pitchClass.rawValue + chordQuality.intervals[inversionValue]) % 12 != bassPitch.pitchClass.rawValue {
                    error("Explicit chord bass and inversion disagree", at: bass!.range)
                }
                var constraints: [PerformanceConstraint] = shape.map { [.chordShape(String($0.lexeme))] } ?? []
                let availableDegrees = Set(chordQuality.degrees).union(additions.compactMap { $0.degree.integerValue })
                constraints.append(contentsOf: chordMemberConstraints(omissions, kind: "omit", availableDegrees: availableDegrees))
                constraints.append(contentsOf: chordMemberConstraints(doublings, kind: "double", availableDegrees: availableDegrees))
                constraints.append(contentsOf: chordToneConstraints(additions, alterations: alterations, quality: chordQuality))
                if let range, let low = parsePitch(range.low), let high = parsePitch(range.high) {
                    if low.chromaticIndex >= high.chromaticIndex { error("Chord range must ascend from low to high", at: range.low.range) }
                    else { constraints.append(.pitchRange(low, high)) }
                }
                return .init(
                    id: id("chord", expression.range),
                    kind: .chord(.init(spelling, chordQuality, bass: bassPitch, inversion: inversionValue), duration: duration(durationToken), constraints: constraints),
                    annotations: .init(source: expression.range)
                )
            default: preconditionFailure("Mismatched expression dispatch")
            }
        }

        mutating func lowerRelativechordExpression(_ expression: TextExpressionSyntax) -> MusicalExpression {
            switch expression.kind {
            case .relativeChord(let degree, let alteration, let quality, let durationToken, let shape, let bass, let inversion, let omissions, let doublings, let additions, let alterations, let range):
                if (degree.integerValue ?? 0) <= 0 {
                    error("Scale-relative chord degrees must be positive", at: degree.range)
                }
                guard let chordQuality = chordQuality(quality) else {
                    error("Unsupported chord quality '\(quality.lexeme)'", at: quality.range)
                    return .rest(.zero, id: id("invalid", expression.range))
                }
                let bassPitch = bass.flatMap { parsePitchClass(String($0.lexeme)) }
                if bass != nil && bassPitch == nil { error("Invalid chord bass '\(bass!.lexeme)'", at: bass!.range) }
                let inversionValue = inversion?.integerValue
                if let inversionValue, !chordQuality.intervals.indices.contains(inversionValue) {
                    error("Chord inversion must be in 0...\(chordQuality.intervals.count - 1)", at: inversion!.range)
                }
                var constraints: [PerformanceConstraint] = shape.map { [.chordShape(String($0.lexeme))] } ?? []
                let availableDegrees = Set(chordQuality.degrees).union(additions.compactMap { $0.degree.integerValue })
                constraints.append(contentsOf: chordMemberConstraints(omissions, kind: "omit", availableDegrees: availableDegrees))
                constraints.append(contentsOf: chordMemberConstraints(doublings, kind: "double", availableDegrees: availableDegrees))
                constraints.append(contentsOf: chordToneConstraints(additions, alterations: alterations, quality: chordQuality))
                if let range, let low = parsePitch(range.low), let high = parsePitch(range.high) {
                    if low.chromaticIndex >= high.chromaticIndex { error("Chord range must ascend from low to high", at: range.low.range) }
                    else { constraints.append(.pitchRange(low, high)) }
                }
                return .init(
                    id: id("relative-chord", expression.range),
                    kind: .chord(.init(scaleDegree: degree.integerValue ?? 0, alteration: alteration, chordQuality, bass: bassPitch, inversion: inversionValue), duration: duration(durationToken), constraints: constraints),
                    annotations: .init(source: expression.range)
                )
            default: preconditionFailure("Mismatched expression dispatch")
            }
        }

        mutating func lowerSymbolExpression(_ expression: TextExpressionSyntax) -> MusicalExpression {
            switch expression.kind {
            case .symbol(let name, let useAlteration, let octave, let durationToken):
                if let pitch = pitchParameters[String(name.lexeme)] {
                    if octave != nil || useAlteration != 0 {
                        error("Pitch parameters already carry their octave and accidental", at: expression.range)
                    }
                    return .init(id: id("pitch-parameter:\(name.lexeme)", expression.range), kind: .note(pitch, duration: duration(durationToken), constraints: []), annotations: .init(source: expression.range))
                }
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
            case .reference(let token, let arguments):
                guard let phrase = resolvePhraseSyntax(token) else {
                    return .rest(.zero, id: id("invalid-phrase-call", expression.range))
                }
                if phrase.parameters.isEmpty {
                    if !arguments.isEmpty { error("Phrase '\(token.lexeme)' does not accept arguments", at: expression.range) }
                    return .reference(phraseID(phrase), id: id("phrase-reference", expression.range))
                }
                let parametersByName = Dictionary(uniqueKeysWithValues: phrase.parameters.map { (String($0.name.lexeme), $0) })
                let parameterNames = phrase.parameters.map { String($0.name.lexeme) }
                var suppliedPitches: [String: MusicalPitch] = [:]
                var suppliedIntegers: [String: Int] = [:]
                var suppliedLabels: Set<String> = []
                for argument in arguments {
                    let label = String(argument.label.lexeme)
                    guard let parameter = parametersByName[label] else {
                        error("Unexpected argument label '\(label)' in call to '\(token.lexeme)'", at: argument.label.range)
                        continue
                    }
                    if !suppliedLabels.insert(label).inserted {
                        error("Duplicate argument label '\(label)' in call to '\(token.lexeme)'", at: argument.label.range)
                        continue
                    }
                    if parameter.type.lexeme == "pitch" {
                        if let value = evaluatePitch(argument.value) { suppliedPitches[label] = value }
                        else { error("Argument '\(label)' requires a pitch expression", at: argument.value.range) }
                    } else if parameter.type.lexeme == "integer" {
                        if let value = evaluateInteger(argument.value) { suppliedIntegers[label] = value }
                        else { error("Argument '\(label)' requires an integer expression", at: argument.value.range) }
                    }
                }
                for name in parameterNames where !suppliedLabels.contains(name) {
                    error("Missing argument label '\(name)' in call to '\(token.lexeme)'", at: expression.range)
                }
                let targetID = phraseID(phrase)
                if phraseCallStack.contains(targetID) {
                    error("Recursive parameterized phrase call '\(token.lexeme)' is not allowed", at: expression.range)
                    return .rest(.zero, id: id("recursive-phrase-call", expression.range))
                }
                let previousParameters = pitchParameters
                let previousIntegers = integerParameters
                pitchParameters.merge(suppliedPitches) { _, supplied in supplied }
                integerParameters.merge(suppliedIntegers) { _, supplied in supplied }
                phraseCallStack.append(targetID)
                let operand = lowerBoundarySequence(phrase.expressions, range: phrase.range)
                phraseCallStack.removeLast()
                pitchParameters = previousParameters
                integerParameters = previousIntegers
                return .technique(.init(
                    "__phraseApplication",
                    form: .scoped,
                    operands: [operand],
                    parameters: ["phrase": .string(targetID.rawValue)]
                ), id: id("phrase-call:\(token.lexeme)", expression.range))
            default: preconditionFailure("Mismatched expression dispatch")
            }
        }

        func integerValue(_ token: TextToken) -> Int? {
            token.integerValue ?? integerParameters[String(token.lexeme)]
        }

        func evaluateInteger(_ expression: TextValueExpressionSyntax) -> Int? {
            guard case .atom(let token) = expression else { return nil }
            return integerValue(token)
        }

        mutating func evaluatePitch(_ expression: TextValueExpressionSyntax) -> MusicalPitch? {
            switch expression {
            case .atom(let token):
                if let inherited = pitchParameters[String(token.lexeme)] { return inherited }
                return parsePitch(token).map(MusicalPitch.absolute)
            case .pitchOffset(let base, let operation, let amountToken, let unit):
                guard let pitch = evaluatePitch(base), let rawAmount = integerValue(amountToken) else { return nil }
                let amount = operation.kind == .minus ? -rawAmount : rawAmount
                switch String(unit.lexeme) {
                case "semitone", "semitones":
                    switch pitch {
                    case .absolute(let absolute): return .absolute(absolute.transposed(cents: amount * 100))
                    case .scaleDegree(let degree, let octave, let alteration): return .scaleDegree(degree, octave: octave, alteration: alteration + amount)
                    }
                case "degree", "degrees":
                    guard case .scaleDegree(let degree, let octave, let alteration) = pitch else { return nil }
                    return .scaleDegree(degree + amount, octave: octave, alteration: alteration)
                default: return nil
                }
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
                let meter = activeMeter
                return .init(id: id("bar", expression.range), kind: .barAssertion(expressionSequence(expressions, range: expression.range)), annotations: .init(metadata: meterMetadata(meter), source: expression.range))
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
                annotations: .init(metadata: ["barRole": .string(role)].merging(meterMetadata(activeMeter)) { current, _ in current }, source: expression.range)
            )
        }

        mutating func lowerMeterExpression(_ expression: TextExpressionSyntax) -> MusicalExpression {
            guard case .meter(let numerator, let denominator) = expression.kind,
                  let n = numerator.integerValue, let d = denominator.integerValue, n > 0, d > 0 else {
                error("Meter values must be positive integers", at: expression.range)
                return .rest(.zero, id: id("invalid-meter", expression.range))
            }
            return .init(id: id("meter", expression.range), kind: .rest(.zero), annotations: .init(metadata: [
                "meterNumerator": .integer(n), "meterDenominator": .integer(d)
            ], source: expression.range))
        }

        func meterMetadata(_ meter: TimeSignature?) -> [String: MetadataValue] {
            guard let meter else { return [:] }
            return ["expectedMeterNumerator": .integer(meter.numerator), "expectedMeterDenominator": .integer(meter.denominator)]
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
                for child in expressions where containsContextDirective(child) {
                    error("Meter, scale, and tempo changes are not allowed inside parallel branches", at: child.range)
                }
                return .parallel(expressions.map { lowerExpression($0) }, id: id("parallel", expression.range))
            default: preconditionFailure("Mismatched expression dispatch")
            }
        }

        func containsContextDirective(_ expression: TextExpressionSyntax) -> Bool {
            switch expression.kind {
            case .meter, .scale, .tempo, .tempoRamp: return true
            case .sequence(let children), .parallel(let children), .bar(let children), .pickup(let children), .finalBar(let children),
                 .repeated(_, let children), .dynamic(_, let children), .dynamicEnvelope(_, _, let children), .pedal(let children),
                 .grace(_, _, let children), .ornament(_, _, let children), .voiceLeading(_, let children), .technique(_, let children),
                 .transposePitch(_, let children), .transposeDegree(_, let children), .rhythmicTransform(_, _, _, let children):
                return children.contains(where: containsContextDirective)
            case .proportional(_, _, _, let children): return children.contains(where: containsContextDirective)
            case .bass(_, _, _, let children), .performed(_, let children): return children.contains(where: containsContextDirective)
            default: return false
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
            chordQualities[String(token.lexeme)]
        }

        mutating func chordMemberConstraints(_ tokens: [TextToken], kind: String, availableDegrees: Set<Int>) -> [PerformanceConstraint] {
            tokens.compactMap { token in
                let degree = token.lexeme == "root" ? 1 : token.integerValue
                guard let degree, availableDegrees.contains(degree) else {
                    error("Chord \(kind) expects a tone present in the chord", at: token.range)
                    return nil
                }
                return kind == "omit" ? .chordOmit(degree) : .chordDouble(degree)
            }
        }

        mutating func chordToneConstraints(_ additions: [TextChordToneSyntax], alterations: [TextChordToneSyntax], quality: ChordQuality) -> [PerformanceConstraint] {
            var result: [PerformanceConstraint] = []
            var available = Set(quality.degrees)
            for addition in additions {
                guard let degree = addition.degree.integerValue, (2...13).contains(degree) else {
                    error("Chord add expects a degree in 2...13", at: addition.degree.range)
                    continue
                }
                available.insert(degree)
                result.append(.chordAdd(degree: degree, alteration: addition.alteration))
            }
            for alteration in alterations {
                guard let degree = alteration.degree.integerValue, available.contains(degree), alteration.alteration != 0 else {
                    error("Chord alter expects an existing chord degree followed by # or b", at: alteration.degree.range)
                    continue
                }
                result.append(.chordAlter(degree: degree, semitones: alteration.alteration))
            }
            return result
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
