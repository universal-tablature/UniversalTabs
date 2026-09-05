import Foundation
import UTABComposerCore
import UTABInstruments
import UniversalTabs

public struct MinimalUTabLoweringStage: CompilerStage {
    public init() {}

    public func run(_ input: RealizedComposition) -> CompilerStageResult<UTabDocument> {
        var lowerer = Lowerer(input: input)
        return lowerer.lower()
    }

    private struct Capability {
        var actions: Set<String> = []
        var techniques: Set<String> = []
        var groups: [String: GroupCapability] = [:]
    }

    private struct GroupCapability {
        var maximumIndex: Int?
        var namedMembers: Set<String> = []
    }

    private struct TrackAccumulator {
        let id: String
        let name: String
        let instrumentID: String
        var parts: [TrackPart]
    }

    private struct EditingLeaf {
        let occurrenceID: String
        let offset: MusicalDuration
        let duration: MusicalDuration
    }

    private struct EditingBar {
        let offset: MusicalDuration
        let duration: MusicalDuration
        let source: SourceReference?
    }

    private struct Lowerer {
        let input: RealizedComposition
        var diagnostics: [ComposerDiagnostic] = []
        var capabilities: [String: Capability] = [:]
        var tracks: [String: TrackAccumulator] = [:]
        var instances: [String: InstrumentInstanceDefinition] = [:]
        var lyricsByOccurrence: [SemanticID: [AlignedLyricSyllable]] = [:]
        var editingOccurrences: [UTabEditingOccurrence] = []
        var editingContainers: [UTabEditingContainer] = []
        var editingMeasures: [UTabEditingMeasure] = []

        var composition: Composition { input.source.source.source.source.source }

        mutating func lower() -> CompilerStageResult<UTabDocument> {
            validateTimingRepresentation()
            guard diagnostics.isEmpty else { return .init(output: nil, diagnostics: diagnostics) }
            let sectionDefinitions = input.sections.map(makeSectionDefinition)
            for section in input.sections {
                lower(section)
            }
            let arrangement = lowerArrangement()
            let harmony = lowerHarmony()
            let tempos = lowerTempoMap(arrangement: arrangement)

            guard !diagnostics.contains(where: { $0.severity == .error }) else {
                return .init(output: nil, diagnostics: diagnostics)
            }

            let instrumentIDs = capabilities.keys.sorted()
            let profiles = instrumentIDs.map(makeProfile)
            let instruments = instrumentIDs.compactMap { id -> InstrumentInstance? in
                guard let instance = instances[id] else { return nil }
                return InstrumentInstance(
                    id: instance.id.rawValue,
                    name: instance.name,
                    profile: profileID(id),
                    configuration: instance.configuration.isEmpty ? nil : instance.configuration.mapValues(instrumentJSONValue),
                    realization: realization(for: id)
                )
            }
            let tuning = TuningDefinition(
                id: "12edo",
                type: "equalDivision",
                periodRatio: "2/1",
                divisions: 12,
                reference: .init(pitch: .init(degree: 9, period: 4), frequencyHz: 440),
                names: ["C": 0, "C#": 1, "D": 2, "Eb": 3, "E": 4, "F": 5, "F#": 6, "G": 7, "Ab": 8, "A": 9, "Bb": 10, "B": 11]
            )
            let setup = PerformanceSetup(
                profiles: profiles,
                instruments: instruments,
                time: .init(
                    meter: .init(numerator: composition.meter.numerator, denominator: composition.meter.denominator),
                    tempo: .init(quarterNotesPerMinute: composition.tempo),
                    tempoMap: tempos.isEmpty ? nil : tempos
                ),
                sections: sectionDefinitions,
                arrangement: arrangement,
                tunings: [tuning]
            )
            let metadata = UTabMetadata(
                version: "0.1-draft",
                documentId: composition.id.rawValue,
                title: composition.title,
                encoding: .init(
                    date: nil,
                    software: ["UTABLowering"],
                    encoders: nil,
                    description: "Generated from the high-level semantic compiler pipeline"
                ),
                miscellaneous: [
                    "sourceCompositionID": composition.id.rawValue,
                    "sourceMapping": "event-id-and-parameters",
                ]
            )
            let document = UTabDocument(
                utab: metadata,
                setup: setup,
                tracks: tracks.values.sorted { $0.id < $1.id }.map {
                    EventTrack(id: $0.id, name: $0.name, instrument: $0.instrumentID, parts: $0.parts)
                },
                harmony: harmony.isEmpty ? nil : harmony,
                editingMap: editingOccurrences.isEmpty && editingContainers.isEmpty && editingMeasures.isEmpty
                    ? nil
                    : UTabEditingMap(
                        occurrences: editingOccurrences,
                        containers: editingContainers,
                        measures: editingMeasures,
                        scale: editingScale()
                    )
            )
            return .init(output: document, diagnostics: diagnostics)
        }

