public struct ComposerDiagnostic: Sendable, Hashable, CustomStringConvertible {
    public enum Severity: String, Sendable { case warning, error }
    public let severity: Severity
    public let path: String
    public let message: String

    public init(_ severity: Severity, path: String, message: String) {
        self.severity = severity; self.path = path; self.message = message
    }

    public var description: String { "\(severity.rawValue): \(path): \(message)" }
}

public struct CompositionValidator: Sendable {
    public init() {}

    public func validate(_ composition: Composition) -> [ComposerDiagnostic] {
        var diagnostics: [ComposerDiagnostic] = []
        if composition.tempo <= 0 {
            diagnostics.append(.init(.error, path: "tempo", message: "Tempo must be positive"))
        }

        var phrases: [String: Phrase] = [:]
        for (index, phrase) in composition.phrases.enumerated() {
            if phrases.updateValue(phrase, forKey: phrase.name) != nil {
                diagnostics.append(.init(.error, path: "phrases[\(index)].name", message: "Duplicate phrase '\(phrase.name)'"))
            }
            for (barIndex, bar) in phrase.bars.enumerated() {
                let expectedDuration = bar.meter?.duration ?? composition.meter.duration
                guard let actualDuration = bar.expression.duration else {
                    diagnostics.append(.init(
                        .error,
                        path: "phrases[\(index)].bars[\(barIndex)]",
                        message: "Bar duration cannot be determined before reference resolution"
                    ))
                    continue
                }
                guard actualDuration != expectedDuration else { continue }
                diagnostics.append(.init(
                    .error,
                    path: "phrases[\(index)].bars[\(barIndex)]",
                    message: "Bar duration is \(actualDuration); expected \(expectedDuration)"
                ))
            }
        }

        for (sectionIndex, section) in composition.sections.enumerated() {
            for (partIndex, part) in section.parts.enumerated() {
                for (voiceIndex, voice) in part.voices.enumerated() {
                    let path = "sections[\(sectionIndex)].parts[\(partIndex)].voices[\(voiceIndex)]"
                    validateLyrics(voice.lyrics, path: "\(path).lyrics", diagnostics: &diagnostics)
                    var duration: MusicalDuration? = .zero
                    for item in voice.content {
                        switch item {
                        case .expression(let expression):
                            guard let current = duration, let expressionDuration = expression.duration else {
                                duration = nil
                                continue
                            }
                            duration = current + expressionDuration
                        case .phrase(let name):
                            guard let phrase = phrases[name] else {
                                diagnostics.append(.init(.error, path: path, message: "Unknown phrase '\(name)'"))
                                continue
                            }
                            guard let current = duration, let phraseDuration = phrase.duration else {
                                duration = nil
                                continue
                            }
                            duration = current + phraseDuration
                        case .reference(let id):
                            guard let phrase = composition.phrases.first(where: { $0.id == id }) else {
                                diagnostics.append(.init(.error, path: path, message: "Unknown declaration '\(id)'"))
                                continue
                            }
                            guard let current = duration, let phraseDuration = phrase.duration else {
                                duration = nil
                                continue
                            }
                            duration = current + phraseDuration
                        }
                    }
                    guard let expectedDuration = section.expectedDuration else { continue }
                    guard let duration else {
                        diagnostics.append(.init(.error, path: path, message: "Voice duration cannot be determined before reference resolution"))
                        continue
                    }
                    if duration != expectedDuration {
                        diagnostics.append(.init(.error, path: path, message: "Voice duration is \(duration); expected section duration \(expectedDuration)"))
                    }
                }
            }
        }
        return diagnostics
    }

    private func validateLyrics(
        _ verses: [LyricVerse],
        path: String,
        diagnostics: inout [ComposerDiagnostic]
    ) {
        var ids = Set<SemanticID>()
        var verseNumbers = Set<Int>()
        for (verseIndex, verse) in verses.enumerated() {
            let versePath = "\(path)[\(verseIndex)]"
            if verse.number <= 0 {
                diagnostics.append(.init(.error, path: "\(versePath).number", message: "Lyric verse numbers must be positive"))
            }
            if !verseNumbers.insert(verse.number).inserted {
                diagnostics.append(.init(.error, path: "\(versePath).number", message: "Duplicate lyric verse number \(verse.number)"))
            }
            validateUnique(verse.id, path: "\(versePath).id", ids: &ids, diagnostics: &diagnostics)
            if verse.words.isEmpty {
                diagnostics.append(.init(.warning, path: versePath, message: "Lyric verse is empty"))
            }
            for (wordIndex, word) in verse.words.enumerated() {
                let wordPath = "\(versePath).words[\(wordIndex)]"
                validateUnique(word.id, path: "\(wordPath).id", ids: &ids, diagnostics: &diagnostics)
                if word.syllables.isEmpty {
                    diagnostics.append(.init(.error, path: wordPath, message: "Lyric word must contain at least one syllable"))
                }
                for (syllableIndex, syllable) in word.syllables.enumerated() {
                    let syllablePath = "\(wordPath).syllables[\(syllableIndex)]"
                    validateUnique(syllable.id, path: "\(syllablePath).id", ids: &ids, diagnostics: &diagnostics)
                    if syllable.text.isEmpty {
                        diagnostics.append(.init(.error, path: "\(syllablePath).text", message: "Lyric syllable text cannot be empty"))
                    }
                    let expected: LyricSyllablePosition
                    if word.syllables.count == 1 { expected = .single }
                    else if syllableIndex == 0 { expected = .beginning }
                    else if syllableIndex == word.syllables.count - 1 { expected = .end }
                    else { expected = .middle }
                    if syllable.position != expected {
                        diagnostics.append(.init(.error, path: "\(syllablePath).position", message: "Expected syllable position '\(expected.rawValue)'"))
                    }
                }
            }
        }
    }

    private func validateUnique(
        _ id: SemanticID,
        path: String,
        ids: inout Set<SemanticID>,
        diagnostics: inout [ComposerDiagnostic]
    ) {
        if !ids.insert(id).inserted {
            diagnostics.append(.init(.error, path: path, message: "Duplicate lyric semantic ID '\(id)'"))
        }
    }
}
