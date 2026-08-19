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
}

public struct RealizedVoice: Sendable, Hashable {
    public let source: Voice
    public let expression: RealizedExpression
}

public struct RealizedPart: Sendable, Hashable {
    public let source: Part
    public let instrumentInstance: InstrumentInstanceDefinition
    public let instrumentModel: InstrumentID
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
                        RealizedVoice(
                            source: voice.source,
                            expression: realize(
                                voice.expression,
                                context: context,
                                path: "\(path).voices[\(voiceIndex)]"
                            )
                        )
                    }
                    parts.append(.init(
                        source: part.source,
                        instrumentInstance: context.instance,
                        instrumentModel: context.model.id,
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
                kind = .actuator(actuator)
            case .sequence(let children):
                kind = .sequence(children.enumerated().map { index, child in
                    realize(child, context: context, path: "\(path).sequence[\(index)]")
                })
            case .parallel(let children):
                kind = .parallel(children.enumerated().map { index, child in
                    realize(child, context: context, path: "\(path).parallel[\(index)]")
                })
            case .technique(let application):
                if !context.profile.techniques.contains(where: { $0.id == application.technique }) {
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
                guard let assignments = chordStringAssignments(chord, context: context) else {
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
                            soundingPitch: .absolute(assignment.pitch)
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
        }

        func chordStringAssignments(_ chord: ResolvedTimelineChord, context: Context) -> [StringAssignment]? {
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
                        let index = open.chromaticIndex + fret
                        let pitch = AbsolutePitch(PitchClass(rawValue: index % 12)!, octave: index / 12 - 1)
                        let assignment = StringAssignment(
                            course: course,
                            stringNumber: tuning.courses.count - course,
                            fret: fret,
                            pitch: pitch
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
                let fret = pitch.chromaticIndex - open.chromaticIndex
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
                  (lowest.chromaticIndex...highest.chromaticIndex).contains(pitch.chromaticIndex) else { return nil }
            return pitch.chromaticIndex - lowest.chromaticIndex + 1
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
            let producedIndex = openPitch.chromaticIndex + fret
            if producedIndex != claimedPitch.chromaticIndex {
                diagnostics.append(.init(
                    .error,
                    path: path,
                    message: "String \(stringNumber) fret \(fret) produces chromatic pitch \(producedIndex), not requested pitch \(claimedPitch.chromaticIndex)"
                ))
            }
        }
    }
}
