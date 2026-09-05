import UTABComposerCore

public struct RealizationRequest: Sendable {
    public let composition: PitchResolvedComposition
    public let catalog: InstrumentCatalog
    public let instrumentBindings: [String: InstrumentInstanceDefinition]

    public init(
        composition: PitchResolvedComposition,
        catalog: InstrumentCatalog,
        instrumentBindings: [String: InstrumentInstanceDefinition]
    ) {
        self.composition = composition
        self.catalog = catalog
        self.instrumentBindings = instrumentBindings
    }
}

public struct RealizedTechniqueApplication: Sendable, Hashable {
    public let technique: String
    public let form: TechniqueForm
    public let operands: [RealizedExpression]
    public let parameters: [String: MetadataValue]

    public init(technique: String, form: TechniqueForm, operands: [RealizedExpression], parameters: [String: MetadataValue]) {
        self.technique = technique
        self.form = form
        self.operands = operands
        self.parameters = parameters
    }
}

/// A performance tree with no abstract chord case. Every chord has been converted
/// to pitched notes or concrete actuator instructions for its bound instrument.
public struct RealizedExpression: Sendable, Hashable {
    public indirect enum Kind: Sendable, Hashable {
        case note(ResolvedTimelinePitch, constraints: [PerformanceConstraint])
        case rest
        case actuator(ActuatorExpression)
        case sequence([RealizedExpression])
        case parallel([RealizedExpression])
        case technique(RealizedTechniqueApplication)
    }

    public let provenance: ExpressionProvenance
    public let offset: MusicalDuration
    public let duration: MusicalDuration
    public let kind: Kind
    public let annotations: SemanticAnnotations

    public init(provenance: ExpressionProvenance, offset: MusicalDuration, duration: MusicalDuration, kind: Kind, annotations: SemanticAnnotations) {
        self.provenance = provenance
        self.offset = offset
        self.duration = duration
        self.kind = kind
        self.annotations = annotations
    }
}

public struct RealizedVoice: Sendable, Hashable {
    public let source: Voice
    public let expression: RealizedExpression
    public let lyrics: [AlignedLyricVerse]
}

public struct RealizedPart: Sendable, Hashable {
    public let source: Part
    public let instrumentInstance: InstrumentInstanceDefinition
    public let instrumentModel: InstrumentID
    public let instrumentRealization: InstrumentRealization?
    public let voices: [RealizedVoice]
}

public struct RealizedSection: Sendable, Hashable {
    public let source: Section
    public let duration: MusicalDuration
    public let parts: [RealizedPart]
}

public struct RealizedComposition: Sendable {
    public let source: PitchResolvedComposition
    public let sections: [RealizedSection]
    public let main: ExpandedArrangement?
}

public struct InstrumentRealizationStage: CompilerStage {
    public init() {}

    public func run(_ input: RealizationRequest) -> CompilerStageResult<RealizedComposition> {
        var worker = Worker(request: input)
        return worker.realize()
    }

    private struct Worker {
        let request: RealizationRequest
        var diagnostics: [ComposerDiagnostic] = []

        mutating func realize() -> CompilerStageResult<RealizedComposition> {
            var sections: [RealizedSection] = []
            for (sectionIndex, section) in request.composition.sections.enumerated() {
                var parts: [RealizedPart] = []
                for (partIndex, part) in section.parts.enumerated() {
                    let path = "sections[\(sectionIndex)].parts[\(partIndex)]"
                    guard let context = context(for: part.source.instrument, path: path) else { continue }
                    let voices = part.voices.enumerated().map { voiceIndex, voice in
                        let realized = realize(
                            voice.expression,
                            context: context,
                            path: "\(path).voices[\(voiceIndex)]"
                        )
                        return RealizedVoice(
                            source: voice.source,
                            expression: resolveChordTies(realized, path: "\(path).voices[\(voiceIndex)]"),
                            lyrics: voice.lyrics
                        )
                    }
                    parts.append(.init(
                        source: part.source,
                        instrumentInstance: context.instance,
                        instrumentModel: context.model.id,
                        instrumentRealization: context.model.realization,
                        voices: voices
                    ))
                }
                sections.append(.init(source: section.source, duration: section.duration, parts: parts))
            }
            guard !diagnostics.contains(where: { $0.severity == .error }) else {
                return .init(output: nil, diagnostics: diagnostics)
            }
            return .init(
                output: .init(source: request.composition, sections: sections, main: request.composition.main),
                diagnostics: diagnostics
            )
        }

        struct Context {
            let instance: InstrumentInstanceDefinition
            let model: InstrumentModelDefinition
            let profile: InstrumentProfileDefinition
            let tuning: InstrumentTuningDefinition?
            let fretCount: Int?