        func editingScale() -> UTabEditingScale? {
            guard let scale = composition.scale else { return nil }
            let name: String
            switch scale.kind {
            case .major: name = "major"
            case .naturalMinor: name = "natural minor"
            case .custom(let customName, _): name = customName
            }
            return .init(
                tonic: format(scale.tonicSpelling),
                name: name,
                centIntervals: scale.kind.centIntervals
            )
        }

        func lowerHarmony() -> [HarmonyEvent] {
            input.source.sections.flatMap { section in
                let meter = section.source.meter ?? composition.meter
                if let harmony = section.harmony {
                    return harmonyEvents(
                        in: harmony,
                        sectionID: section.source.id.rawValue,
                        meter: meter
                    )
                }
                return section.parts.flatMap { part in
                    part.voices.flatMap { voice in
                        harmonyEvents(
                            in: voice.expression,
                            sectionID: section.source.id.rawValue,
                            meter: meter
                        )
                    }
                }
            }
        }

        struct TempoRamp {
            let offset: MusicalDuration
            let duration: MusicalDuration
            let target: Double
            let steps: Int
        }

        struct TempoFermata {
            let offset: MusicalDuration
            let duration: MusicalDuration
            let factor: Double
        }

        struct TempoRubato {
            let offset: MusicalDuration
            let duration: MusicalDuration
            let factor: Double
        }

        mutating func lowerTempoMap(arrangement: [ArrangementEntry]) -> [TempoChange] {
            var changesBySection: [String: [(MusicalDuration, Double)]] = [:]
            for section in input.sections {
                let sectionID = section.source.id.rawValue
                var changes: [(MusicalDuration, Double)] = []
                var ramps: [TempoRamp] = []
                var fermatas: [TempoFermata] = []
                var rubatos: [TempoRubato] = []
                for expression in section.parts.flatMap(\.voices).map(\.expression) {
                    collectTempoChanges(in: expression, points: &changes, ramps: &ramps, fermatas: &fermatas, rubatos: &rubatos)
                }
                for ramp in ramps.sorted(by: { $0.offset < $1.offset }) {
                    let end = ramp.offset + ramp.duration
                    guard end <= section.duration else {
                        diagnostics.append(.init(.error, path: sectionID, message: "Tempo ramp extends beyond its section"))
                        continue
                    }
                    if changes.contains(where: { ramp.offset < $0.0 && $0.0 < end }) ||
                        ramps.contains(where: { $0.offset != ramp.offset && ramp.offset < $0.offset && $0.offset < end }) {
                        diagnostics.append(.init(.error, path: sectionID, message: "Tempo ramps may not overlap another tempo directive"))
                        continue
                    }
                    let start = changes.filter { $0.0 <= ramp.offset }.sorted { $0.0 < $1.0 }.last?.1 ?? composition.tempo
                    for step in 1...ramp.steps {
                        guard let scaled = ramp.duration.wholeNotes.multiplied(by: Rational(step, ramp.steps)) else {
                            diagnostics.append(.init(.error, path: sectionID, message: "Tempo ramp timing exceeds the supported rational range"))
                            break
                        }
                        let offset = ramp.offset + MusicalDuration(scaled.numerator, scaled.denominator)
                        let progress = Double(step) / Double(ramp.steps)
                        changes.append((offset, start + (ramp.target - start) * progress))
                    }
                }
                for fermata in fermatas.sorted(by: { $0.offset < $1.offset }) {
                    let end = fermata.offset + fermata.duration
                    guard end <= section.duration else {
                        diagnostics.append(.init(.error, path: sectionID, message: "Fermata extends beyond its section"))
                        continue
                    }
                    if changes.contains(where: { fermata.offset < $0.0 && $0.0 < end }) ||
                        fermatas.contains(where: { $0.offset != fermata.offset && fermata.offset < $0.offset && $0.offset < end }) {
                        diagnostics.append(.init(.error, path: sectionID, message: "Fermatas may not overlap another tempo directive"))
                        continue
                    }
                    let active = changes.filter { $0.0 <= fermata.offset }.sorted { $0.0 < $1.0 }.last?.1 ?? composition.tempo
                    changes.append((fermata.offset, active / fermata.factor))
                    changes.append((end, active))
                }
                for rubato in rubatos.sorted(by: { $0.offset < $1.offset }) {
                    let end = rubato.offset + rubato.duration
                    guard end <= section.duration else {
                        diagnostics.append(.init(.error, path: sectionID, message: "Rubato span extends beyond its section"))
                        continue
                    }
                    if changes.contains(where: { rubato.offset < $0.0 && $0.0 < end }) ||
                        rubatos.contains(where: { $0.offset != rubato.offset && rubato.offset < $0.offset && $0.offset < end }) {
                        diagnostics.append(.init(.error, path: sectionID, message: "Rubato spans may not overlap another tempo directive"))
                        continue
                    }
                    let active = changes.filter { $0.0 <= rubato.offset }.sorted { $0.0 < $1.0 }.last?.1 ?? composition.tempo
                    changes.append((rubato.offset, active / rubato.factor))
                    changes.append((end, active))
                }
                let grouped = Dictionary(grouping: changes, by: { $0.0 })
                for (offset, values) in grouped where Set(values.map(\.1)).count > 1 {
                    diagnostics.append(.init(.error, path: sectionID, message: "Conflicting tempo changes at score offset \(offset)"))
                }
                changesBySection[sectionID] = grouped.values.compactMap(\.first).sorted { $0.0 < $1.0 }
            }
            return arrangement.flatMap { entry -> [TempoChange] in
                guard let section = input.sections.first(where: { $0.source.id.rawValue == entry.section }) else { return [] }
                let meter = section.source.meter ?? composition.meter
                return (changesBySection[entry.section] ?? []).map { offset, bpm in
                    let position = eventTime(offset, meter: meter).musical!
                    var at: [String: JSONValue] = ["entry": .string(entry.id), "measure": .number(Double(position.measure))]
                    if let beat = position.beat { at["beat"] = .number(Double(beat)) }
                    if let fraction = position.offset { at["offset"] = fraction }
                    return .init(at: at, quarterNotesPerMinute: bpm)
                }
            }
        }

