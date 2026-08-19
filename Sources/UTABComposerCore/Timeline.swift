public struct TimedTechniqueApplication: Sendable, Hashable {
    public let technique: String
    public let form: TechniqueForm
    public let operands: [TimedExpression]
    public let parameters: [String: MetadataValue]
}

public struct TimedExpression: Sendable, Hashable {
    public indirect enum Kind: Sendable, Hashable {
        case note(MusicalPitch, constraints: [PerformanceConstraint])
        case rest
        case chord(ChordSymbol, constraints: [PerformanceConstraint])
        case actuator(ActuatorExpression)
        case sequence([TimedExpression])
        case parallel([TimedExpression])
        case technique(TimedTechniqueApplication)
    }

    public let provenance: ExpressionProvenance
    public let offset: MusicalDuration
    public let duration: MusicalDuration
    public let kind: Kind
    public let annotations: SemanticAnnotations
}

public struct TimedVoice: Sendable, Hashable {
    public let source: Voice
    public let expression: TimedExpression
}

public struct TimedPart: Sendable, Hashable {
    public let source: Part
    public let voices: [TimedVoice]
}

public struct TimedSection: Sendable, Hashable {
    public let source: Section
    public let duration: MusicalDuration
    public let parts: [TimedPart]
}

public struct TemporalComposition: Sendable {
    public let source: ExpandedComposition
    public let sections: [TimedSection]
    public let main: ExpandedArrangement?
}

public struct TemporalResolutionStage: CompilerStage {
    public init() {}

    public func run(_ input: ExpandedComposition) -> CompilerStageResult<TemporalComposition> {
        var diagnostics: [ComposerDiagnostic] = []
        let sections = input.sections.enumerated().map { sectionIndex, section in
            let parts = section.parts.enumerated().map { partIndex, part in
                let voices = part.voices.enumerated().map { voiceIndex, voice in
                    let expression = schedule(voice.expression, at: .zero, diagnostics: &diagnostics)
                    if let expected = section.source.expectedDuration, expression.duration != expected {
                        diagnostics.append(.init(
                            .error,
                            path: "sections[\(sectionIndex)].parts[\(partIndex)].voices[\(voiceIndex)]",
                            message: "Voice duration is \(expression.duration); expected section duration \(expected)"
                        ))
                    }
                    return TimedVoice(source: voice.source, expression: expression)
                }
                return TimedPart(source: part.source, voices: voices)
            }
            let inferred = parts.flatMap(\.voices).map(\.expression.duration).max() ?? .zero
            return TimedSection(
                source: section.source,
                duration: section.source.expectedDuration ?? inferred,
                parts: parts
            )
        }

        guard !diagnostics.contains(where: { $0.severity == .error }) else {
            return .init(output: nil, diagnostics: diagnostics)
        }
        return .init(output: .init(source: input, sections: sections, main: input.main), diagnostics: diagnostics)
    }

    private func schedule(
        _ expression: ExpandedExpression,
        at offset: MusicalDuration,
        diagnostics: inout [ComposerDiagnostic]
    ) -> TimedExpression {
        let kind: TimedExpression.Kind
        switch expression.kind {
        case .note(let pitch, _, let constraints):
            kind = .note(pitch, constraints: constraints)
        case .rest:
            kind = .rest
        case .chord(let chord, _, let constraints):
            kind = .chord(chord, constraints: constraints)
        case .actuator(let actuator):
            kind = .actuator(actuator)
        case .sequence(let children):
            var cursor = offset
            let timed = children.map { child in
                let result = schedule(child, at: cursor, diagnostics: &diagnostics)
                cursor = cursor + child.duration
                return result
            }
            kind = .sequence(timed)
        case .parallel(let children):
            kind = .parallel(children.map { schedule($0, at: offset, diagnostics: &diagnostics) })
        case .technique(let application):
            let operands: [TimedExpression]
            switch application.form {
            case .unary, .scoped:
                if application.operands.count != 1 {
                    diagnostics.append(.init(
                        .error,
                        path: expression.provenance.expansionPath.joined(separator: "."),
                        message: "\(application.form.rawValue) technique '\(application.technique)' requires exactly one operand"
                    ))
                }
                operands = application.operands.map { schedule($0, at: offset, diagnostics: &diagnostics) }
            case .transition:
                if application.operands.count != 2 {
                    diagnostics.append(.init(
                        .error,
                        path: expression.provenance.expansionPath.joined(separator: "."),
                        message: "Transition technique '\(application.technique)' requires exactly two operands"
                    ))
                }
                var cursor = offset
                operands = application.operands.map { operand in
                    let result = schedule(operand, at: cursor, diagnostics: &diagnostics)
                    cursor = cursor + operand.duration
                    return result
                }
            }
            kind = .technique(.init(
                technique: application.technique,
                form: application.form,
                operands: operands,
                parameters: application.parameters
            ))
        }
        return .init(
            provenance: expression.provenance,
            offset: offset,
            duration: expression.duration,
            kind: kind,
            annotations: expression.annotations
        )
    }
}

