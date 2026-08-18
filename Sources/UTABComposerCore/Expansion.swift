public struct ExpressionProvenance: Sendable, Hashable {
    public let occurrenceID: SemanticID
    public let originID: SemanticID
    public let ancestry: [SemanticID]
    public let expansionPath: [String]

    public init(originID: SemanticID, ancestry: [SemanticID], expansionPath: [String]) {
        self.originID = originID
        self.ancestry = ancestry
        self.expansionPath = expansionPath
        self.occurrenceID = .derived(
            kind: "occurrence:\(expansionPath.joined(separator: "/"))",
            components: ancestry + [originID]
        )
    }
}

public struct ExpandedTechniqueApplication: Sendable, Hashable {
    public let technique: String
    public let form: TechniqueForm
    public let operands: [ExpandedExpression]
    public let parameters: [String: MetadataValue]
}

/// A reference-free, repetition-free expression tree. Construction is internal to
/// compiler passes so later stages never need to handle unresolved semantic cases.
public struct ExpandedExpression: Sendable, Hashable {
    public indirect enum Kind: Sendable, Hashable {
        case note(MusicalPitch, duration: MusicalDuration, constraints: [PerformanceConstraint])
        case rest(MusicalDuration)
        case chord(ChordSymbol, duration: MusicalDuration, constraints: [PerformanceConstraint])
        case actuator(ActuatorExpression)
        case sequence([ExpandedExpression])
        case parallel([ExpandedExpression])
        case technique(ExpandedTechniqueApplication)
    }

    public let provenance: ExpressionProvenance
    public let kind: Kind
    public let annotations: SemanticAnnotations

    init(provenance: ExpressionProvenance, kind: Kind, annotations: SemanticAnnotations) {
        self.provenance = provenance
        self.kind = kind
        self.annotations = annotations
    }

    public var duration: MusicalDuration {
        switch kind {
        case .note(_, let duration, _), .rest(let duration), .chord(_, let duration, _):
            return duration
        case .actuator(let actuator):
            return actuator.duration
        case .sequence(let children):
            return children.reduce(.zero) { $0 + $1.duration }
        case .parallel(let children):
            return children.map(\.duration).max() ?? .zero
        case .technique(let application):
            switch application.form {
            case .unary, .scoped:
                return application.operands.first?.duration ?? .zero
            case .transition:
                return application.operands.reduce(.zero) { $0 + $1.duration }
            }
        }
    }
}

public struct ExpandedVoice: Sendable, Hashable {
    public let source: Voice
    public let expression: ExpandedExpression
}

public struct ExpandedPart: Sendable, Hashable {
    public let source: Part
    public let voices: [ExpandedVoice]
}

public struct ExpandedSection: Sendable, Hashable {
    public let source: Section
    public let parts: [ExpandedPart]
}

public struct SectionOccurrence: Sendable, Hashable {
    public let occurrenceID: SemanticID
    public let sectionID: SemanticID
    public let expansionPath: [String]

    public init(sectionID: SemanticID, expansionPath: [String]) {
        self.sectionID = sectionID
        self.expansionPath = expansionPath
        self.occurrenceID = .derived(kind: "section-occurrence:\(expansionPath.joined(separator: "/"))", components: [sectionID])
    }
}

public struct ExpandedArrangement: Sendable, Hashable {
    public indirect enum Kind: Sendable, Hashable {
        case section(SectionOccurrence)
        case sequence([ExpandedArrangement])
        case parallel([ExpandedArrangement])
    }

    public let kind: Kind
}

public struct ExpandedComposition: Sendable {
    public let source: NameResolvedComposition
    public let sections: [ExpandedSection]
    public let main: ExpandedArrangement?
}

public struct ReferenceExpansionStage: CompilerStage {
    public init() {}

    public func run(_ input: NameResolvedComposition) -> CompilerStageResult<ExpandedComposition> {
        var expander = Expander(input: input)
        return expander.expand()
    }

    private struct Expander {
        let input: NameResolvedComposition
        var diagnostics: [ComposerDiagnostic] = []

        var phrasesByID: [SemanticID: Phrase] {
            Dictionary(uniqueKeysWithValues: input.source.phrases.map { ($0.id, $0) })
        }

