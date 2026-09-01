import Foundation

public struct ConversionResult: Sendable {
    public let midi: Data
    public let diagnostics: [String]
}

public enum UTabConversionError: Error, CustomStringConvertible {
    case invalidDocument(Error)

    public var description: String {
        switch self {
        case .invalidDocument(let error):
            "invalid utab document: \(error.localizedDescription)"
        }
    }
}

public final class UTabMIDIConverter {
    private struct PositionedEvent {
        let event: PerformanceEvent
        let offset: Int
        let section: SectionDefinition?
    }

    private let division = StandardMIDIFile.ticksPerQuarter
    private var diagnostics: [String] = []
    private var bpm = 120.0
    private var numerator = 4
    private var denominator = 4
    private var tunings: [String: TuningDefinition] = [:]

    public init() {}

    public func convert(data: Data) throws -> ConversionResult {
        let document: UTabDocument
        do {
            document = try JSONDecoder().decode(UTabDocument.self, from: data)
        } catch {
            throw UTabConversionError.invalidDocument(error)
        }

        return convert(document: document)
    }

    public func convert(document: UTabDocument) -> ConversionResult {

        diagnostics = UTabValidator().validate(document).map(\.description)
        bpm = 120
        numerator = 4
        denominator = 4
        readTime(document.setup.time)
        tunings = Dictionary((document.setup.tunings ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        let profiles = Dictionary(
            document.setup.profiles.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let instruments = Dictionary(
            document.setup.instruments.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var midiTracks: [[MIDIMessage]] = []

        for (index, track) in document.tracks.enumerated() {
            let name = track.name ?? track.id
            guard let instrument = instruments[track.instrument] else {
                diagnostics.append("\(name): skipped because instrument '\(track.instrument)' is unresolved")
                continue
            }
            guard let profile = profiles[instrument.profile] else {
                diagnostics.append("\(name): skipped because profile '\(instrument.profile)' is unresolved")
                continue
            }
            if profile.actuators == nil, profile.source != nil {
                diagnostics.append("\(name): external profile '\(profile.id)' is not loaded")
            }
            midiTracks.append(convertTrack(
                expandedEvents(for: track, setup: document.setup),
                name: name,
                instrument: instrument,
                profile: profile,
                channel: index % 9
            ))
        }

        let conductor = conductorTrack(for: document.setup)
        return ConversionResult(
            midi: StandardMIDIFile.make(conductor: conductor, tracks: midiTracks),
            diagnostics: diagnostics
        )
    }

    private func convertTrack(
        _ positionedEvents: [PositionedEvent],
        name: String,
        instrument: InstrumentInstance,
        profile: InstrumentProfile,
        channel: Int
    ) -> [MIDIMessage] {
        let midiRealization = instrument.realization?.midi
        let isDrums = midiRealization?.percussion == true
        let midiChannel = isDrums ? 9 : channel
        var output = [StandardMIDIFile.trackName(name)]
        if !isDrums {
            output.append(MIDIMessage(
                tick: 0,
                priority: 0,
                bytes: [UInt8(0xC0 | midiChannel), UInt8(generalMIDIProgram(midiRealization?.program ?? 1))]
            ))
        }

        let tuning = pitchArray(instrument.configuration?["tuning"])
            ?? pitchArray(instrument.configuration?["melodyStringTuning"])
            ?? []
        let indexOrder = string(instrument.configuration?["stringIndexOrder"])
            ?? "lowest-to-highest"
        let directPitches = collectMemberPitches(profile)
        var frets: [Int: Int] = [:]
        var ratios: [Int: Double] = [:]
        var muted = Set<Int>()
        var pitchesFromBitsets: [String: Int] = [:]

        let sortedEvents = positionedEvents.enumerated().sorted {
            let leftTick = eventTick($0.element.event, section: $0.element.section) + $0.element.offset
            let rightTick = eventTick($1.element.event, section: $1.element.section) + $1.element.offset
            if leftTick != rightTick { return leftTick < rightTick }
            let leftPriority = $0.element.event.changes == nil ? 1 : 0
            let rightPriority = $1.element.event.changes == nil ? 1 : 0
            return leftPriority == rightPriority ? $0.offset < $1.offset : leftPriority < rightPriority
        }

        for (_, positioned) in sortedEvents {
            let event = positioned.event
            let tick = eventTick(event, section: positioned.section) + positioned.offset
            for change in event.changes ?? [] {
                if let stringIndex = targetIndex(change.target, group: "strings")
                    ?? targetIndex(change.target, group: "melodyStrings") {
                    if change.parameter == "fret", let value = int(change.value) {
                        frets[stringIndex] = value
                    }
                    if change.parameter == "muted", bool(change.value) == true {
                        muted.insert(stringIndex)
                    }
                    if change.parameter == "muted", bool(change.value) == false {
                        muted.remove(stringIndex)
                    }
                    if change.parameter == "position",
                       let object = object(change.value),
                       let ratio = double(object["ratioFromNut"]) {
                        ratios[stringIndex] = ratio
                    }
                } else if change.parameter == "state" {
                    if let resolved = bitsetPitches(profile: profile, group: change.target, value: change.value) {
                        pitchesFromBitsets = resolved
                    } else {
                        diagnostics.append("\(name): bitset state at tick \(tick) has no pitch mapping and was ignored")
                    }
                }
            }

            let action = event.action
            let gesture = event.gesture
            let eventTargets = event.targets ?? event.target.map { [$0] } ?? []
            let target = eventTargets.first
            let parameters = event.parameters ?? [:]

            if action == "setPosition", let target,
               let index = targetIndex(target, group: "strings"),
               let fret = int(parameters["fret"]) {
                frets[index] = fret
                continue
            }

            if action == "strum" || gesture == "strum", let target {
                let indices = targetRange(target, group: "strings")
                let spread = object(parameters["spread"])
                let spreadMS = double(spread?["value"]) ?? 30
                let spreadTicks = Int((spreadMS / 1000 * bpm / 60 * Double(division)).rounded())
                for (offset, index) in indices.enumerated() where !muted.contains(index) {
                    if let note = stringNote(
                        index: index,
                        tuning: tuning,
                        order: indexOrder,
                        fret: frets[index] ?? 0,
                        ratio: ratios[index]
                    ) {
                        addNote(
                            &output,
                            tick: tick + offset * spreadTicks,
                            duration: defaultDuration(),
                            channel: midiChannel,
                            note: note,
                            velocity: velocity(parameters)
                        )
                    }
                }
                continue
            }

            if gesture == "roll", let target, let note = directPitches[target] {
                let duration = durationTicks(event)
                let rate = double(object(parameters["rate"])?["value"]) ?? 12
                let interval = max(1, Int((Double(division) * bpm / 60 / rate).rounded()))
                var strikeTick = tick
                while strikeTick < tick + duration {
                    addNote(
                        &output,
                        tick: strikeTick,
                        duration: min(interval, defaultDuration()),
                        channel: midiChannel,
                        note: note,
                        velocity: velocity(parameters)
                    )
                    strikeTick += interval
                }
                continue
            }

            guard let action, !eventTargets.isEmpty else { continue }
            if action == "strum", case .array(let members)? = parameters["members"] {
                let spreadMilliseconds = string(parameters["spread"]).flatMap { value -> Double? in
                    guard value.hasSuffix("ms") else { return nil }
                    return Double(value.dropLast(2))
                } ?? 24
                let totalSpreadTicks = max(1, Int((spreadMilliseconds / 1_000 * Double(division) * bpm / 60).rounded()))
                let interval = members.count > 1 ? max(1, totalSpreadTicks / (members.count - 1)) : 0
                let accentedVelocity = min(127, velocity(parameters) + (bool(parameters["accent"]) == true ? 12 : 0))
                for (index, value) in members.enumerated() {
                    guard let member = object(value),
                          let pitch = pitchValue(member["pitch"]),
                          let note = midiNote(pitch) else { continue }
                    addNote(
                        &output,
                        tick: tick + index * interval,
                        duration: durationTicks(event),
                        channel: midiChannel,
                        note: note,
                        velocity: accentedVelocity
                    )
                }
            } else if action == "pluck" || action == "bow" {
                for target in eventTargets {
                    let group = target.hasPrefix("melodyStrings") ? "melodyStrings" : "strings"
                    let stringIndex = targetIndex(target, group: group)
                    let note = pitchValue(parameters["pitch"]).flatMap(midiNote)
                        ?? pitchesFromBitsets[target]
                        ?? stringIndex.flatMap {
                        stringNote(index: $0, tuning: tuning, order: indexOrder, fret: frets[$0] ?? 0, ratio: ratios[$0])
                    }
                    if let index = stringIndex, !muted.contains(index), let note {
                        addNote(&output, tick: tick, duration: durationTicks(event), channel: midiChannel, note: note, velocity: velocity(parameters))
                    } else {
                        diagnostics.append("\(name): could not resolve pitch for \(target) at tick \(tick)")
                    }
                }
            } else if action == "strike" {
                for target in eventTargets {
                    if isDrums, let note = drumNote(target) {
                        addNote(&output, tick: tick, duration: defaultDuration() / 2, channel: 9, note: note, velocity: velocity(parameters))
                    } else if let note = directPitches[target] {
                        addNote(&output, tick: tick, duration: durationTicks(event), channel: midiChannel, note: note, velocity: velocity(parameters))
                    } else {
                        diagnostics.append("\(name): could not resolve pitch for \(target) at tick \(tick)")
                    }
                }
            } else if action == "sing" {
                if let pitch = pitchValue(parameters["pitch"]), let note = midiNote(pitch) {
                    addNote(&output, tick: tick, duration: durationTicks(event), channel: midiChannel, note: note, velocity: velocity(parameters))
                } else {
                    diagnostics.append("\(name): singing event at tick \(tick) has no supported pitch")
                }
            }
        }
        return output
    }

    private func expandedEvents(for track: EventTrack, setup: PerformanceSetup) -> [PositionedEvent] {
        if let events = track.events {
            return events.map { PositionedEvent(event: $0, offset: 0, section: nil) }
        }
        guard let parts = track.parts,
              let arrangement = setup.arrangement,
              let sections = setup.sections else { return [] }

        let sectionsByID = Dictionary(sections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let reusableParts = Dictionary(
            parts.compactMap { part in part.section.map { ($0, part) } },
            uniquingKeysWith: { first, _ in first }
        )
        let entryParts = Dictionary(
            parts.compactMap { part in part.entry.map { ($0, part) } },
            uniquingKeysWith: { first, _ in first }
        )

        var result: [PositionedEvent] = []
        var offset = 0
        for entry in arrangement {
            guard let section = sectionsByID[entry.section] else { continue }
            for _ in 0..<max(0, entry.effectivePlayCount) {
                let reusable = reusableParts[entry.section]
                let specific = entryParts[entry.id]
                let selected: [TrackPart]
                if let specific {
                    selected = specific.mode == .overlay ? [reusable, specific].compactMap { $0 } : [specific]
                } else {
                    selected = reusable.map { [$0] } ?? []
                }
                for part in selected {
                    result.append(contentsOf: part.events.map { PositionedEvent(event: $0, offset: offset, section: section) })
                }
                offset += sectionTicks(section)
            }
        }
        return result
    }

    private func sectionTicks(_ section: SectionDefinition) -> Int {
        let quarters = (1...section.length.measures).reduce(0.0) { total, measure in
            let meter = meter(for: measure, in: section)
            return total + Double(meter.numerator) * 4 / Double(meter.denominator)
        }
        return max(0, Int((quarters * Double(division)).rounded()))
    }

    private func readTime(_ time: TimeSetup?) {
        guard let time else { return }
        if let first = time.tempoMap?.first { bpm = first.quarterNotesPerMinute }
        if let first = time.meterMap?.first {
            numerator = first.numerator
            denominator = first.denominator
        }
        if let tempo = time.tempo { bpm = tempo.quarterNotesPerMinute }
        if let meter = time.meter {
            numerator = meter.numerator
            denominator = meter.denominator
        }
    }

    private func conductorTrack(for setup: PerformanceSetup) -> [MIDIMessage] {
        var messages = StandardMIDIFile.conductorTrack(bpm: bpm, numerator: numerator, denominator: denominator)
        guard let arrangement = setup.arrangement, let sections = setup.sections else { return messages }
        let sectionsByID = Dictionary(sections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var entryOffsets: [String: Int] = [:]
        var offset = 0
        for entry in arrangement {
            guard let section = sectionsByID[entry.section] else { continue }
            entryOffsets[entry.id] = offset
            for _ in 0..<max(0, entry.effectivePlayCount) {
                for meterChange in section.meterMap ?? [] {
                    let measure = int(meterChange.at?["measure"]) ?? 1
                    let tick = offset + tickAtStart(ofMeasure: measure, in: section)
                    if tick != 0 || meterChange.numerator != numerator || meterChange.denominator != denominator {
                        messages.append(StandardMIDIFile.meterChange(numerator: meterChange.numerator, denominator: meterChange.denominator, tick: tick))
                    }
                }
                offset += sectionTicks(section)
            }
        }
        for tempo in setup.time?.tempoMap ?? [] {
            guard let entryID = string(tempo.at?["entry"]),
                  let entryOffset = entryOffsets[entryID],
                  let entry = arrangement.first(where: { $0.id == entryID }),
                  let section = sectionsByID[entry.section] else { continue }
            let measure = int(tempo.at?["measure"]) ?? 1
            let beat = int(tempo.at?["beat"]) ?? 1
            let localTick = tickAtStart(ofMeasure: measure, in: section)
                + tickWithinMeasure(beat: beat, offset: rational(tempo.at?["offset"]) ?? 0, meter: meter(for: measure, in: section))
            let tick = entryOffset + localTick
            if tick != 0 || tempo.quarterNotesPerMinute != bpm {
                messages.append(StandardMIDIFile.tempoChange(bpm: tempo.quarterNotesPerMinute, tick: tick))
            }
        }
        return messages
    }

    private func tickAtStart(ofMeasure measure: Int, in section: SectionDefinition) -> Int {
        guard measure > 1 else { return 0 }
        let quarters = (1..<measure).reduce(0.0) { total, priorMeasure in
            let meter = meter(for: priorMeasure, in: section)
            return total + Double(meter.numerator) * 4 / Double(meter.denominator)
        }
        return Int((quarters * Double(division)).rounded())
    }

    private func tickWithinMeasure(beat: Int, offset: Double, meter: MeterChange) -> Int {
        Int(((Double(beat - 1) + offset) * 4 / Double(meter.denominator) * Double(division)).rounded())
    }

    private func eventTick(_ event: PerformanceEvent, section: SectionDefinition? = nil) -> Int {
        if let musical = event.at.musical {
            let beat = musical.beat ?? 1
            let offset = rational(musical.offset) ?? 0
            let quarterBeats: Double
            if let section {
                let preceding = musical.measure > 1 ? (1..<musical.measure).reduce(0.0) { total, measure in
                    let meter = meter(for: measure, in: section)
                    return total + Double(meter.numerator) * 4 / Double(meter.denominator)
                } : 0
                let activeMeter = meter(for: musical.measure, in: section)
                quarterBeats = preceding + (Double(beat - 1) + offset) * 4 / Double(activeMeter.denominator)
            } else {
                quarterBeats = Double(musical.measure - 1) * Double(numerator) * 4 / Double(denominator)
                    + (Double(beat - 1) + offset) * 4 / Double(denominator)
            }
            return max(0, Int((quarterBeats * Double(division)).rounded()))
        }
        if let absolute = event.at.absolute {
            let seconds = absolute.unit == "ms" ? absolute.value / 1000 : absolute.value
            return max(0, Int((seconds * bpm / 60 * Double(division)).rounded()))
        }
        return 0
    }

    private func durationTicks(_ event: PerformanceEvent) -> Int {
        guard let duration = event.duration else { return defaultDuration() }
        if let quarterNotes = rational(duration.quarterNotes) {
            return max(1, Int((quarterNotes * Double(division)).rounded()))
        }
        if let value = duration.value {
            let seconds = duration.unit == "ms" ? value / 1000 : value
            return max(1, Int((seconds * bpm / 60 * Double(division)).rounded()))
        }
        return defaultDuration()
    }

    private func defaultDuration() -> Int {
        Int(Double(division) * 0.45)
    }

    private func meter(for measure: Int, in section: SectionDefinition) -> MeterChange {
        let fallback = MeterChange(at: nil, numerator: numerator, denominator: denominator)
        return (section.meterMap ?? [])
            .filter { meter in
                guard case .number(let start)? = meter.at?["measure"] else { return false }
                return Int(start) <= measure
            }
            .last ?? fallback
    }

    private func addNote(
        _ output: inout [MIDIMessage],
        tick: Int,
        duration: Int,
        channel: Int,
        note: Int,
        velocity: Int
    ) {
        let safeNote = UInt8(clamping: note)
        output.append(MIDIMessage(
            tick: tick,
            priority: 2,
            bytes: [UInt8(0x90 | channel), safeNote, UInt8(clamping: velocity)]
        ))
        output.append(MIDIMessage(
            tick: tick + max(1, duration),
            priority: 1,
            bytes: [UInt8(0x80 | channel), safeNote, 0]
        ))
    }

    private func stringNote(
        index: Int,
        tuning: [PitchValue],
        order: String,
        fret: Int,
        ratio: Double?
    ) -> Int? {
        guard !tuning.isEmpty else { return nil }
        let tuningIndex = order == "highest-to-lowest" ? tuning.count - index : index - 1
        guard tuning.indices.contains(tuningIndex), let base = midiNote(tuning[tuningIndex]) else {
            return nil
        }
        if let ratio, ratio >= 0, ratio < 1 {
            return base + Int((-12 * log2(1 - ratio)).rounded())
        }
        return base + fret
    }

    private func collectMemberPitches(_ profile: InstrumentProfile) -> [String: Int] {
        var result: [String: Int] = [:]
        for (group, actuator) in profile.actuators ?? [:] {
            for member in actuator.members ?? [] {
                if let pitch = member.pitch, let note = midiNote(pitch) {
                    let encoded = try? JSONEncoder().encode(member.id)
                    let quoted = encoded.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\(member.id)\""
                    result["\(group)[\(quoted)]"] = note
                }
            }
        }
        return result
    }

    private func bitsetPitches(
        profile: InstrumentProfile,
        group: String,
        value: JSONValue
    ) -> [String: Int]? {
        guard let value = object(value),
              string(value["encoding"]) == "hex",
              let text = string(value["data"]),
              text.lowercased().hasPrefix("0x"),
              let mask = UInt64(text.dropFirst(2), radix: 16),
              let bits = profile.actuators?[group]?.bits else {
            return nil
        }

        var result: [String: Int] = [:]
        for bit in bits where (0..<64).contains(bit.index)
            && mask & (UInt64(1) << UInt64(bit.index)) != 0 {
            for effect in bit.effects ?? [] {
                if let pitch = effect.pitch, let note = midiNote(pitch) {
                    result[effect.target] = note
                }
            }
        }
        return result
    }

    private func targetIndex(_ target: String, group: String) -> Int? {
        guard target.hasPrefix("\(group)["), target.hasSuffix("]") else { return nil }
        return Int(target.dropFirst(group.count + 1).dropLast())
    }

    private func targetRange(_ target: String, group: String) -> [Int] {
        guard target.hasPrefix("\(group)["), target.hasSuffix("]") else { return [] }
        let body = String(target.dropFirst(group.count + 1).dropLast())
        let parts = body.components(separatedBy: "..")
        if parts.count == 2, let first = Int(parts[0]), let last = Int(parts[1]) {
            return first <= last ? Array(first...last) : Array((last...first).reversed())
        }
        return Int(body).map { [$0] } ?? []
    }

    private func velocity(_ parameters: [String: JSONValue]) -> Int {
        let intensity = min(1, max(0, double(parameters["intensity"]) ?? 0.7))
        return max(1, Int((intensity * 127).rounded()))
    }

    private func drumNote(_ target: String) -> Int? {
        guard let parsed = try? ActuatorTarget(parsing: target),
              case .member(let member) = parsed.selector,
              parsed.groupPath == "surfaces" else { return nil }
        return ["kick": 36, "snare-head": 38, "closed-hi-hat": 42, "crash": 49][member]
    }

    private func generalMIDIProgram(_ documentedProgram: Int) -> Int {
        min(128, max(1, documentedProgram)) - 1
    }

    private func string(_ value: JSONValue?) -> String? {
        guard case .string(let value) = value else { return nil }
        return value
    }

    private func int(_ value: JSONValue?) -> Int? {
        guard case .number(let value) = value, value.rounded() == value else { return nil }
        return Int(value)
    }

    private func double(_ value: JSONValue?) -> Double? {
        switch value {
        case .number(let value): value
        case .string(let value): Double(value)
        default: nil
        }
    }

    private func bool(_ value: JSONValue?) -> Bool? {
        guard case .boolean(let value) = value else { return nil }
        return value
    }

    private func object(_ value: JSONValue?) -> [String: JSONValue]? {
        guard case .object(let value) = value else { return nil }
        return value
    }

    private func stringArray(_ value: JSONValue?) -> [String]? {
        guard case .array(let values) = value else { return nil }
        let strings = values.compactMap(string)
        return strings.count == values.count ? strings : nil
    }

    private func pitchArray(_ value: JSONValue?) -> [PitchValue]? {
        guard case .array(let values) = value else { return nil }
        let pitches = values.compactMap(pitchValue)
        return pitches.count == values.count ? pitches : nil
    }

    private func pitchValue(_ value: JSONValue?) -> PitchValue? {
        guard let value, let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONDecoder().decode(PitchValue.self, from: data)
    }

    private func midiNote(_ pitch: PitchValue) -> Int? {
        if let legacy = pitch.legacyName { return Pitch.midiNote(legacy) }
        if let frequency = pitch.frequencyHz, frequency > 0 {
            return quantizeMIDI(69 + 12 * log2(frequency / 440))
        }
        guard let tuningID = pitch.tuning, let definition = tunings[tuningID], let period = pitch.period else { return nil }
        let degree = pitch.degree ?? pitch.name.flatMap { definition.names?[$0] }
        guard let degree, let periodRatio = ratio(definition.periodRatio) else { return nil }
        let reference = definition.reference
        let frequency: Double
        if definition.type == "equalDivision", let divisions = definition.divisions, divisions > 0 {
            let steps = (period - reference.pitch.period) * divisions + degree - reference.pitch.degree
            frequency = reference.frequencyHz * pow(periodRatio, Double(steps) / Double(divisions))
        } else if definition.type == "ratioScale", let degrees = definition.degrees,
                  degrees.indices.contains(degree), degrees.indices.contains(reference.pitch.degree),
                  let currentRatio = ratio(degrees[degree]), let referenceRatio = ratio(degrees[reference.pitch.degree]) {
            frequency = reference.frequencyHz * currentRatio / referenceRatio * pow(periodRatio, Double(period - reference.pitch.period))
        } else { return nil }
        return quantizeMIDI(69 + 12 * log2(frequency / 440))
    }

    private func quantizeMIDI(_ value: Double) -> Int {
        let rounded = value.rounded()
        if abs(value - rounded) > 0.000_001 {
            diagnostics.append("pitch \(value) requires MIDI 1 pitch quantization to note \(Int(rounded))")
        }
        return Int(rounded)
    }

    private func ratio(_ text: String) -> Double? {
        let parts = text.split(separator: "/")
        guard parts.count == 2, let numerator = Double(parts[0]), let denominator = Double(parts[1]), denominator > 0 else { return nil }
        return numerator / denominator
    }

    private func rational(_ value: JSONValue?) -> Double? {
        if let number = double(value) { return number }
        guard let text = string(value) else { return nil }
        let parts = text.split(separator: "/")
        if parts.count == 2,
           let numerator = Double(parts[0]),
           let denominator = Double(parts[1]), denominator != 0 {
            return numerator / denominator
        }
        return Double(text)
    }
}