        func collectTempoChanges(in expression: RealizedExpression, points: inout [(MusicalDuration, Double)], ramps: inout [TempoRamp], fermatas: inout [TempoFermata], rubatos: inout [TempoRubato]) {
            if case .decimal(let bpm)? = expression.annotations.metadata["tempoQuarterNotesPerMinute"] {
                points.append((expression.offset, bpm))
            }
            if case .decimal(let target)? = expression.annotations.metadata["tempoRampTarget"],
               case .integer(let numerator)? = expression.annotations.metadata["tempoRampDurationNumerator"],
               case .integer(let denominator)? = expression.annotations.metadata["tempoRampDurationDenominator"],
               case .integer(let steps)? = expression.annotations.metadata["tempoRampSteps"] {
                ramps.append(.init(offset: expression.offset, duration: .init(numerator, denominator), target: target, steps: steps))
            }
            if case .decimal(let factor)? = expression.annotations.metadata["fermataFactor"],
               case .integer(let numerator)? = expression.annotations.metadata["fermataDurationNumerator"],
               case .integer(let denominator)? = expression.annotations.metadata["fermataDurationDenominator"] {
                fermatas.append(.init(offset: expression.offset, duration: .init(numerator, denominator), factor: factor))
            }
            if case .decimal(let factor)? = expression.annotations.metadata["rubatoFactor"],
               case .integer(let numerator)? = expression.annotations.metadata["rubatoDurationNumerator"],
               case .integer(let denominator)? = expression.annotations.metadata["rubatoDurationDenominator"] {
                rubatos.append(.init(offset: expression.offset, duration: .init(numerator, denominator), factor: factor))
            }
            switch expression.kind {
            case .sequence(let children), .parallel(let children): children.forEach { collectTempoChanges(in: $0, points: &points, ramps: &ramps, fermatas: &fermatas, rubatos: &rubatos) }
            case .technique(let application): application.operands.forEach { collectTempoChanges(in: $0, points: &points, ramps: &ramps, fermatas: &fermatas, rubatos: &rubatos) }
            case .note, .rest, .actuator: break
            }
        }