        mutating func expand() -> CompilerStageResult<ExpandedComposition> {
            validateRepetitionCounts()
            guard !diagnostics.contains(where: { $0.severity == .error }) else {
                return .init(output: nil, diagnostics: diagnostics)
            }
            let sections = input.sections.enumerated().map { sectionIndex, section in
                expandSection(section, sectionIndex: sectionIndex)
            }
            let main = input.source.main.flatMap { expandArrangement($0, path: ["main"]) }

            guard !diagnostics.contains(where: { $0.severity == .error }) else {
                return .init(output: nil, diagnostics: diagnostics)
            }
            return .init(output: .init(source: input, sections: sections, main: main), diagnostics: diagnostics)
        }

        mutating func validateRepetitionCounts() {
            for (index, phrase) in input.source.phrases.enumerated() {
                validateRepetitionCounts(in: phrase.expression, path: "phrases[\(index)].expression")
            }
            for (sectionIndex, section) in input.source.sections.enumerated() {
                for (partIndex, part) in section.parts.enumerated() {
                    for (voiceIndex, voice) in part.voices.enumerated() {
                        for (contentIndex, content) in voice.content.enumerated() {
                            guard case .expression(let expression) = content else { continue }
                            validateRepetitionCounts(
                                in: expression,
                                path: "sections[\(sectionIndex)].parts[\(partIndex)].voices[\(voiceIndex)].content[\(contentIndex)]"
                            )
                        }
                    }
                }
            }
            if let main = input.source.main {
                validateRepetitionCounts(in: main, path: "main")
            }
        }

        mutating func validateRepetitionCounts(in expression: MusicalExpression, path: String) {
            switch expression.kind {
            case .repeated(let count, let child):
                if count < 0 {
                    diagnostics.append(.init(.error, path: path, message: "Repetition count must not be negative"))
                }
                validateRepetitionCounts(in: child, path: "\(path).repeated")
            case .sequence(let children), .parallel(let children):
                for (index, child) in children.enumerated() {
                    validateRepetitionCounts(in: child, path: "\(path)[\(index)]")
                }
            case .technique(let application):
                for (index, operand) in application.operands.enumerated() {
                    validateRepetitionCounts(in: operand, path: "\(path).technique.operands[\(index)]")
                }
            case .note, .rest, .chord, .actuator, .reference:
                break
            }
        }

        mutating func expandSection(_ section: NameResolvedSection, sectionIndex: Int) -> ExpandedSection {
            let parts = section.parts.enumerated().map { partIndex, part in
                let voices = part.voices.enumerated().map { voiceIndex, voice in
                    let voicePath = [
                        "section:\(section.source.id.rawValue)",
                        "part:\(partIndex):\(part.source.id.rawValue)",
                        "voice:\(voiceIndex):\(voice.source.id.rawValue)",
                    ]
                    let expressions = voice.content.enumerated().compactMap { contentIndex, content in
                        let path = voicePath + ["content:\(contentIndex)"]
                        switch content {
                        case .expression(let expression):
                            return expandExpression(expression, path: path, ancestry: [])
                        case .reference(let reference):
                            return expandPhrase(reference.declaration.id, path: path, ancestry: [])
                        }
                    }
                    let origin = voice.source.id
                    let sequence = ExpandedExpression(
                        provenance: .init(originID: origin, ancestry: [], expansionPath: voicePath),
                        kind: .sequence(expressions),
                        annotations: voice.source.annotations
                    )
                    return ExpandedVoice(source: voice.source, expression: sequence)
                }
                return ExpandedPart(source: part.source, voices: voices)
            }
            return ExpandedSection(source: section.source, parts: parts)
        }

        mutating func expandPhrase(
            _ phraseID: SemanticID,
            path: [String],
            ancestry: [SemanticID]
        ) -> ExpandedExpression? {
            guard let phrase = phrasesByID[phraseID] else {
                diagnostics.append(.init(.error, path: path.joined(separator: "."), message: "Resolved phrase '\(phraseID)' is unavailable during expansion"))
                return nil
            }
            if !phrase.bars.isEmpty {
                let phrasePath = path + ["phrase:\(phraseID.rawValue)"]
                let children = phrase.bars.enumerated().compactMap { index, bar in
                    expandExpression(
                        bar.expression,
                        path: phrasePath + ["bar:\(index):\(bar.id.rawValue)"],
                        ancestry: ancestry + [phraseID, bar.id]
                    )
                }
                return ExpandedExpression(
                    provenance: .init(
                        originID: phrase.expression.id,
                        ancestry: ancestry + [phraseID],
                        expansionPath: phrasePath
                    ),
                    kind: .sequence(children),
                    annotations: phrase.annotations
                )
            }
            return expandExpression(
                phrase.expression,
                path: path + ["phrase:\(phraseID.rawValue)"],
                ancestry: ancestry + [phraseID]
            )
        }

