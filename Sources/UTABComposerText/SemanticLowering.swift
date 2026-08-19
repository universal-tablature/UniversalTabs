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
    public let displayName: String?
    public let range: SourceRange
}

public struct TextSemanticLowerer: Sendable {
    public init() {}

    public func lower(_ syntax: TextCompositionSyntax) -> TextSemanticResult {
        var worker = Worker(syntax: syntax)
        return worker.lower()
    }

    private struct Worker {
        let syntax: TextCompositionSyntax
        var diagnostics: [TextDiagnostic] = []

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
                    model: $0.model.stringValue ?? String($0.model.lexeme),
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
            case .relativeNote(let degree, let octave, let durationToken):
                return .init(
                    id: id("relative-note", expression.range),
                    kind: .note(.scaleDegree(degree.integerValue ?? 0, octave: octave.integerValue ?? 0), duration: duration(durationToken), constraints: []),
                    annotations: .init(source: expression.range)
                )
            case .chord(let root, let quality, let durationToken):
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
                    kind: .chord(.init(spelling, chordQuality), duration: duration(durationToken), constraints: []),
                    annotations: .init(source: expression.range)
                )
            case .rest(let token):
                return .init(id: id("rest", expression.range), kind: .rest(duration(token)), annotations: .init(source: expression.range))
            case .reference(let token):
                return .reference(.named("phrase", String(token.lexeme)), id: id("phrase-reference", expression.range))
            case .repeated(let count, let expressions):
                return .repeated(count: count.integerValue ?? 0, expressionSequence(expressions, range: expression.range), id: id("repeat", expression.range))
            case .bar(let expressions):
                return expressionSequence(expressions, range: expression.range)
            case .parallel(let expressions):
                return .parallel(expressions.map { lowerExpression($0) }, id: id("parallel", expression.range))
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
            let kind: ScaleKind?
            switch mode.lexeme { case "major": kind = .major; case "minor": kind = .naturalMinor; default: kind = nil }
            guard let kind else { error("Unsupported scale mode '\(mode.lexeme)'", at: mode.range); return nil }
            return .init(spelling, kind)
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