public struct ResolvedTimelinePitch: Sendable, Hashable {
    public let authored: MusicalPitch
    public let absolute: AbsolutePitch

    public init(authored: MusicalPitch, absolute: AbsolutePitch) {
        self.authored = authored
        self.absolute = absolute
    }
}

public struct ResolvedTimelineChord: Sendable, Hashable {
    public let authored: ChordSymbol
    public let rootPitchClass: PitchClass

    public init(authored: ChordSymbol, rootPitchClass: PitchClass) {
        self.authored = authored
        self.rootPitchClass = rootPitchClass
    }
}

public struct PitchResolvedTechniqueApplication: Sendable, Hashable {
    public let technique: String
    public let form: TechniqueForm
    public let operands: [PitchResolvedExpression]
    public let parameters: [String: MetadataValue]
}

public struct PitchResolvedExpression: Sendable, Hashable {
    public indirect enum Kind: Sendable, Hashable {
        case note(ResolvedTimelinePitch, constraints: [PerformanceConstraint])
        case rest
        case chord(ResolvedTimelineChord, constraints: [PerformanceConstraint])
        case actuator(ActuatorExpression)
        case sequence([PitchResolvedExpression])
        case parallel([PitchResolvedExpression])
        case technique(PitchResolvedTechniqueApplication)
    }

    public let provenance: ExpressionProvenance
    public let offset: MusicalDuration
    public let duration: MusicalDuration
    public let kind: Kind
    public let annotations: SemanticAnnotations
}

public struct PitchResolvedVoice: Sendable, Hashable {
    public let source: Voice
    public let expression: PitchResolvedExpression
}

public struct PitchResolvedPart: Sendable, Hashable {
    public let source: Part
    public let voices: [PitchResolvedVoice]
}

public struct PitchResolvedSection: Sendable, Hashable {
    public let source: Section
    public let duration: MusicalDuration
    public let parts: [PitchResolvedPart]
}

public struct PitchResolvedComposition: Sendable {
    public let source: TemporalComposition
    public let sections: [PitchResolvedSection]
    public let main: ExpandedArrangement?
}

public struct PitchResolutionStage: CompilerStage {
    public init() {}

    public func run(_ input: TemporalComposition) -> CompilerStageResult<PitchResolvedComposition> {
        var diagnostics: [ComposerDiagnostic] = []
        let scale = input.source.source.source.scale
        let sections = input.sections.map { section in
            PitchResolvedSection(
                source: section.source,
                duration: section.duration,
                parts: section.parts.map { part in
                    PitchResolvedPart(
                        source: part.source,
                        voices: part.voices.map { voice in
                            PitchResolvedVoice(
                                source: voice.source,
                                expression: resolve(voice.expression, scale: scale, diagnostics: &diagnostics)
                            )
                        }
                    )
                }
            )
        }
        guard !diagnostics.contains(where: { $0.severity == .error }) else {
            return .init(output: nil, diagnostics: diagnostics)
        }
        return .init(output: .init(source: input, sections: sections, main: input.main), diagnostics: diagnostics)
    }