        func harmonyEvents(
            in expression: PitchResolvedExpression,
            sectionID: String,
            meter: TimeSignature
        ) -> [HarmonyEvent] {
            switch expression.kind {
            case .chord(let chord, _):
                let root = pitchClassName(chord.rootPitchClass)
                let quality = qualityName(chord.authored.quality)
                return [.init(
                    id: expression.provenance.occurrenceID.rawValue,
                    section: sectionID,
                    at: eventTime(expression.offset, meter: meter),
                    duration: .init(quarterNotes: .string((expression.duration * 4).description)),
                    value: .init(
                        symbol: root + qualitySuffix(chord.authored.quality),
                        root: root,
                        quality: quality
                    ),
                    source: [
                        "origin": .string(expression.provenance.originID.rawValue),
                        "ancestry": .array(expression.provenance.ancestry.map { .string($0.rawValue) }),
                        "path": .array(expression.provenance.expansionPath.map(JSONValue.string)),
                    ]
                )]
            case .sequence(let children), .parallel(let children):
                return children.flatMap {
                    harmonyEvents(in: $0, sectionID: sectionID, meter: meter)
                }
            case .technique(let application):
                return application.operands.flatMap {
                    harmonyEvents(in: $0, sectionID: sectionID, meter: meter)
                }
            case .note, .rest, .actuator:
                return []
            }
        }

        func pitchClassName(_ pitchClass: PitchClass) -> String {
            ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"][pitchClass.rawValue]
        }

        func qualityName(_ quality: ChordQuality) -> String {
            switch quality {
            case .major: "major"
            case .minor: "minor"
            case .diminished: "diminished"
            case .suspendedFourth: "suspendedFourth"
            }
        }

        func qualitySuffix(_ quality: ChordQuality) -> String {
            switch quality {
            case .major: ""
            case .minor: "m"
            case .diminished: "dim"
            case .suspendedFourth: "sus4"
            }
        }

        mutating func lower(_ section: RealizedSection) {
            let meter = section.source.meter ?? composition.meter
            for part in section.parts {
                let instanceID = part.instrumentInstance.id.rawValue
                instances[instanceID] = part.instrumentInstance
                for voice in part.voices {
                    for aligned in voice.lyrics.flatMap(\.syllables) {
                        lyricsByOccurrence[aligned.attackOccurrenceID, default: []].append(aligned)
                    }
                    var events: [PerformanceEvent] = []
                    lower(
                        voice.expression,
                        instrument: instanceID,
                        meter: meter,
                        inheritedTechniques: [],
                        into: &events
                    )
                    events.sort {
                        if timeKey($0.at) != timeKey($1.at) { return timeKey($0.at) < timeKey($1.at) }
                        return ($0.id ?? "") < ($1.id ?? "")
                    }
                    let key = "\(instanceID)\u{1f}\(voice.source.id.rawValue)"
                    let trackID = "track:\(instanceID):\(voice.source.id.rawValue)"
                    collectEditingMap(
                        voice.expression,
                        trackID: trackID,
                        sectionID: section.source.id.rawValue,
                        meter: meter
                    )
                    let displayName = part.instrumentInstance.name ?? part.source.instrument
                    var track = tracks[key] ?? .init(
                        id: trackID,
                        name: "\(displayName) — \(voice.source.name)",
                        instrumentID: instanceID,
                        parts: []
                    )
                    track.parts.append(.init(
                        section: section.source.id.rawValue,
                        source: sourceReference(
                            id: section.source.id,
                            range: section.source.annotations.source
                        ),
                        events: events
                    ))
                    tracks[key] = track
                }
            }
        }

        mutating func collectEditingMap(
            _ expression: RealizedExpression,
            trackID: String,
            sectionID: String,
            meter: TimeSignature
        ) {
            var leaves: [EditingLeaf] = []
            var explicitBars: [EditingBar] = []
            collectEditingNode(
                expression,
                trackID: trackID,
                sectionID: sectionID,
                meter: meter,
                leaves: &leaves,
                explicitBars: &explicitBars
            )

            let measureCount = max(1, ceilingRatio(expression.duration, meter.duration))
            for measureIndex in 0..<measureCount {
                let measureStart = meter.duration * measureIndex
                let measureEnd = measureStart + meter.duration
                let contributors = leaves.filter { leaf in
                    leaf.offset < measureEnd && leaf.offset + leaf.duration > measureStart
                }.map(\.occurrenceID)
                let explicitBarSource = explicitBars.first { bar in
                    bar.offset == measureStart && bar.duration == meter.duration
                }?.source
                editingMeasures.append(.init(
                    id: "\(trackID):\(sectionID):measure:\(measureIndex + 1)",
                    trackID: trackID,
                    sectionID: sectionID,
                    measure: measureIndex + 1,
                    contributorOccurrenceIDs: contributors,
                    explicitBarSource: explicitBarSource
                ))
            }
        }

