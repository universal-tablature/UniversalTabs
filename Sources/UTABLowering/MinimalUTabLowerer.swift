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

    private struct Lowerer {
        let input: RealizedComposition
        var diagnostics: [ComposerDiagnostic] = []
        var capabilities: [String: Capability] = [:]
        var tracks: [String: TrackAccumulator] = [:]
        var instances: [String: InstrumentInstanceDefinition] = [:]

        var composition: Composition { input.source.source.source.source.source }

        mutating func lower() -> CompilerStageResult<UTabDocument> {
            let sectionDefinitions = input.sections.map(makeSectionDefinition)
            for section in input.sections {
                lower(section)
            }
            let arrangement = lowerArrangement()

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
                    configuration: instance.configuration.isEmpty ? nil : instance.configuration.mapValues(instrumentJSONValue)
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
                    tempo: .init(quarterNotesPerMinute: composition.tempo)
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
                }
            )
            return .init(output: document, diagnostics: diagnostics)
        }

        mutating func lower(_ section: RealizedSection) {
            let meter = section.source.meter ?? composition.meter
            for part in section.parts {
                let instanceID = part.instrumentInstance.id.rawValue
                instances[instanceID] = part.instrumentInstance
                for voice in part.voices {
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
                    let displayName = part.instrumentInstance.name ?? part.source.instrument
                    var track = tracks[key] ?? .init(
                        id: trackID,
                        name: "\(displayName) — \(voice.source.name)",
                        instrumentID: instanceID,
                        parts: []
                    )
                    track.parts.append(.init(section: section.source.id.rawValue, events: events))
                    tracks[key] = track
                }
            }
        }

        mutating func lower(
            _ expression: RealizedExpression,
            instrument: String,
            meter: TimeSignature,
            inheritedTechniques: [String],
            into events: inout [PerformanceEvent]
        ) {
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

        func makeEvent(
            _ expression: RealizedExpression,
            meter: TimeSignature,
            action: String,
            target: String,
            parameters: [String: JSONValue],
            techniques: [String]
        ) -> PerformanceEvent {
            var eventParameters = parameters
            eventParameters["_source"] = .object([
                "origin": .string(expression.provenance.originID.rawValue),
                "ancestry": .array(expression.provenance.ancestry.map { .string($0.rawValue) }),
                "path": .array(expression.provenance.expansionPath.map(JSONValue.string)),
            ])
            return .init(
                id: expression.provenance.occurrenceID.rawValue,
                at: eventTime(expression.offset, meter: meter),
                duration: .init(quarterNotes: .string((expression.duration * 4).description)),
                action: action,
                target: target,
                parameters: eventParameters,
                techniques: techniques.isEmpty ? nil : techniques
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

        func target(_ address: ActuatorAddress) -> String {
            guard let member = address.member else { return address.group }
            if Int(member) != nil { return "\(address.group)[\(member)]" }
            let escaped = member.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            return "\(address.group)[\"\(escaped)\"]"
        }

        func pitchValue(_ pitch: AbsolutePitch) -> JSONValue {
            .object([
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
            let a = lhs.wholeNotes
            let b = rhs.wholeNotes
            return (a.numerator * b.denominator) / (a.denominator * b.numerator)
        }

        func ceilingRatio(_ lhs: MusicalDuration, _ rhs: MusicalDuration) -> Int {
            let a = lhs.wholeNotes
            let b = rhs.wholeNotes
            let numerator = a.numerator * b.denominator
            let denominator = a.denominator * b.numerator
            return (numerator + denominator - 1) / denominator
        }

        func subtract(_ lhs: MusicalDuration, _ rhs: MusicalDuration) -> MusicalDuration {
            .init(
                lhs.wholeNotes.numerator * rhs.wholeNotes.denominator - rhs.wholeNotes.numerator * lhs.wholeNotes.denominator,
                lhs.wholeNotes.denominator * rhs.wholeNotes.denominator
            )
        }

        func divide(_ lhs: MusicalDuration, _ rhs: MusicalDuration) -> Rational {
            .init(
                lhs.wholeNotes.numerator * rhs.wholeNotes.denominator,
                lhs.wholeNotes.denominator * rhs.wholeNotes.numerator
            )
        }
    }
}