            var isKeyboard: Bool { profile.actuators.contains { $0.id == "keys" } }
            var isFrettedStrings: Bool { fretCount != nil && profile.actuators.contains { $0.id == "strings" } }
        }

        struct RealizedTone {
            let pitch: AbsolutePitch
            let expression: RealizedExpression
        }

        mutating func resolveChordTies(_ expression: RealizedExpression, path: String) -> RealizedExpression {
            var extended: [SemanticID: MusicalDuration] = [:]
            var continuations = Set<SemanticID>()
            diagnoseAndCollectChordTies(expression, path: path, extended: &extended, continuations: &continuations)
            return rewriteChordTies(expression, extended: extended, continuations: continuations)
        }

        mutating func diagnoseAndCollectChordTies(
            _ expression: RealizedExpression,
            path: String,
            extended: inout [SemanticID: MusicalDuration],
            continuations: inout Set<SemanticID>
        ) {
            switch expression.kind {
            case .sequence(let children):
                var active: [AbsolutePitch: (id: SemanticID, offset: MusicalDuration)] = [:]
                for index in children.indices {
                    let source = children[index]
                    guard source.annotations.metadata["tieToNext"] == .boolean(true) else {
                        active.removeAll()
                        diagnoseAndCollectChordTies(source, path: "\(path).sequence[\(index)]", extended: &extended, continuations: &continuations)
                        continue
                    }
                    let sourceTones = realizedTones(in: source)
                    guard sourceTones.count > 1 else { continue }
                    guard children.indices.contains(index + 1) else {
                        diagnostics.append(.init(.error, path: path, message: "A chord tie must be followed by another chord", range: source.annotations.source))
                        continue
                    }
                    let destination = children[index + 1]
                    let destinationTones = realizedTones(in: destination)
                    guard destinationTones.count > 1,
                          source.offset + source.duration == destination.offset else {
                        diagnostics.append(.init(.error, path: path, message: "A chord tie must connect adjacent realized chords", range: source.annotations.source))
                        continue
                    }
                    let sourceByPitch = Dictionary(grouping: sourceTones, by: \.pitch)
                    let destinationByPitch = Dictionary(grouping: destinationTones, by: \.pitch)
                    let shared = Set(sourceByPitch.keys).intersection(destinationByPitch.keys)
                    guard !shared.isEmpty else {
                        diagnostics.append(.init(.error, path: path, message: "Tied chords must share at least one sounding pitch", range: source.annotations.source))
                        active.removeAll()
                        continue
                    }
                    var nextActive: [AbsolutePitch: (id: SemanticID, offset: MusicalDuration)] = [:]
                    for pitch in shared {
                        guard sourceByPitch[pitch]?.count == 1, destinationByPitch[pitch]?.count == 1,
                              let sourceTone = sourceByPitch[pitch]?.first,
                              let destinationTone = destinationByPitch[pitch]?.first else {
                            diagnostics.append(.init(.error, path: path, message: "A chord tie is ambiguous when a realized chord doubles the same pitch", range: source.annotations.source))
                            continue
                        }
                        let origin = active[pitch] ?? (sourceTone.expression.provenance.occurrenceID, sourceTone.expression.offset)
                        let end = destinationTone.expression.offset + destinationTone.expression.duration
                        if let value = end.wholeNotes.subtracting(origin.offset.wholeNotes) {
                            extended[origin.id] = .init(value.numerator, value.denominator)
                            continuations.insert(destinationTone.expression.provenance.occurrenceID)
                            nextActive[pitch] = origin
                        }
                    }
                    active = nextActive
                }
            case .parallel(let children):
                for (index, child) in children.enumerated() {
                    diagnoseAndCollectChordTies(child, path: "\(path).parallel[\(index)]", extended: &extended, continuations: &continuations)
                }
            case .technique(let application):
                for (index, operand) in application.operands.enumerated() {
                    diagnoseAndCollectChordTies(operand, path: "\(path).technique[\(index)]", extended: &extended, continuations: &continuations)
                }
            case .note, .rest, .actuator: break
            }
        }

        func realizedTones(in expression: RealizedExpression) -> [RealizedTone] {
            switch expression.kind {
            case .note(let pitch, _): return [.init(pitch: pitch.absolute, expression: expression)]
            case .actuator(let actuator):
                guard case .absolute(let pitch)? = actuator.soundingPitch else { return [] }
                return [.init(pitch: pitch, expression: expression)]
            case .parallel(let children): return children.flatMap(realizedTones)
            case .technique(let application): return application.operands.flatMap(realizedTones)
            case .sequence, .rest: return []
            }
        }