        mutating func collectEditingNode(
            _ expression: RealizedExpression,
            trackID: String,
            sectionID: String,
            meter: TimeSignature,
            leaves: inout [EditingLeaf],
            explicitBars: inout [EditingBar]
        ) {
            let occurrenceID = expression.provenance.occurrenceID.rawValue
            let definitionID = expression.provenance.originID.rawValue
            let source = sourceReference(
                id: expression.provenance.originID,
                range: expression.annotations.source,
                ancestry: expression.provenance.ancestry,
                path: expression.provenance.expansionPath
            )

            switch expression.kind {
            case .sequence(let children), .parallel(let children):
                let isExplicitBar = definitionID.hasPrefix("bar:")
                let kind: UTabEditingContainer.Kind
                switch expression.kind {
                case .parallel:
                    kind = .parallel
                default:
                    kind = isExplicitBar ? .explicitBar : .sequence
                }
                editingContainers.append(.init(
                    occurrenceID: occurrenceID,
                    definitionID: definitionID,
                    kind: kind,
                    trackID: trackID,
                    sectionID: sectionID,
                    childOccurrenceIDs: children.map { $0.provenance.occurrenceID.rawValue },
                    source: source
                ))
                if isExplicitBar {
                    explicitBars.append(.init(
                        offset: expression.offset,
                        duration: expression.duration,
                        source: source
                    ))
                }
                children.forEach {
                    collectEditingNode(
                        $0,
                        trackID: trackID,
                        sectionID: sectionID,
                        meter: meter,
                        leaves: &leaves,
                        explicitBars: &explicitBars
                    )
                }
            case .technique(let application):
                editingContainers.append(.init(
                    occurrenceID: occurrenceID,
                    definitionID: definitionID,
                    kind: .technique,
                    trackID: trackID,
                    sectionID: sectionID,
                    childOccurrenceIDs: application.operands.map { $0.provenance.occurrenceID.rawValue },
                    source: source
                ))
                application.operands.forEach {
                    collectEditingNode(
                        $0,
                        trackID: trackID,
                        sectionID: sectionID,
                        meter: meter,
                        leaves: &leaves,
                        explicitBars: &explicitBars
                    )
                }
            case .note:
                appendEditingOccurrence(
                    expression,
                    kind: .note,
                    trackID: trackID,
                    sectionID: sectionID,
                    meter: meter,
                    source: source,
                    leaves: &leaves
                )
            case .rest:
                appendEditingOccurrence(
                    expression,
                    kind: .rest,
                    trackID: trackID,
                    sectionID: sectionID,
                    meter: meter,
                    source: source,
                    leaves: &leaves
                )
            case .actuator:
                appendEditingOccurrence(
                    expression,
                    kind: .actuator,
                    trackID: trackID,
                    sectionID: sectionID,
                    meter: meter,
                    source: source,
                    leaves: &leaves
                )
            }
        }

        func editingPitchRepresentation(
            _ expression: RealizedExpression
        ) -> UTabEditingPitchRepresentation? {
            guard case .note(let resolvedPitch, _) = expression.kind else { return nil }
            switch resolvedPitch.authored {
            case .absolute(let pitch):
                return .init(
                    kind: .absolute,
                    letter: String(describing: pitch.spelling.letter).uppercased(),
                    accidental: pitch.spelling.accidental,
                    tuningOffsetCents: pitch.spelling.tuningOffsetCents,
                    octave: pitch.octave,
                    resolvedMIDIPitch: resolvedPitch.absolute.chromaticIndex
                )
            case .scaleDegree(let degree, let octave, let alteration):
                return .init(
                    kind: .scaleRelative,
                    degree: degree,
                    alteration: alteration,
                    octave: octave,
                    resolvedMIDIPitch: resolvedPitch.absolute.chromaticIndex
                )
            }
        }

        mutating func appendEditingOccurrence(
            _ expression: RealizedExpression,
            kind: UTabEditingOccurrence.Kind,
            trackID: String,
            sectionID: String,
            meter: TimeSignature,
            source: SourceReference?,
            leaves: inout [EditingLeaf]
        ) {
            let occurrenceID = expression.provenance.occurrenceID.rawValue
            editingOccurrences.append(.init(
                occurrenceID: occurrenceID,
                definitionID: expression.provenance.originID.rawValue,
                kind: kind,
                trackID: trackID,
                sectionID: sectionID,
                at: eventTime(expression.offset, meter: meter),
                duration: .init(quarterNotes: .string((expression.duration * 4).description)),
                pitchRepresentation: editingPitchRepresentation(expression),
                source: source
            ))
            leaves.append(.init(
                occurrenceID: occurrenceID,
                offset: expression.offset,
                duration: expression.duration
            ))
        }