        mutating func expandExpression(
            _ expression: MusicalExpression,
            path: [String],
            ancestry: [SemanticID]
        ) -> ExpandedExpression? {
            let provenance = ExpressionProvenance(originID: expression.id, ancestry: ancestry, expansionPath: path)
            let expandedKind: ExpandedExpression.Kind

            switch expression.kind {
            case .note(let pitch, let duration, let constraints):
                expandedKind = .note(pitch, duration: duration, constraints: constraints)
            case .rest(let duration):
                expandedKind = .rest(duration)
            case .chord(let chord, let duration, let constraints):
                expandedKind = .chord(chord, duration: duration, constraints: constraints)
            case .actuator(let actuator):
                expandedKind = .actuator(actuator)
            case .sequence(let children):
                expandedKind = .sequence(children.enumerated().compactMap { index, child in
                    expandExpression(child, path: path + ["sequence:\(index)"], ancestry: ancestry)
                })
            case .parallel(let children):
                expandedKind = .parallel(children.enumerated().compactMap { index, child in
                    expandExpression(child, path: path + ["parallel:\(index)"], ancestry: ancestry)
                })
            case .reference:
                guard let reference = input.expressionReferences[expression.id] else {
                    diagnostics.append(.init(.error, path: path.joined(separator: "."), message: "Expression reference '\(expression.id)' has no name-resolution binding"))
                    return nil
                }
                return expandPhrase(
                    reference.declaration.id,
                    path: path + ["reference:\(expression.id.rawValue)"],
                    ancestry: ancestry + [expression.id]
                )
            case .repeated(let count, let child):
                guard count >= 0 else {
                    diagnostics.append(.init(.error, path: path.joined(separator: "."), message: "Repetition count must not be negative"))
                    return nil
                }
                let repetitions = (0..<count).compactMap { index in
                    expandExpression(
                        child,
                        path: path + ["repeat:\(expression.id.rawValue):\(index)"],
                        ancestry: ancestry + [expression.id]
                    )
                }
                expandedKind = .sequence(repetitions)
            case .technique(let application):
                let operands = application.operands.enumerated().compactMap { index, operand in
                    expandExpression(
                        operand,
                        path: path + ["technique:\(expression.id.rawValue):\(index)"],
                        ancestry: ancestry + [expression.id]
                    )
                }
                expandedKind = .technique(.init(
                    technique: application.technique,
                    form: application.form,
                    operands: operands,
                    parameters: application.parameters
                ))
            }
            return .init(provenance: provenance, kind: expandedKind, annotations: expression.annotations)
        }

        mutating func expandArrangement(_ expression: MusicalExpression, path: [String]) -> ExpandedArrangement? {
            switch expression.kind {
            case .reference:
                guard let reference = input.expressionReferences[expression.id], reference.declaration.kind == .section else {
                    diagnostics.append(.init(.error, path: path.joined(separator: "."), message: "Arrangement reference '\(expression.id)' does not resolve to a section"))
                    return nil
                }
                return .init(kind: .section(.init(
                    sectionID: reference.declaration.id,
                    expansionPath: path + ["reference:\(expression.id.rawValue)"]
                )))
            case .sequence(let children):
                return .init(kind: .sequence(children.enumerated().compactMap { index, child in
                    expandArrangement(child, path: path + ["sequence:\(index)"])
                }))
            case .parallel(let children):
                return .init(kind: .parallel(children.enumerated().compactMap { index, child in
                    expandArrangement(child, path: path + ["parallel:\(index)"])
                }))
            case .repeated(let count, let child):
                guard count >= 0 else {
                    diagnostics.append(.init(.error, path: path.joined(separator: "."), message: "Arrangement repetition count must not be negative"))
                    return nil
                }
                return .init(kind: .sequence((0..<count).compactMap { index in
                    expandArrangement(child, path: path + ["repeat:\(expression.id.rawValue):\(index)"])
                }))
            case .note, .rest, .chord, .actuator, .technique:
                diagnostics.append(.init(.error, path: path.joined(separator: "."), message: "The main arrangement may contain only section references, sequence, parallel composition, and repetition"))
                return nil
            }
        }
    }
}