        func rewriteChordTies(
            _ expression: RealizedExpression,
            extended: [SemanticID: MusicalDuration],
            continuations: Set<SemanticID>
        ) -> RealizedExpression {
            let kind: RealizedExpression.Kind
            switch expression.kind {
            case .sequence(let children): kind = .sequence(children.map { rewriteChordTies($0, extended: extended, continuations: continuations) })
            case .parallel(let children): kind = .parallel(children.map { rewriteChordTies($0, extended: extended, continuations: continuations) })
            case .technique(let application): kind = .technique(.init(
                technique: application.technique,
                form: application.form,
                operands: application.operands.map { rewriteChordTies($0, extended: extended, continuations: continuations) },
                parameters: application.parameters
            ))
            default: kind = expression.kind
            }
            let occurrence = expression.provenance.occurrenceID
            var metadata = expression.annotations.metadata
            if continuations.contains(occurrence) { metadata["tieContinuation"] = .boolean(true) }
            if extended[occurrence] != nil {
                metadata["writtenDurationNumerator"] = .integer(expression.duration.wholeNotes.numerator)
                metadata["writtenDurationDenominator"] = .integer(expression.duration.wholeNotes.denominator)
                metadata["tieResolvedWithinSection"] = .boolean(true)
            }
            return .init(
                provenance: expression.provenance,
                offset: expression.offset,
                duration: extended[occurrence] ?? expression.duration,
                kind: kind,
                annotations: .init(metadata: metadata, source: expression.annotations.source)
            )
        }

        mutating func context(for alias: String, path: String) -> Context? {
            guard let instance = request.instrumentBindings[alias] else {
                diagnostics.append(.init(.error, path: "\(path).instrument", message: "No instrument binding for '\(alias)'"))
                return nil
            }
            let modelID = instance.model
            guard let model = request.catalog.models.first(where: { $0.id == modelID }) else {
                diagnostics.append(.init(.error, path: "\(path).instrument", message: "Bound model '\(modelID)' is not present in the catalog"))
                return nil
            }
            guard let profile = request.catalog.profiles.first(where: { $0.id == model.profile }) else {
                diagnostics.append(.init(.error, path: "\(path).instrument", message: "Model '\(modelID)' has no resolvable capability profile"))
                return nil
            }
            let tuningID = model.defaultTuning ?? model.tunings.first
            let tuning = tuningID.flatMap { id in request.catalog.tunings.first { $0.id == id } }
            if tuningID != nil && tuning == nil {
                diagnostics.append(.init(.error, path: "\(path).instrument", message: "Model '\(modelID)' has an unresolved tuning"))
                return nil
            }
            let fretCount = model.geometry.first(where: { $0.id == "frets" }).flatMap { geometry -> Int? in
                guard case .integer(let value) = geometry.properties["count"] else { return nil }
                return value
            }
            return .init(instance: instance, model: model, profile: profile, tuning: tuning, fretCount: fretCount)
        }