        mutating func lower(
            _ expression: RealizedExpression,
            instrument: String,
            meter: TimeSignature,
            inheritedTechniques: [String],
            into events: inout [PerformanceEvent]
        ) {
            if expression.annotations.metadata["tieContinuation"] == .boolean(true) { return }
            switch expression.kind {
            case .sequence(let children), .parallel(let children):
                children.forEach {
                    lower($0, instrument: instrument, meter: meter, inheritedTechniques: inheritedTechniques, into: &events)
                }
            case .technique(let application):
                let techniques = inheritedTechniques + [application.technique]
                capabilities[instrument, default: .init()].techniques.insert(application.technique)
                application.operands.forEach {
                    lower($0, instrument: instrument, meter: meter, inheritedTechniques: techniques, into: &events)
                }
            case .rest:
                break
            case .note(let pitch, _):
                capabilities[instrument, default: .init()].actions.insert("play")
                if capabilities[instrument, default: .init()].groups["notes"] == nil {
                    capabilities[instrument, default: .init()].groups["notes"] = .init()
                }
                events.append(makeEvent(
                    expression,
                    meter: meter,
                    action: "play",
                    target: "notes",
                    parameters: ["pitch": pitchValue(pitch.absolute), "spelling": .string(format(pitch.absolute.spelling))],
                    techniques: inheritedTechniques
                ))
            case .actuator(let actuator):
                capabilities[instrument, default: .init()].actions.insert(actuator.action)
                register(actuator.target, for: instrument)
                var parameters = actuator.parameters.mapValues(jsonValue)
                if let position = actuator.target.position { parameters["position"] = .number(Double(position)) }
                if let soundingPitch = actuator.soundingPitch {
                    switch soundingPitch {
                    case .absolute(let pitch): parameters["pitch"] = pitchValue(pitch)
                    case .scaleDegree:
                        diagnostics.append(.init(
                            .error,
                            path: expression.provenance.expansionPath.joined(separator: "."),
                            message: "An exact actuator expression still contains an unresolved scale-relative sounding pitch"
                        ))
                    }
                }
                events.append(makeEvent(
                    expression,
                    meter: meter,
                    action: actuator.action,
                    target: target(actuator.target),
                    parameters: parameters,
                    techniques: inheritedTechniques
                ))
            }
        }

        mutating func register(_ address: ActuatorAddress, for instrument: String) {
            var group = capabilities[instrument, default: .init()].groups[address.group, default: .init()]
            if let member = address.member, let index = Int(member), index > 0 {
                group.maximumIndex = max(group.maximumIndex ?? 0, index)
            } else if let member = address.member {
                group.namedMembers.insert(member)
            }
            capabilities[instrument, default: .init()].groups[address.group] = group
        }

        func sourceReference(
            id: SemanticID,
            range: SourceRange? = nil,
            ancestry: [SemanticID] = [],
            path: [String] = []
        ) -> SourceReference? {
            let parsedRange: (file: String, line: Int, column: Int)? = {
                guard range == nil else { return nil }
                let components = id.rawValue.split(separator: ":", omittingEmptySubsequences: false)
                guard components.count >= 4,
                      let line = Int(components[components.count - 2]),
                      let column = Int(components[components.count - 1]) else { return nil }
                return (components.dropFirst().dropLast(2).joined(separator: ":"), line, column)
            }()
            guard let file = range?.fileID ?? parsedRange?.file,
                  let line = range?.start.line ?? parsedRange?.line,
                  let column = range?.start.column ?? parsedRange?.column else {
                return nil
            }
            return .init(
                id: id.rawValue,
                file: file,
                line: line,
                column: column,
                endLine: range?.end?.line ?? line,
                endColumn: range?.end?.column ?? column,
                ancestry: ancestry.isEmpty ? nil : ancestry.map(\.rawValue),
                path: path.isEmpty ? nil : path
            )
        }

        func makeEvent(
            _ expression: RealizedExpression,
            meter: TimeSignature,
            action: String,
            target: String,
            parameters: [String: JSONValue],
            techniques: [String]
        ) -> PerformanceEvent {
            var eventParameters = parameters
            if let lyrics = lyricsByOccurrence[expression.provenance.occurrenceID], !lyrics.isEmpty {
                eventParameters["_lyrics"] = .array(lyrics.sorted {
                    $0.verseID.rawValue < $1.verseID.rawValue
                }.map { lyric in
                    .object([
                        "verse": .string(lyric.verseID.rawValue),
                        "word": .string(lyric.wordID.rawValue),
                        "syllable": .string(lyric.syllable.id.rawValue),
                        "text": .string(lyric.syllable.text),
                        "position": .string(lyric.syllable.position.rawValue),
                    ])
                })
            }
            return .init(
                id: expression.provenance.occurrenceID.rawValue,
                at: eventTime(expression.offset, meter: meter),
                duration: .init(quarterNotes: .string((expression.duration * 4).description)),
                action: action,
                target: target,
                parameters: eventParameters,
                techniques: techniques.isEmpty ? nil : techniques,
                source: sourceReference(
                    id: expression.provenance.originID,
                    range: expression.annotations.source,
                    ancestry: expression.provenance.ancestry,
                    path: expression.provenance.expansionPath
                )
            )
        }

