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
        var worker = Worker(syntax: syntax, scaleKinds: definitions.kinds, bindings: bindings(in: [syntax]), diagnostics: definitions.diagnostics)
        return worker.lower()
    }

    public func lower(_ modules: [TextLoadedModule]) -> TextSemanticResult {
        guard let root = modules.last(where: \.isRoot) else {
            return .init(composition: nil, instruments: [], diagnostics: [])
        }
        let definitions = scaleKinds(in: modules.map(\.syntax))
        var worker = Worker(syntax: root.syntax, scaleKinds: definitions.kinds, bindings: bindings(in: modules.map(\.syntax)), diagnostics: definitions.diagnostics)
        return worker.lower()
    }

    private func bindings(in syntaxes: [TextCompositionSyntax]) -> [String: TextConstantSyntax.Value] {
        var result: [String: TextConstantSyntax.Value] = [:]
        for constant in syntaxes.flatMap(\.constants) {
            result[String(constant.name.lexeme)] = constant.value
        }
        return result
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
        let scaleKinds: [String: ScaleKind]
        let bindings: [String: TextConstantSyntax.Value]
        var diagnostics: [TextDiagnostic]

        mutating func lower() -> TextSemanticResult {
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
            let phrases = syntax.phrases.map { lowerPhrase($0) }
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
                return .init(String(phrase.name.lexeme), id: .named("phrase", String(phrase.name.lexeme)), bars: bars, source: phrase.range)
            }
            return .init(
                String(phrase.name.lexeme),
                id: .named("phrase", String(phrase.name.lexeme)),
                expression: expressionSequence(phrase.expressions, range: phrase.range),
                source: phrase.range
            )
        }

        mutating func lowerSection(_ section: TextSectionSyntax, meter: TimeSignature) -> Section {
            let duration = section.barCount?.integerValue.map { meter.duration * $0 }
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
            return .init(
                String(voice.name.lexeme),
                id: id("voice", voice.range),
                content: voice.expressions.map { lowerVoiceContent($0) },
                lyrics: lyrics,
                source: voice.range
            )
        }

        mutating func lowerVoiceContent(_ expression: TextExpressionSyntax) -> VoiceContent {
            if case .reference(let token) = expression.kind { return .phrase(String(token.lexeme)) }
            return .expression(lowerExpression(expression))
        }

        mutating func expressionSequence(_ expressions: [TextExpressionSyntax], range: SourceRange) -> MusicalExpression {
            .sequence(expressions.map { lowerExpression($0) }, id: id("sequence", range))
        }

        mutating func lowerExpression(_ expression: TextExpressionSyntax) -> MusicalExpression {
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
            case .relativeNote(let degree, let alteration, let octave, let durationToken):
                return .init(
                    id: id("relative-note", expression.range),
                    kind: .note(.scaleDegree(degree.integerValue ?? 0, octave: octave.integerValue ?? 0, alteration: alteration), duration: duration(durationToken), constraints: []),
                    annotations: .init(source: expression.range)
                )
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
            case .symbol(let name, let useAlteration, let octave, let durationToken):
                let resolved = symbolicBinding(String(name.lexeme), useAlteration: useAlteration)
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
            case .rest(let token):
                return .init(id: id("rest", expression.range), kind: .rest(duration(token)), annotations: .init(source: expression.range))
            case .reference(let token):
                return .reference(.named("phrase", String(token.lexeme)), id: id("phrase-reference", expression.range))
            case .repeated(let count, let expressions):
                return .repeated(count: count.integerValue ?? 0, expressionSequence(expressions, range: expression.range), id: id("repeat", expression.range))
            case .bar(let expressions), .sequence(let expressions):
                return expressionSequence(expressions, range: expression.range)
            case .parallel(let expressions):
                return .parallel(expressions.map { lowerExpression($0) }, id: id("parallel", expression.range))
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
                return .technique(.init(
                    "__performancePattern",
                    form: .scoped,
                    operands: [.sequence(operands, id: id("performed-chords", expression.range))],
                    parameters: [
                        "name": .string(patternName),
                        "subdivision": .string(String(pattern.subdivision.lexeme)),
                        "steps": .list(pattern.steps.map(performanceStep)),
                    ]
                ), id: id("performance", expression.range))
            }
        }

        func symbolicBinding(_ rawName: String, useAlteration: Int) -> (binding: TextConstantSyntax.Value?, alteration: Int) {
            if let binding = bindings[rawName] { return (binding, useAlteration) }
            var name = rawName
            var alteration = useAlteration
            while let suffix = name.last, suffix == "#" || suffix == "b" {
                alteration += suffix == "#" ? 1 : -1
                name.removeLast()
            }
            return (bindings[name], alteration)
        }

        func performanceStep(_ step: TextPerformanceStepSyntax) -> MetadataValue {
            switch step.kind {
            case .interaction(let words):
                return .object(["words": .list(words.map { .string(String($0.lexeme)) })])
            case .parallel(let children):
                return .object(["parallel": .list(children.map(performanceStep))])
            }
        }

        mutating func duration(_ token: TextToken) -> MusicalDuration {
            switch token.lexeme {
            case "w": return .whole
            case "h": return .half
            case "q": return .quarter
            case "e": return .eighth
            case "s": return MusicalDuration(1, 16)
            default:
                error("Unknown duration '\(token.lexeme)'", at: token.range)
                return .zero
            }
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
            guard let spelling = parsePitchClass(String(tonic.lexeme)) else {
                error("Invalid scale tonic '\(tonic.lexeme)'", at: tonic.range); return nil
            }
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