        mutating func realize(
            _ expression: PitchResolvedExpression,
            context: Context,
            path: String
        ) -> RealizedExpression {
            let kind: RealizedExpression.Kind
            switch expression.kind {
            case .rest:
                kind = .rest
            case .note(let pitch, let constraints):
                kind = realizeNote(pitch, duration: expression.duration, constraints: constraints, context: context, path: path)
            case .chord(let chord, let constraints):
                kind = realizeChord(chord, duration: expression.duration, constraints: constraints, context: context, expression: expression, path: path)
            case .actuator(let actuator):
                validate(actuator: actuator, context: context, path: path)
                kind = .actuator(resolveSoundingPitch(for: actuator, context: context))
            case .sequence(let children):
                kind = .sequence(children.enumerated().map { index, child in
                    realize(child, context: context, path: "\(path).sequence[\(index)]")
                })
            case .parallel(let children):
                kind = .parallel(children.enumerated().map { index, child in
                    realize(child, context: context, path: "\(path).parallel[\(index)]")
                })
            case .technique(let application):
                if application.technique == "__performancePattern" {
                    kind = realizePerformancePattern(application, context: context, expression: expression, path: path)
                    break
                }
                let universalTechniques: Set<String> = ["legato", "slur", "rearticulate", "letRing", "accent", "__dynamic", "__dynamicEnvelope", "__sustainPedal"]
                if !universalTechniques.contains(application.technique),
                   !context.profile.techniques.contains(where: { $0.id == application.technique }) {
                    diagnostics.append(.init(.error, path: path, message: "Instrument '\(context.model.name)' does not support technique '\(application.technique)'"))
                }
                kind = .technique(.init(
                    technique: application.technique,
                    form: application.form,
                    operands: application.operands.enumerated().map { index, operand in
                        realize(operand, context: context, path: "\(path).technique[\(index)]")
                    },
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

        func resolveSoundingPitch(for actuator: ActuatorExpression, context: Context) -> ActuatorExpression {
            guard actuator.soundingPitch == nil,
                  actuator.target.group == "strings",
                  let member = actuator.target.member,
                  let stringNumber = Int(member), stringNumber > 0,
                  let tuning = context.tuning,
                  stringNumber <= tuning.courses.count else { return actuator }

            let stringsGeometry = context.model.geometry.first { $0.id == "strings" }
            let isHighToLow: Bool
            if case .text("highToLow")? = stringsGeometry?.properties["numbering"] {
                isHighToLow = true
            } else {
                isHighToLow = false
            }
            let courseIndex = isHighToLow ? stringNumber - 1 : tuning.courses.count - stringNumber
            guard let pitch = tuning.courses[courseIndex].pitches.first else { return actuator }
            let position = actuator.target.position ?? 0
            return .init(
                action: actuator.action,
                target: actuator.target,
                duration: actuator.duration,
                soundingPitch: .absolute(pitch.transposed(cents: position * 100)),
                parameters: actuator.parameters
            )
        }

        struct PatternStep {
            let interactions: [[String]]
        }

        mutating func realizePerformancePattern(
            _ application: PitchResolvedTechniqueApplication,
            context: Context,
            expression: PitchResolvedExpression,
            path: String
        ) -> RealizedExpression.Kind {
            guard let subdivision = patternSubdivision(application.parameters),
                  case .list(let encodedSteps)? = application.parameters["steps"],
                  let chordContainer = application.operands.first else {
                diagnostics.append(.init(.error, path: path, message: "Malformed performance pattern"))
                return .parallel([])
            }
            let steps = encodedSteps.compactMap(decodePatternStep)
            guard !steps.isEmpty else {
                diagnostics.append(.init(.error, path: path, message: "Performance pattern has no steps"))
                return .parallel([])
            }
            let chords: [PitchResolvedExpression]
            if case .sequence(let children) = chordContainer.kind { chords = children } else { chords = [chordContainer] }
            var result: [RealizedExpression] = []
            for chordExpression in chords {
                guard case .chord(let chord, let constraints) = chordExpression.kind,
                      let assignments = chordStringAssignments(chord, constraints: constraints, context: context, path: path) else {
                    diagnostics.append(.init(.error, path: path, message: "Performance patterns require chords playable by the bound string instrument"))
                    continue
                }
                var cursor = MusicalDuration.zero
                var stepIndex = 0
                while cursor < chordExpression.duration {
                    let step = steps[stepIndex % steps.count]
                    guard stepIndex < 1_000_000,
                          let start = chordExpression.offset.wholeNotes.adding(cursor.wholeNotes),
                          let remaining = chordExpression.duration.wholeNotes.subtracting(cursor.wholeNotes) else {
                        diagnostics.append(.init(.error, path: path, message: "Performance pattern timing overflows or exceeds one million steps", range: chordExpression.annotations.source))
                        return .parallel([])
                    }
                    let offset = MusicalDuration(start.numerator, start.denominator)
                    let duration = minDuration(subdivision, MusicalDuration(remaining.numerator, remaining.denominator))
                    let children = step.interactions.compactMap { words in
                        realizePatternInteraction(
                            words,
                            assignments: assignments,
                            offset: offset,
                            duration: duration,
                            parent: chordExpression,
                            context: context,
                            path: "\(path).step[\(stepIndex)]"
                        )
                    }
                    if children.count == 1 { result.append(children[0]) }
                    else if !children.isEmpty {
                        result.append(realizedContainer(from: chordExpression, discriminator: "pattern-step:\(stepIndex)", offset: offset, duration: duration, kind: .parallel(children)))
                    }
                    guard let next = cursor.wholeNotes.adding(duration.wholeNotes) else {
                        diagnostics.append(.init(.error, path: path, message: "Performance pattern timing overflows", range: chordExpression.annotations.source))
                        return .parallel([])
                    }
                    cursor = MusicalDuration(next.numerator, next.denominator)
                    stepIndex += 1
                }
            }
            return .sequence(result)
        }

        mutating func realizePatternInteraction(
            _ words: [String],
            assignments: [StringAssignment],
            offset: MusicalDuration,
            duration: MusicalDuration,
            parent: PitchResolvedExpression,
            context: Context,
            path: String
        ) -> RealizedExpression? {
            guard let action = words.first else { return nil }
            if action == "hold" { return nil }
            guard let interaction = context.profile.interactions.first(where: { $0.id == action }) else {
                diagnostics.append(.init(.error, path: path, message: "Instrument '\(context.model.name)' does not support interaction '\(action)'"))
                return nil
            }
            var parameters: [String: MetadataValue] = [:]
            var consumed = Set<Int>()
            consumed.insert(0)
            for argument in interaction.arguments {
                if let match = words.indices.dropFirst().first(where: { !consumed.contains($0) && argument.values.contains(words[$0]) }) {
                    parameters[argument.id] = .string(words[match])
                    consumed.insert(match)
                } else if argument.isRequired {
                    diagnostics.append(.init(.error, path: path, message: "Interaction '\(action)' requires argument '\(argument.id)'"))
                }
            }
            for (index, word) in words.enumerated() where interaction.modifiers.contains(word) {
                parameters[word] = .boolean(true)
                consumed.insert(index)
            }
            if let withIndex = words.firstIndex(of: "with"), words.indices.contains(withIndex + 1) {
                let effector = words[withIndex + 1]
                if !supports(effector: effector, interaction: interaction) {
                    diagnostics.append(.init(.error, path: path, message: "Interaction '\(action)' does not support effector '\(effector)'"))
                }
                parameters["effector"] = .string(effector)
                consumed.insert(withIndex); consumed.insert(withIndex + 1)
            }

            if action == "strum" {
                let direction = metadataString(parameters["direction"]) ?? "down"
                let ordered = direction == "up" ? Array(assignments.reversed()) : assignments
                parameters["members"] = .list(ordered.map { assignment in
                    .object([
                        "string": .integer(assignment.stringNumber),
                        "position": .integer(assignment.fret),
                        "pitch": .object([
                            "tuning": .string("12edo"),
                            "degree": .integer(assignment.pitch.pitchClass.rawValue),
                            "period": .integer(assignment.pitch.octave),
                        ]),
                    ])
                })
                parameters["spread"] = .string("24ms")
                if let shape = assignments.first?.chordShape { parameters["chordShape"] = .string(shape) }
                return realizedContainer(
                    from: parent,
                    discriminator: "strum:\(offset)",
                    offset: offset,
                    duration: duration,
                    kind: .actuator(.init(action: action, target: .init(group: "strings"), duration: duration, parameters: parameters))
                )
            }

            if action == "damp" {
                return realizedContainer(
                    from: parent,
                    discriminator: "damp:\(offset)",
                    offset: offset,
                    duration: duration,
                    kind: .actuator(.init(action: action, target: .init(group: "strings"), duration: duration, parameters: parameters))
                )
            }

            guard action == "pluck" else {
                let target = interaction.targets.first ?? "strings"
                return realizedContainer(
                    from: parent,
                    discriminator: "\(action):\(offset)",
                    offset: offset,
                    duration: duration,
                    kind: .actuator(.init(action: action, target: .init(group: target), duration: duration, parameters: parameters))
                )
            }
            let selectors = words.indices.filter { !consumed.contains($0) }.map { words[$0] }
            let assignment = selectAssignment(selectors.first ?? "highest", from: assignments)
            guard let assignment else { return nil }
            if let shape = assignment.chordShape { parameters["chordShape"] = .string(shape) }
            return realizedContainer(
                from: parent,
                discriminator: "pluck:\(assignment.stringNumber):\(offset)",
                offset: offset,
                duration: duration,
                kind: .actuator(.init(
                    action: "pluck",
                    target: .init(group: "strings", member: String(assignment.stringNumber), position: assignment.fret),
                    duration: duration,
                    soundingPitch: .absolute(assignment.pitch),
                    parameters: parameters
                ))
            )
        }

        func decodePatternStep(_ value: MetadataValue) -> PatternStep? {
            guard case .object(let object) = value else { return nil }
            if case .list(let words)? = object["words"] {
                return .init(interactions: [words.compactMap(metadataString)])
            }
            if case .list(let children)? = object["parallel"] {
                return .init(interactions: children.compactMap(decodePatternStep).flatMap(\.interactions))
            }
            return nil
        }

        func patternSubdivision(_ parameters: [String: MetadataValue]) -> MusicalDuration? {
            if case .integer(let n) = parameters["subdivisionNumerator"],
               case .integer(let d) = parameters["subdivisionDenominator"], n > 0, d > 0 {
                return MusicalDuration(n, d)
            }
            return metadataString(parameters["subdivision"]).flatMap(patternDuration)
        }

        func patternDuration(_ name: String) -> MusicalDuration? {
            switch name {
            case "w": .whole
            case "h": .half
            case "q": .quarter
            case "e": .eighth
            case "s": .init(1, 16)
            default: nil
            }
        }

        func supports(effector: String, interaction: Interaction) -> Bool {
            interaction.effectors.contains(effector)
                || (["thumb", "index", "middle", "ring", "little"].contains(effector) && interaction.effectors.contains("finger"))
        }

        func selectAssignment(_ selector: String, from assignments: [StringAssignment]) -> StringAssignment? {
            let ordered = assignments.sorted { $0.pitch.chromaticIndex < $1.pitch.chromaticIndex }
            switch selector {
            case "bass", "lowest": return ordered.first
            case "alternateBass": return ordered.dropFirst().first ?? ordered.first
            case "innerLow": return ordered.count > 2 ? ordered[1] : ordered.first
            case "inner", "innerHigh": return ordered.count > 2 ? ordered[ordered.count - 2] : ordered.last
            case "highest": return ordered.last
            default:
                if selector == "root" { return ordered.first }
                if selector.hasPrefix("string"), let number = Int(selector.dropFirst("string".count)) {
                    return assignments.first { $0.stringNumber == number }
                }
                return ordered.last
            }
        }

        func realizedContainer(
            from parent: PitchResolvedExpression,
            discriminator: String,
            offset: MusicalDuration,
            duration: MusicalDuration,
            kind: RealizedExpression.Kind
        ) -> RealizedExpression {
            let provenance = ExpressionProvenance(
                originID: parent.provenance.originID,
                ancestry: parent.provenance.ancestry + [parent.provenance.occurrenceID],
                expansionPath: parent.provenance.expansionPath + [discriminator]
            )
            return .init(provenance: provenance, offset: offset, duration: duration, kind: kind, annotations: parent.annotations)
        }

        func minDuration(_ lhs: MusicalDuration, _ rhs: MusicalDuration) -> MusicalDuration {
            lhs < rhs ? lhs : rhs
        }

        func metadataString(_ value: MetadataValue?) -> String? {
            guard case .string(let string)? = value else { return nil }
            return string
        }

        mutating func realizeNote(
            _ pitch: ResolvedTimelinePitch,
            duration: MusicalDuration,
            constraints: [PerformanceConstraint],
            context: Context,
            path: String
        ) -> RealizedExpression.Kind {
            if context.isKeyboard {
                guard let key = keyboardKey(for: pitch.absolute, model: context.model) else {
                    diagnostics.append(.init(.error, path: path, message: "Pitch is outside keyboard range for '\(context.model.name)'"))
                    return .note(pitch, constraints: constraints)
                }
                return .actuator(.init(
                    action: "press",
                    target: .init(group: "keys", member: String(key)),
                    duration: duration,
                    soundingPitch: .absolute(pitch.absolute)
                ))
            }
            if context.isFrettedStrings {
                guard let address = stringAddress(for: pitch.absolute, context: context) else {
                    diagnostics.append(.init(.error, path: path, message: "Pitch \(pitch.absolute.chromaticIndex) cannot be produced by '\(context.model.name)' under its active tuning"))
                    return .note(pitch, constraints: constraints)
                }
                return .actuator(.init(
                    action: "pluck",
                    target: address,
                    duration: duration,
                    soundingPitch: .absolute(pitch.absolute)
                ))
            }
            return .note(pitch, constraints: constraints)
        }

        mutating func realizeChord(
            _ chord: ResolvedTimelineChord,
            duration: MusicalDuration,
            constraints: [PerformanceConstraint],
            context: Context,
            expression: PitchResolvedExpression,
            path: String
        ) -> RealizedExpression.Kind {
            if context.isKeyboard {
                let octave = constraints.contains(where: {
                    guard case .group(let value) = $0 else { return false }
                    return value.lowercased() == "left" || value.lowercased() == "left hand"
                }) ? 3 : 4
                let pitches = chordPitches(chord, rootOctave: octave)
                let children = pitches.enumerated().map { index, pitch in
                    realizedChild(
                        from: expression,
                        discriminator: "chord-tone:\(index)",
                        kind: realizeNote(
                            .init(authored: .absolute(pitch), absolute: pitch),
                            duration: duration,
                            constraints: constraints,
                            context: context,
                            path: "\(path).tone[\(index)]"
                        )
                    )
                }
                return .parallel(children)
            }
            if context.isFrettedStrings {
                guard let assignments = chordStringAssignments(chord, constraints: constraints, context: context, path: path) else {
                    diagnostics.append(.init(.error, path: path, message: "No deterministic string/fret realization for chord on '\(context.model.name)'"))
                    return .parallel([])
                }
                return .parallel(assignments.enumerated().map { index, assignment in
                    realizedChild(
                        from: expression,
                        discriminator: "chord-string:\(assignment.course)",
                        kind: .actuator(.init(
                            action: "pluck",
                            target: .init(group: "strings", member: String(assignment.stringNumber), position: assignment.fret),
                            duration: duration,
                            soundingPitch: .absolute(assignment.pitch),
                            parameters: assignment.chordShape.map { ["chordShape": .string($0)] } ?? [:]
                        ))
                    )
                })
            }
            diagnostics.append(.init(.error, path: path, message: "Instrument '\(context.model.name)' has no chord realization strategy"))
            return .parallel([])
        }

        func realizedChild(
            from parent: PitchResolvedExpression,
            discriminator: String,
            kind: RealizedExpression.Kind
        ) -> RealizedExpression {
            let provenance = ExpressionProvenance(
                originID: parent.provenance.originID,
                ancestry: parent.provenance.ancestry + [parent.provenance.occurrenceID],
                expansionPath: parent.provenance.expansionPath + [discriminator]
            )
            return .init(
                provenance: provenance,
                offset: parent.offset,
                duration: parent.duration,
                kind: kind,
                annotations: parent.annotations
            )
        }

        func chordPitches(_ chord: ResolvedTimelineChord, rootOctave: Int) -> [AbsolutePitch] {
            chord.authored.quality.intervals.map { interval in
                let index = (rootOctave + 1) * 12 + chord.rootPitchClass.rawValue + interval
                return .init(PitchClass(rawValue: ((index % 12) + 12) % 12)!, octave: index / 12 - 1)
            }
        }

        struct StringAssignment {
            let course: Int
            let stringNumber: Int
            let fret: Int
            let pitch: AbsolutePitch
            let chordShape: String?
        }

        mutating func chordStringAssignments(_ chord: ResolvedTimelineChord, constraints: [PerformanceConstraint], context: Context, path: String) -> [StringAssignment]? {
            if let shapeName = constraints.compactMap({ constraint -> String? in
                guard case .chordShape(let name) = constraint else { return nil }
                return name
            }).first {
                return explicitChordShapeAssignments(named: shapeName, chord: chord, context: context, path: path)
            }
            return automaticChordStringAssignments(chord, context: context)
        }

        mutating func explicitChordShapeAssignments(named name: String, chord: ResolvedTimelineChord, context: Context, path: String) -> [StringAssignment]? {
            guard let shape = request.catalog.chordShapes.first(where: { $0.model == context.model.id && ($0.name == name || $0.id.rawValue == name) }) else {
                diagnostics.append(.init(.error, path: path, message: "Unknown chord shape '\(name)' for '\(context.model.name)'"))
                return nil
            }
            guard shape.root == chord.rootPitchClass, shape.quality == chord.authored.quality else {
                diagnostics.append(.init(.error, path: path, message: "Chord shape '\(name)' does not realize the requested chord"))
                return nil
            }
            guard let tuning = context.tuning, let fretCount = context.fretCount else { return nil }
            let chordTones = Set(shape.quality.intervals.map { (shape.root.rawValue + $0) % 12 })
            var assignments: [StringAssignment] = []
            for position in shape.strings {
                let course = tuning.courses.count - position.stringNumber
                guard tuning.courses.indices.contains(course), position.fret <= fretCount,
                      let open = tuning.courses[course].pitches.first else {
                    diagnostics.append(.init(.error, path: path, message: "Chord shape '\(name)' is outside the configured strings or fret range"))
                    return nil
                }
                let pitch = open.transposed(cents: position.fret * 100)
                guard chordTones.contains(pitch.pitchClass.rawValue) else {
                    diagnostics.append(.init(.error, path: path, message: "Chord shape '\(name)' contains a pitch outside the requested chord"))
                    return nil
                }
                assignments.append(.init(course: course, stringNumber: position.stringNumber, fret: position.fret, pitch: pitch, chordShape: shape.name))
            }
            guard Set(assignments.map { $0.pitch.pitchClass.rawValue }).isSuperset(of: chordTones) else {
                diagnostics.append(.init(.error, path: path, message: "Chord shape '\(name)' does not contain every chord tone"))
                return nil
            }
            return assignments.sorted { $0.stringNumber > $1.stringNumber }
        }

        func automaticChordStringAssignments(_ chord: ResolvedTimelineChord, context: Context) -> [StringAssignment]? {
            guard let tuning = context.tuning, let fretCount = context.fretCount else { return nil }
            let tones = chord.authored.quality.intervals.map { (chord.rootPitchClass.rawValue + $0) % 12 }
            var best: (cost: Int, values: [StringAssignment])?

            func search(_ toneIndex: Int, used: Set<Int>, values: [StringAssignment], cost: Int) {
                if toneIndex == tones.count {
                    if best == nil || cost < best!.cost || (cost == best!.cost && lexical(values) < lexical(best!.values)) {
                        best = (cost, values)
                    }
                    return
                }
                for (course, tuningCourse) in tuning.courses.enumerated() {
                    guard !used.contains(course), let open = tuningCourse.pitches.first else { continue }
                    for fret in 0...min(fretCount, 12) where (open.pitchClass.rawValue + fret) % 12 == tones[toneIndex] {
                        let pitch = open.transposed(cents: fret * 100)
                        let assignment = StringAssignment(
                            course: course,
                            stringNumber: tuning.courses.count - course,
                            fret: fret,
                            pitch: pitch,
                            chordShape: nil
                        )
                        search(toneIndex + 1, used: used.union([course]), values: values + [assignment], cost: cost + fret)
                    }
                }
            }
            search(0, used: [], values: [], cost: 0)
            return best?.values.sorted { $0.stringNumber > $1.stringNumber }
        }

        func lexical(_ values: [StringAssignment]) -> String {
            values.map { "\($0.course):\($0.fret)" }.joined(separator: ",")
        }

        func stringAddress(for pitch: AbsolutePitch, context: Context) -> ActuatorAddress? {
            guard let tuning = context.tuning, let fretCount = context.fretCount else { return nil }
            return tuning.courses.enumerated().compactMap { course, tuningCourse -> (Int, ActuatorAddress)? in
                guard let open = tuningCourse.pitches.first else { return nil }
                let cents = pitch.cents(relativeTo: open)
                guard cents.isMultiple(of: 100) else { return nil }
                let fret = cents / 100
                guard (0...fretCount).contains(fret) else { return nil }
                let stringNumber = tuning.courses.count - course
                return (fret, .init(group: "strings", member: String(stringNumber), position: fret))
            }.sorted { lhs, rhs in
                if lhs.0 != rhs.0 { return lhs.0 < rhs.0 }
                return lhs.1.member! < rhs.1.member!
            }.first?.1
        }

        func keyboardKey(for pitch: AbsolutePitch, model: InstrumentModelDefinition) -> Int? {
            guard let keyboard = model.geometry.first(where: { $0.id == "keyboard" }),
                  case .pitch(let lowest) = keyboard.properties["lowestPitch"],
                  case .pitch(let highest) = keyboard.properties["highestPitch"],
                  pitch.acousticCents >= lowest.acousticCents,
                  pitch.acousticCents <= highest.acousticCents else { return nil }
            let centsFromLowest = pitch.cents(relativeTo: lowest)
            guard centsFromLowest.isMultiple(of: 100) else { return nil }
            return centsFromLowest / 100 + 1
        }

        mutating func validate(actuator: ActuatorExpression, context: Context, path: String) {
            guard context.profile.actuators.contains(where: { $0.id == actuator.target.group }) else {
                diagnostics.append(.init(.error, path: path, message: "Unknown actuator group '\(actuator.target.group)' for '\(context.model.name)'"))
                return
            }
            if !context.profile.interactions.contains(where: { $0.id == actuator.action }) {
                diagnostics.append(.init(.error, path: path, message: "Unsupported action '\(actuator.action)' for '\(context.model.name)'"))
            }
            if actuator.target.group == "strings", context.isFrettedStrings {
                validateFrettedString(actuator: actuator, context: context, path: path)
            } else if actuator.target.group == "keys", context.isKeyboard,
                      let member = actuator.target.member, let key = Int(member) {
                let keyCount = context.profile.actuators.first(where: { $0.id == "keys" }).flatMap { actuator -> Int? in
                    guard case .exact(let count) = actuator.cardinality else { return nil }
                    return count
                }
                if key < 1 || keyCount.map({ key > $0 }) == true {
                    diagnostics.append(.init(.error, path: path, message: "Keyboard key \(key) is outside the supported actuator range"))
                }
            }
        }

        mutating func validateFrettedString(actuator: ActuatorExpression, context: Context, path: String) {
            guard let tuning = context.tuning, let fretCount = context.fretCount,
                  let member = actuator.target.member, let stringNumber = Int(member),
                  (1...tuning.courses.count).contains(stringNumber) else {
                diagnostics.append(.init(.error, path: path, message: "A fretted-string actuator requires a valid string number"))
                return
            }
            guard let fret = actuator.target.position, (0...fretCount).contains(fret) else {
                diagnostics.append(.init(.error, path: path, message: "Fret position is outside 0...\(fretCount)"))
                return
            }
            let courseIndex = tuning.courses.count - stringNumber
            guard let openPitch = tuning.courses[courseIndex].pitches.first else { return }
            guard let soundingPitch = actuator.soundingPitch else { return }
            guard case .absolute(let claimedPitch) = soundingPitch else {
                diagnostics.append(.init(.error, path: path, message: "A physical string/fret position cannot retain an unresolved relative sounding pitch"))
                return
            }
            let producedPitch = openPitch.transposed(cents: fret * 100)
            if !producedPitch.isAcousticallyEquivalent(to: claimedPitch) {
                diagnostics.append(.init(
                    .error,
                    path: path,
                    message: "String \(stringNumber) fret \(fret) produces acoustic pitch \(producedPitch.acousticCents) cents, not requested pitch \(claimedPitch.acousticCents) cents"
                ))
            }
        }
    }
}