        func makeSectionDefinition(_ section: RealizedSection) -> SectionDefinition {
            let meter = section.source.meter ?? composition.meter
            let measures = max(1, ceilingRatio(section.duration, meter.duration))
            return .init(
                id: section.source.id.rawValue,
                name: section.source.name,
                length: .init(measures: measures),
                meterMap: [.init(
                    at: ["measure": .number(1)],
                    numerator: meter.numerator,
                    denominator: meter.denominator
                )]
            )
        }

        mutating func lowerArrangement() -> [ArrangementEntry] {
            guard let main = input.main else {
                return input.sections.enumerated().map { index, section in
                    .init(id: "entry:\(index):\(section.source.id.rawValue)", section: section.source.id.rawValue)
                }
            }
            var entries: [ArrangementEntry] = []
            flatten(main, into: &entries)
            return entries
        }

        mutating func flatten(_ arrangement: ExpandedArrangement, into entries: inout [ArrangementEntry]) {
            switch arrangement.kind {
            case .section(let occurrence):
                entries.append(.init(id: occurrence.occurrenceID.rawValue, section: occurrence.sectionID.rawValue))
            case .sequence(let children):
                children.forEach { flatten($0, into: &entries) }
            case .parallel:
                diagnostics.append(.init(.error, path: "main", message: "UTAB arrangement entries are sequential; parallel section arrangements are not supported by the minimal lowerer"))
            }
        }

        func makeProfile(_ instanceID: String) -> InstrumentProfile {
            let capability = capabilities[instanceID] ?? .init()
            let displayName = instances[instanceID]?.name ?? instanceID
            let actuators = capability.groups.mapValues { group -> ActuatorDefinition in
                let members = group.namedMembers.sorted().map { ActuatorMember(id: $0) }
                return .init(
                    type: "generated",
                    count: group.maximumIndex,
                    members: members.isEmpty ? nil : members
                )
            }
            return .init(
                id: profileID(instanceID),
                name: "Generated \(displayName) profile",
                profileVersion: "0.1-draft",
                actuators: actuators,
                interactions: Dictionary(uniqueKeysWithValues: capability.actions.sorted().map { ($0, .object([:])) }),
                techniques: capability.techniques.isEmpty ? nil : Dictionary(uniqueKeysWithValues: capability.techniques.sorted().map { ($0, .object([:])) })
            )
        }

        func profileID(_ instanceID: String) -> String { "profile:generated:\(instanceID)" }

        func realization(for instanceID: String) -> UniversalTabs.InstrumentRealization? {
            guard let source = input.sections.lazy
                .flatMap(\.parts)
                .first(where: { $0.instrumentInstance.id.rawValue == instanceID })?
                .instrumentRealization,
                  let midi = source.midi else { return nil }
            return .init(midi: .init(program: midi.program, percussion: midi.percussion))
        }

        func target(_ address: ActuatorAddress) -> String {
            guard let member = address.member else { return address.group }
            if Int(member) != nil { return "\(address.group)[\(member)]" }
            let escaped = member.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            return "\(address.group)[\"\(escaped)\"]"
        }

        func pitchValue(_ pitch: AbsolutePitch) -> JSONValue {
            if pitch.spelling.tuningOffsetCents != 0 {
                return .object(["frequencyHz": .number(pitch.frequency())])
            }
            return .object([
                "tuning": .string("12edo"),
                "degree": .number(Double(pitch.pitchClass.rawValue)),
                "period": .number(Double(pitch.octave)),
            ])
        }

        func format(_ spelling: SpelledPitchClass) -> String {
            let letter: String = switch spelling.letter {
            case .c: "C"; case .d: "D"; case .e: "E"; case .f: "F"
            case .g: "G"; case .a: "A"; case .b: "B"
            }
            if spelling.accidental > 0 { return letter + String(repeating: "#", count: spelling.accidental) }
            return letter + String(repeating: "b", count: -spelling.accidental)
        }

