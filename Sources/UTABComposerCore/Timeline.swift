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
    public let lyrics: [AlignedLyricVerse]

    public init(source: Voice, expression: TimedExpression, lyrics: [AlignedLyricVerse] = []) {
        self.source = source
        self.expression = expression
        self.lyrics = lyrics
    }
}

public struct TimedPart: Sendable, Hashable {
    public let source: Part
    public let voices: [TimedVoice]
}

public struct TimedSection: Sendable, Hashable {
    public let source: Section
    public let duration: MusicalDuration
    public let harmony: TimedExpression?
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
            let harmony = section.harmony.map { schedule($0, at: .zero, diagnostics: &diagnostics) }
            if let expected = section.source.expectedDuration, let harmony, harmony.duration != expected {
                diagnostics.append(.init(
                    .error,
                    path: "sections[\(sectionIndex)].harmony",
                    message: "Harmony duration is \(harmony.duration); expected section duration \(expected)"
                ))
            }
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
            let inferred = ([harmony?.duration].compactMap { $0 } + parts.flatMap(\.voices).map(\.expression.duration)).max() ?? .zero
            return TimedSection(
                source: section.source,
                duration: section.source.expectedDuration ?? inferred,
                harmony: harmony,
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
    public let lyrics: [AlignedLyricVerse]

    public init(source: Voice, expression: PitchResolvedExpression, lyrics: [AlignedLyricVerse] = []) {
        self.source = source
        self.expression = expression
        self.lyrics = lyrics
    }
}

public struct PitchResolvedPart: Sendable, Hashable {
    public let source: Part
    public let voices: [PitchResolvedVoice]
}

public struct PitchResolvedSection: Sendable, Hashable {
    public let source: Section
    public let duration: MusicalDuration
    public let harmony: PitchResolvedExpression?
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
            let harmony = section.harmony.map { resolve($0, scale: scale, diagnostics: &diagnostics) }
            let parts = section.parts.map { part in
                PitchResolvedPart(
                    source: part.source,
                    voices: part.voices.map { voice in
                        let resolved = resolve(voice.expression, scale: scale, diagnostics: &diagnostics)
                        let tied = resolveTies(in: resolved, diagnostics: &diagnostics)
                        return PitchResolvedVoice(
                            source: voice.source,
                            expression: resolveRinging(in: tied, sectionDuration: section.duration),
                            lyrics: voice.lyrics
                        )
                    }
                )
            }
            if let harmony {
                diagnoseHarmonyConflicts(harmony: harmony, parts: parts, diagnostics: &diagnostics)
            }
            return PitchResolvedSection(
                source: section.source,
                duration: section.duration,
                harmony: harmony,
                parts: parts
            )
        }
        guard !diagnostics.contains(where: { $0.severity == .error }) else {
            return .init(output: nil, diagnostics: diagnostics)
        }
        return .init(output: .init(source: input, sections: sections, main: input.main), diagnostics: diagnostics)
    }

    private struct HarmonicSpan {
        let start: MusicalDuration
        let end: MusicalDuration
        let chord: ResolvedTimelineChord
        let path: String
    }

    private func diagnoseHarmonyConflicts(
        harmony: PitchResolvedExpression,
        parts: [PitchResolvedPart],
        diagnostics: inout [ComposerDiagnostic]
    ) {
        let spans = harmonicSpans(in: harmony)
        guard !spans.isEmpty else { return }
        let notes = parts.flatMap(\.voices).flatMap { noteAttacks(in: $0.expression) }
        for span in spans {
            let chordTones = Set(span.chord.authored.quality.intervals.map {
                (span.chord.rootPitchClass.rawValue + $0) % 12
            })
            let activeNotes = notes.filter { span.start <= $0.offset && $0.offset < span.end }
            guard !activeNotes.isEmpty else { continue }
            let matchingCount = activeNotes.reduce(into: 0) { count, note in
                guard case .note(let pitch, _) = note.kind else { return }
                if chordTones.contains(pitch.absolute.pitchClass.rawValue) { count += 1 }
            }
            let shouldWarn = activeNotes.count <= 2
                ? matchingCount == 0
                : matchingCount * 2 < activeNotes.count
            guard shouldWarn else { continue }
            diagnostics.append(.init(
                .warning,
                path: span.path,
                message: "Only \(matchingCount) of \(activeNotes.count) note attacks use tones from the active \(span.chord.authored.quality) chord; this may be intentional"
            ))
        }
    }

    private func harmonicSpans(in expression: PitchResolvedExpression) -> [HarmonicSpan] {
        switch expression.kind {
        case .chord(let chord, _):
            return [.init(
                start: expression.offset,
                end: expression.offset + expression.duration,
                chord: chord,
                path: expression.provenance.expansionPath.joined(separator: ".")
            )]
        case .sequence(let children), .parallel(let children):
            return children.flatMap(harmonicSpans)
        case .technique(let application):
            return application.operands.flatMap(harmonicSpans)
        case .note, .rest, .actuator:
            return []
        }
    }

    private func noteAttacks(in expression: PitchResolvedExpression) -> [PitchResolvedExpression] {
        switch expression.kind {
        case .note:
            return [expression]
        case .sequence(let children), .parallel(let children):
            return children.flatMap(noteAttacks)
        case .technique(let application):
            return application.operands.flatMap(noteAttacks)
        case .rest, .chord, .actuator:
            return []
        }
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
            case .scaleDegree(let degree, let octave, let alteration):
                absolute = scale?.resolve(degree: degree, octave: octave)?.transposed(cents: alteration * 100)
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
            case .scaleDegree(let degree, let alteration):
                root = scale?.resolve(degree: degree, octave: 0)?
                    .transposed(cents: alteration * 100).pitchClass
            }
            if root == nil {
                diagnostics.append(.init(
                    .error,
                    path: expression.provenance.expansionPath.joined(separator: "."),
                    message: "Scale-relative chord cannot be resolved without a valid active scale"
                ))
            }
            if let root, let bass = chord.bass {
                let intervals = chord.quality.intervals
                let matchingInversion = intervals.firstIndex {
                    (root.rawValue + $0) % 12 == bass.pitchClass.rawValue
                }
                if let inversion = chord.inversion, inversion != matchingInversion {
                    diagnostics.append(.init(
                        .error,
                        path: expression.provenance.expansionPath.joined(separator: "."),
                        message: "Explicit chord bass and inversion disagree"
                    ))
                }
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

    private struct TieLeaf {
        let expression: PitchResolvedExpression
        let isInParallel: Bool
    }

    private func resolveTies(
        in expression: PitchResolvedExpression,
        diagnostics: inout [ComposerDiagnostic]
    ) -> PitchResolvedExpression {
        var leaves: [TieLeaf] = []
        collectTieLeaves(expression, isInParallel: false, into: &leaves)
        var extendedDurations: [SemanticID: MusicalDuration] = [:]
        var continuations = Set<SemanticID>()
        var chains: [SemanticID: [SemanticID]] = [:]
        var index = 0

        while index < leaves.count {
            let first = leaves[index]
            guard hasTie(first.expression) else { index += 1; continue }
            guard case .note(let firstPitch, _) = first.expression.kind else {
                if case .chord = first.expression.kind {
                    // Chord voicing is selected by the bound instrument. Its
                    // individual tone ties are resolved after realization.
                    index += 1
                    continue
                }
                tieError("Only a note may start a tie", at: first.expression, diagnostics: &diagnostics)
                index += 1
                continue
            }
            var duration = first.expression.duration
            var segmentIDs = [first.expression.provenance.occurrenceID]
            var cursor = index
            var valid = true
            while hasTie(leaves[cursor].expression) {
                guard cursor + 1 < leaves.count else {
                    // The arrangement may place the next attack at the start of
                    // another section. The final lowering stage validates and
                    // resolves that occurrence-specific boundary.
                    break
                }
                let source = leaves[cursor]
                let destination = leaves[cursor + 1]
                guard !source.isInParallel, !destination.isInParallel else {
                    tieError("A tie is ambiguous inside parallel music", at: source.expression, diagnostics: &diagnostics)
                    valid = false
                    break
                }
                guard source.expression.offset + source.expression.duration == destination.expression.offset,
                      case .note(let pitch, _) = destination.expression.kind else {
                    tieError("A tie must connect adjacent notes in the same sequential voice", at: source.expression, diagnostics: &diagnostics)
                    valid = false
                    break
                }
                guard pitch.authored == firstPitch.authored, pitch.absolute == firstPitch.absolute else {
                    tieError("Tied notes must have the same authored and sounding pitch", at: source.expression, diagnostics: &diagnostics)
                    valid = false
                    break
                }
                duration = duration + destination.expression.duration
                continuations.insert(destination.expression.provenance.occurrenceID)
                segmentIDs.append(destination.expression.provenance.occurrenceID)
                cursor += 1
            }
            if valid {
                extendedDurations[first.expression.provenance.occurrenceID] = duration
                chains[first.expression.provenance.occurrenceID] = segmentIDs
            }
            index = max(index + 1, cursor + 1)
        }
        return rewriteTies(expression, extendedDurations: extendedDurations, continuations: continuations, chains: chains)
    }

    private func collectTieLeaves(_ expression: PitchResolvedExpression, isInParallel: Bool, into leaves: inout [TieLeaf]) {
        switch expression.kind {
        case .sequence(let children):
            children.forEach { collectTieLeaves($0, isInParallel: isInParallel, into: &leaves) }
        case .parallel(let children):
            children.forEach { collectTieLeaves($0, isInParallel: true, into: &leaves) }
        case .technique(let application):
            application.operands.forEach { collectTieLeaves($0, isInParallel: isInParallel, into: &leaves) }
        case .note, .rest, .chord, .actuator:
            leaves.append(.init(expression: expression, isInParallel: isInParallel))
        }
    }

    private func hasTie(_ expression: PitchResolvedExpression) -> Bool {
        expression.annotations.metadata["tieToNext"] == .boolean(true)
    }

    private func tieError(_ message: String, at expression: PitchResolvedExpression, diagnostics: inout [ComposerDiagnostic]) {
        diagnostics.append(.init(.error, path: expression.provenance.expansionPath.joined(separator: "."), message: message, range: expression.annotations.source))
    }

    private func rewriteTies(
        _ expression: PitchResolvedExpression,
        extendedDurations: [SemanticID: MusicalDuration],
        continuations: Set<SemanticID>,
        chains: [SemanticID: [SemanticID]]
    ) -> PitchResolvedExpression {
        let kind: PitchResolvedExpression.Kind
        switch expression.kind {
        case .sequence(let children): kind = .sequence(children.map { rewriteTies($0, extendedDurations: extendedDurations, continuations: continuations, chains: chains) })
        case .parallel(let children): kind = .parallel(children.map { rewriteTies($0, extendedDurations: extendedDurations, continuations: continuations, chains: chains) })
        case .technique(let application): kind = .technique(.init(technique: application.technique, form: application.form, operands: application.operands.map { rewriteTies($0, extendedDurations: extendedDurations, continuations: continuations, chains: chains) }, parameters: application.parameters))
        default: kind = expression.kind
        }
        let occurrence = expression.provenance.occurrenceID
        var metadata = expression.annotations.metadata
        if continuations.contains(occurrence) { metadata["tieContinuation"] = .boolean(true) }
        if let segmentIDs = chains[occurrence] { metadata["tieSegments"] = .list(segmentIDs.map(MetadataValue.reference)) }
        return .init(
            provenance: expression.provenance,
            offset: expression.offset,
            duration: extendedDurations[occurrence] ?? expression.duration,
            kind: kind,
            annotations: .init(metadata: metadata, source: expression.annotations.source)
        )
    }

    private func resolveRinging(
        in expression: PitchResolvedExpression,
        sectionDuration: MusicalDuration
    ) -> PitchResolvedExpression {
        var leaves: [TieLeaf] = []
        collectTieLeaves(expression, isInParallel: false, into: &leaves)
        let dampOffsets = leaves.compactMap { leaf in
            leaf.expression.annotations.metadata["damp"] == .boolean(true) ? leaf.expression.offset : nil
        }.sorted()
        var durations: [SemanticID: MusicalDuration] = [:]
        for leaf in leaves where leaf.expression.annotations.metadata["letRing"] == .boolean(true) {
            guard case .note = leaf.expression.kind else { continue }
            let writtenEnd = leaf.expression.offset + leaf.expression.duration
            let end = dampOffsets.first(where: { $0 >= writtenEnd }) ?? sectionDuration
            guard end > writtenEnd,
                  let value = end.wholeNotes.subtracting(leaf.expression.offset.wholeNotes) else { continue }
            durations[leaf.expression.provenance.occurrenceID] = .init(value.numerator, value.denominator)
        }
        return rewriteRinging(expression, extendedDurations: durations)
    }

    private func rewriteRinging(
        _ expression: PitchResolvedExpression,
        extendedDurations: [SemanticID: MusicalDuration]
    ) -> PitchResolvedExpression {
        let kind: PitchResolvedExpression.Kind
        switch expression.kind {
        case .sequence(let children): kind = .sequence(children.map { rewriteRinging($0, extendedDurations: extendedDurations) })
        case .parallel(let children): kind = .parallel(children.map { rewriteRinging($0, extendedDurations: extendedDurations) })
        case .technique(let application): kind = .technique(.init(
            technique: application.technique,
            form: application.form,
            operands: application.operands.map { rewriteRinging($0, extendedDurations: extendedDurations) },
            parameters: application.parameters
        ))
        default: kind = expression.kind
        }
        let occurrence = expression.provenance.occurrenceID
        var metadata = expression.annotations.metadata
        if let duration = extendedDurations[occurrence] {
            metadata["writtenDurationNumerator"] = .integer(expression.duration.wholeNotes.numerator)
            metadata["writtenDurationDenominator"] = .integer(expression.duration.wholeNotes.denominator)
            metadata["ringingResolved"] = .boolean(true)
            return .init(
                provenance: expression.provenance,
                offset: expression.offset,
                duration: duration,
                kind: kind,
                annotations: .init(metadata: metadata, source: expression.annotations.source)
            )
        }
        return .init(provenance: expression.provenance, offset: expression.offset, duration: expression.duration, kind: kind, annotations: expression.annotations)
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
        case .scaleDegree(let degree, let octave, let alteration):
            "@\(degree)\(alterationText(alteration))[\(octave)]"
        }
    }

    private func alterationText(_ alteration: Int) -> String {
        alteration >= 0
            ? String(repeating: "#", count: alteration)
            : String(repeating: "b", count: -alteration)
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
