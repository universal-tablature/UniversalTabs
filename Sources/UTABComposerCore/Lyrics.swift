public enum LyricSyllablePosition: String, Sendable, Hashable {
    case single
    case beginning
    case middle
    case end
}

public struct LyricSyllable: Sendable, Hashable {
    public let id: SemanticID
    public let text: String
    public let position: LyricSyllablePosition
    public let annotations: SemanticAnnotations

    public init(
        _ text: String,
        position: LyricSyllablePosition,
        id: SemanticID,
        metadata: [String: MetadataValue] = [:]
    ) {
        self.id = id
        self.text = text
        self.position = position
        self.annotations = .init(metadata: metadata)
    }
}

public struct LyricWord: Sendable, Hashable {
    public let id: SemanticID
    public let syllables: [LyricSyllable]
    public let annotations: SemanticAnnotations

    public init(id: SemanticID, syllables: [LyricSyllable], metadata: [String: MetadataValue] = [:]) {
        self.id = id
        self.syllables = syllables
        self.annotations = .init(metadata: metadata)
    }

    public var text: String { syllables.map(\.text).joined() }
}

public struct LyricVerse: Sendable, Hashable {
    public let id: SemanticID
    public let number: Int
    public let language: String?
    public let words: [LyricWord]
    public let annotations: SemanticAnnotations

    public init(
        id: SemanticID,
        number: Int = 1,
        language: String? = nil,
        words: [LyricWord],
        metadata: [String: MetadataValue] = [:]
    ) {
        self.id = id
        self.number = number
        self.language = language
        self.words = words
        self.annotations = .init(metadata: metadata)
    }

    /// Creates the initial compact lyric form. Spaces delimit words and ASCII
    /// hyphens delimit explicitly authored syllables.
    public init(
        _ text: String,
        id: SemanticID,
        number: Int = 1,
        language: String? = nil,
        metadata: [String: MetadataValue] = [:]
    ) {
        let tokens = text.split(whereSeparator: \ .isWhitespace).map(String.init)
        self.init(
            id: id,
            number: number,
            language: language,
            words: tokens.enumerated().map { wordIndex, token in
                let components = token.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
                let wordID = SemanticID.derived(kind: "lyric-word:\(wordIndex)", components: [id])
                return LyricWord(
                    id: wordID,
                    syllables: components.enumerated().map { syllableIndex, syllable in
                        LyricSyllable(
                            syllable,
                            position: Self.position(at: syllableIndex, count: components.count),
                            id: .derived(kind: "lyric-syllable:\(syllableIndex)", components: [wordID])
                        )
                    }
                )
            },
            metadata: metadata
        )
    }

    public var syllables: [LyricSyllable] { words.flatMap(\.syllables) }

    private static func position(at index: Int, count: Int) -> LyricSyllablePosition {
        if count == 1 { return .single }
        if index == 0 { return .beginning }
        if index == count - 1 { return .end }
        return .middle
    }
}

public struct AlignedLyricSyllable: Sendable, Hashable {
    public let verseID: SemanticID
    public let wordID: SemanticID
    public let syllable: LyricSyllable
    public let attackOccurrenceID: SemanticID
    public let offset: MusicalDuration
    public let duration: MusicalDuration
}

public struct AlignedLyricVerse: Sendable, Hashable {
    public let source: LyricVerse
    public let syllables: [AlignedLyricSyllable]
}

public struct LyricAlignmentStage: CompilerStage {
    public init() {}

    public func run(_ input: TemporalComposition) -> CompilerStageResult<TemporalComposition> {
        var diagnostics: [ComposerDiagnostic] = []
        let sections = input.sections.enumerated().map { sectionIndex, section in
            TimedSection(
                source: section.source,
                duration: section.duration,
                harmony: section.harmony,
                parts: section.parts.enumerated().map { partIndex, part in
                    TimedPart(
                        source: part.source,
                        voices: part.voices.enumerated().map { voiceIndex, voice in
                            let path = "sections[\(sectionIndex)].parts[\(partIndex)].voices[\(voiceIndex)].lyrics"
                            return TimedVoice(
                                source: voice.source,
                                expression: voice.expression,
                                lyrics: align(voice.source.lyrics, to: attacks(in: voice.expression), path: path, diagnostics: &diagnostics)
                            )
                        }
                    )
                }
            )
        }
        guard !diagnostics.contains(where: { $0.severity == .error }) else {
            return .init(output: nil, diagnostics: diagnostics)
        }
        return .init(output: .init(source: input.source, sections: sections, main: input.main), diagnostics: diagnostics)
    }

    private func align(
        _ verses: [LyricVerse],
        to attacks: [TimedExpression],
        path: String,
        diagnostics: inout [ComposerDiagnostic]
    ) -> [AlignedLyricVerse] {
        verses.enumerated().map { verseIndex, verse in
            let syllables = verse.words.flatMap { word in word.syllables.map { (word.id, $0) } }
            if syllables.count != attacks.count {
                diagnostics.append(.init(
                    .error,
                    path: "\(path)[\(verseIndex)]",
                    message: "Lyrics contain \(syllables.count) syllables but voice contains \(attacks.count) lyric attacks"
                ))
            }
            return .init(source: verse, syllables: zip(syllables, attacks).map { item, attack in
                .init(
                    verseID: verse.id,
                    wordID: item.0,
                    syllable: item.1,
                    attackOccurrenceID: attack.provenance.occurrenceID,
                    offset: attack.offset,
                    duration: attack.duration
                )
            })
        }
    }

    private func attacks(in expression: TimedExpression) -> [TimedExpression] {
        switch expression.kind {
        case .note, .actuator:
            return [expression]
        case .sequence(let children), .parallel(let children):
            return children.flatMap(attacks).sorted {
                if $0.offset != $1.offset { return $0.offset < $1.offset }
                return $0.provenance.occurrenceID.rawValue < $1.provenance.occurrenceID.rawValue
            }
        case .technique(let application):
            return application.operands.flatMap(attacks)
        case .rest, .chord:
            return []
        }
    }
}