        func jsonValue(_ value: MetadataValue) -> JSONValue {
            switch value {
            case .string(let value): .string(value)
            case .integer(let value): .number(Double(value))
            case .decimal(let value): .number(value)
            case .boolean(let value): .boolean(value)
            case .list(let values): .array(values.map(jsonValue))
            case .object(let values): .object(values.mapValues(jsonValue))
            case .reference(let id): .string(id.rawValue)
            }
        }

        func instrumentJSONValue(_ value: InstrumentValue) -> JSONValue {
            switch value {
            case .integer(let value): .number(Double(value))
            case .decimal(let value): .number(value)
            case .boolean(let value): .boolean(value)
            case .text(let value): .string(value)
            case .pitch(let pitch): pitchValue(pitch)
            case .pitches(let pitches): .array(pitches.map(pitchValue))
            case .list(let values): .array(values.map(instrumentJSONValue))
            case .object(let values): .object(values.mapValues(instrumentJSONValue))
            case .scale(let id): .string(id.rawValue)
            }
        }

        /// UTAB serializes quarter-note fractions and materializes editing measures.
        /// Reject unsupported conversions before any integer arithmetic or allocation.
        mutating func validateTimingRepresentation() {
            for section in input.sections {
                let meter = section.source.meter ?? composition.meter
                let reciprocalMeter = Rational(meter.duration.wholeNotes.denominator, meter.duration.wholeNotes.numerator)
                guard let length = section.duration.wholeNotes.multiplied(by: reciprocalMeter),
                      length <= Rational(1_000_000) else {
                    diagnostics.append(.init(.error, path: section.source.id.rawValue, message: "UTAB section timing exceeds the supported rational range or one million measures", range: section.source.annotations.source))
                    continue
                }
                for part in section.parts { for voice in part.voices { validateTiming(voice.expression, meter: meter) } }
            }
        }

        mutating func validateTiming(_ expression: RealizedExpression, meter: TimeSignature) {
            let reciprocalMeter = Rational(meter.duration.wholeNotes.denominator, meter.duration.wholeNotes.numerator)
            if expression.duration.wholeNotes.multiplied(by: Rational(4)) == nil ||
                expression.offset.wholeNotes.multiplied(by: Rational(4)) == nil ||
                expression.offset.wholeNotes.multiplied(by: reciprocalMeter) == nil ||
                expression.offset.wholeNotes.multiplied(by: Rational(meter.denominator)) == nil {
                diagnostics.append(.init(.error, path: expression.provenance.originID.rawValue, message: "Timing cannot be represented exactly in UTAB quarter-note or meter units", range: expression.annotations.source))
            }
            switch expression.kind {
            case .sequence(let children), .parallel(let children):
                for child in children { validateTiming(child, meter: meter) }
            case .technique(let application):
                for operand in application.operands { validateTiming(operand, meter: meter) }
            default: break
            }
        }

        func eventTime(_ offset: MusicalDuration, meter: TimeSignature) -> EventTime {
            let measureIndex = floorRatio(offset, meter.duration)
            let measureStart = meter.duration * measureIndex
            let remainder = subtract(offset, measureStart)
            let beatDuration = MusicalDuration(1, meter.denominator)
            let beatIndex = floorRatio(remainder, beatDuration)
            let beatStart = beatDuration * beatIndex
            let beatRemainder = subtract(remainder, beatStart)
            let beatFraction = divide(beatRemainder, beatDuration)
            return .init(musical: .init(
                measure: measureIndex + 1,
                beat: beatIndex + 1,
                offset: beatFraction.numerator == 0 ? nil : .string(beatFraction.description)
            ))
        }

        func timeKey(_ time: EventTime) -> String {
            guard let musical = time.musical else { return "" }
            return String(format: "%08d:%08d:%@", musical.measure, musical.beat ?? 1, String(describing: musical.offset))
        }

        func floorRatio(_ lhs: MusicalDuration, _ rhs: MusicalDuration) -> Int {
            let value = divide(lhs, rhs)
            return value.numerator / value.denominator
        }

        func ceilingRatio(_ lhs: MusicalDuration, _ rhs: MusicalDuration) -> Int {
            let value = divide(lhs, rhs)
            return value.numerator / value.denominator + (value.numerator % value.denominator == 0 ? 0 : 1)
        }

        func subtract(_ lhs: MusicalDuration, _ rhs: MusicalDuration) -> MusicalDuration {
            let value = lhs.wholeNotes.subtracting(rhs.wholeNotes)!
            return MusicalDuration(value.numerator, value.denominator)
        }

        func divide(_ lhs: MusicalDuration, _ rhs: MusicalDuration) -> Rational {
            lhs.wholeNotes.multiplied(by: Rational(rhs.wholeNotes.denominator, rhs.wholeNotes.numerator))!
        }
    }
}