    private func resolve(
        _ expression: TimedExpression,
        scale: Scale?,
        diagnostics: inout [ComposerDiagnostic]
    ) -> PitchResolvedExpression {
        let kind: PitchResolvedExpression.Kind
        switch expression.kind {
        case .note(let pitch, let constraints):
            let absolute: AbsolutePitch?
            switch pitch {
            case .absolute(let value):
                absolute = value
            case .scaleDegree(let degree, let octave):
                absolute = scale?.resolve(degree: degree, octave: octave)
            }
            if absolute == nil {
                diagnostics.append(.init(
                    .error,
                    path: expression.provenance.expansionPath.joined(separator: "."),
                    message: "Scale-relative pitch cannot be resolved without a valid active scale"
                ))
            }
            kind = .note(.init(authored: pitch, absolute: absolute ?? .init(.c, octave: 0)), constraints: constraints)
        case .rest:
            kind = .rest
        case .chord(let chord, let constraints):
            let root: PitchClass?
            switch chord.root {
            case .absolute(let spelling):
                root = spelling.pitchClass
            case .scaleDegree(let degree):
                root = scale?.resolve(degree: degree, octave: 0)?.pitchClass
            }
            if root == nil {
                diagnostics.append(.init(
                    .error,
                    path: expression.provenance.expansionPath.joined(separator: "."),
                    message: "Scale-relative chord cannot be resolved without a valid active scale"
                ))
            }
            kind = .chord(.init(authored: chord, rootPitchClass: root ?? .c), constraints: constraints)
        case .actuator(let actuator):
            kind = .actuator(actuator)
        case .sequence(let children):
            kind = .sequence(children.map { resolve($0, scale: scale, diagnostics: &diagnostics) })
        case .parallel(let children):
            kind = .parallel(children.map { resolve($0, scale: scale, diagnostics: &diagnostics) })
        case .technique(let application):
            kind = .technique(.init(
                technique: application.technique,
                form: application.form,
                operands: application.operands.map { resolve($0, scale: scale, diagnostics: &diagnostics) },
                parameters: application.parameters
            ))
        }
        return .init(
            provenance: expression.provenance,
            offset: expression.offset,
            duration: expression.duration,
            kind: kind,
            annotations: expression.annotations
        )
    }
}

public struct TimelineDebugRenderer: Sendable {
    public init() {}

    public func render(_ composition: PitchResolvedComposition) -> String {
        var lines = ["composition \(composition.source.source.source.source.title)"]
        for section in composition.sections {
            lines.append("section \(section.source.name) duration=\(section.duration)")
            for part in section.parts {
                lines.append("  part \(part.source.instrument)")
                for voice in part.voices {
                    lines.append("    voice \(voice.source.name) duration=\(voice.expression.duration)")
                    render(voice.expression, indent: "      ", into: &lines)
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    private func render(_ expression: PitchResolvedExpression, indent: String, into lines: inout [String]) {
        let timing = "at=\(expression.offset) duration=\(expression.duration) occurrence=\(expression.provenance.occurrenceID)"
        switch expression.kind {
        case .note(let pitch, let constraints):
            lines.append("\(indent)note \(format(pitch.authored)) -> \(format(pitch.absolute)) \(timing)\(format(constraints))")
        case .rest:
            lines.append("\(indent)rest \(timing)")
        case .chord(let chord, let constraints):
            lines.append("\(indent)chord root=\(chord.rootPitchClass.rawValue) quality=\(chord.authored.quality) \(timing)\(format(constraints))")
        case .actuator(let actuator):
            lines.append("\(indent)actuator \(actuator.action) group=\(actuator.target.group) \(timing)")
        case .sequence(let children):
            lines.append("\(indent)sequence \(timing)")
            children.forEach { render($0, indent: indent + "  ", into: &lines) }
        case .parallel(let children):
            lines.append("\(indent)parallel \(timing)")
            children.forEach { render($0, indent: indent + "  ", into: &lines) }
        case .technique(let application):
            lines.append("\(indent)technique \(application.technique) form=\(application.form.rawValue) \(timing)")
            application.operands.forEach { render($0, indent: indent + "  ", into: &lines) }
        }
    }

    private func format(_ pitch: MusicalPitch) -> String {
        switch pitch {
        case .absolute(let absolute): format(absolute)
        case .scaleDegree(let degree, let octave): "@\(degree)[\(octave)]"
        }
    }

    private func format(_ pitch: AbsolutePitch) -> String {
        let letter: String = switch pitch.spelling.letter {
        case .c: "C"
        case .d: "D"
        case .e: "E"
        case .f: "F"
        case .g: "G"
        case .a: "A"
        case .b: "B"
        }
        let accidental: String
        if pitch.spelling.accidental > 0 {
            accidental = String(repeating: "#", count: pitch.spelling.accidental)
        } else {
            accidental = String(repeating: "b", count: -pitch.spelling.accidental)
        }
        return "\(letter)\(accidental)\(pitch.octave)"
    }

    private func format(_ constraints: [PerformanceConstraint]) -> String {
        constraints.isEmpty ? "" : " constraints=\(constraints)"
    }
}
