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
    private let division = StandardMIDIFile.ticksPerQuarter
    private var diagnostics: [String] = []
    private var bpm = 120.0
    private var numerator = 4
    private var denominator = 4

    public init() {}

    public func convert(data: Data) throws -> ConversionResult {
        let document: UTabDocument
        do {
            document = try JSONDecoder().decode(UTabDocument.self, from: data)
        } catch {
            throw UTabConversionError.invalidDocument(error)
        }

        diagnostics = []
        bpm = 120
        numerator = 4
        denominator = 4
        readTime(document.setup.time)

        let profiles = Dictionary(uniqueKeysWithValues: document.setup.profiles.map { ($0.id, $0) })
        let instruments = Dictionary(uniqueKeysWithValues: document.setup.instruments.map { ($0.id, $0) })
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
                track,
                name: name,
                instrument: instrument,
                profile: profile,
                channel: index % 9
            ))
        }

        let conductor = StandardMIDIFile.conductorTrack(
            bpm: bpm,
            numerator: numerator,
            denominator: denominator
        )
        return ConversionResult(
            midi: StandardMIDIFile.make(conductor: conductor, tracks: midiTracks),
            diagnostics: diagnostics
        )
    }

    private func convertTrack(
        _ track: EventTrack,
        name: String,
        instrument: InstrumentInstance,
        profile: InstrumentProfile,
        channel: Int
    ) -> [MIDIMessage] {
        let profileName = profile.name ?? ""
        let isDrums = profileName.localizedCaseInsensitiveContains("drum kit")
        let midiChannel = isDrums ? 9 : channel
        var output = [StandardMIDIFile.trackName(name)]
        if !isDrums {
            output.append(MIDIMessage(
                tick: 0,
                priority: 0,
                bytes: [UInt8(0xC0 | midiChannel), UInt8(program(for: profileName))]
            ))
        }

        let tuning = stringArray(instrument.configuration?["tuning"])
            ?? stringArray(instrument.configuration?["melodyStringTuning"])
            ?? []
        let indexOrder = string(instrument.configuration?["stringIndexOrder"])
            ?? "lowest-to-highest"
        let directPitches = collectMemberPitches(profile)
        var frets: [Int: Int] = [:]
        var ratios: [Int: Double] = [:]
        var muted = Set<Int>()
        var pitchesFromBitsets: [String: Int] = [:]

        let sortedEvents = track.events.enumerated().sorted {
            let leftTick = eventTick($0.element)
            let rightTick = eventTick($1.element)
            return leftTick == rightTick ? $0.offset < $1.offset : leftTick < rightTick
        }

        for (_, event) in sortedEvents {
            let tick = eventTick(event)
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
            let target = string(event.target)
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

            guard let action, let target else { continue }
            if action == "pluck" || action == "bow" {
                let group = target.hasPrefix("melodyStrings") ? "melodyStrings" : "strings"
                let stringIndex = targetIndex(target, group: group)
                let note = pitchesFromBitsets[target] ?? stringIndex.flatMap {
                    stringNote(
                        index: $0,
                        tuning: tuning,
                        order: indexOrder,
                        fret: frets[$0] ?? 0,
                        ratio: ratios[$0]
                    )
                }
                if let index = stringIndex, !muted.contains(index), let note {
                    addNote(
                        &output,
                        tick: tick,
                        duration: durationTicks(event),
                        channel: midiChannel,
                        note: note,
                        velocity: velocity(parameters)
                    )
                } else {
                    diagnostics.append("\(name): could not resolve pitch for \(target) at tick \(tick)")
                }
            } else if action == "strike" {
                if isDrums, let note = drumNote(target) {
                    addNote(
                        &output,
                        tick: tick,
                        duration: defaultDuration() / 2,
                        channel: 9,
                        note: note,
                        velocity: velocity(parameters)
                    )
                } else if let note = directPitches[target] {
                    addNote(
                        &output,
                        tick: tick,
                        duration: durationTicks(event),
                        channel: midiChannel,
                        note: note,
                        velocity: velocity(parameters)
                    )
                } else {
                    diagnostics.append("\(name): could not resolve pitch for \(target) at tick \(tick)")
                }
            }
        }
        return output
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

    private func eventTick(_ event: PerformanceEvent) -> Int {
        if let musical = event.at.musical {
            let beat = rational(musical.beat) ?? 1
            let quarterBeats = Double(musical.measure - 1) * Double(numerator) * 4 / Double(denominator)
                + (beat - 1) * 4 / Double(denominator)
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
        if let musical = rational(duration.musical) {
            return max(1, Int((musical * Double(division)).rounded()))
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
        tuning: [String],
        order: String,
        fret: Int,
        ratio: Double?
    ) -> Int? {
        guard !tuning.isEmpty else { return nil }
        let tuningIndex = order == "highest-to-lowest" ? tuning.count - index : index - 1
        guard tuning.indices.contains(tuningIndex), let base = Pitch.midiNote(tuning[tuningIndex]) else {
            return nil
        }
        if let ratio, ratio >= 0, ratio < 1 {
            return base + Int((-12 * log2(1 - ratio)).rounded())
        }
        return base + fret
    }

    private func collectMemberPitches(_ profile: InstrumentProfile) -> [String: Int] {
        var result: [String: Int] = [:]
        for actuator in profile.actuators?.values ?? Dictionary<String, ActuatorDefinition>().values {
            for member in actuator.members ?? [] {
                if let pitch = member.pitch, let note = Pitch.midiNote(pitch) {
                    result[member.id] = note
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
                if let pitch = effect.pitch, let note = Pitch.midiNote(pitch) {
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
        ["kick": 36, "snare-head": 38, "closed-hi-hat": 42, "crash": 49][target]
    }

    private func program(for profileName: String) -> Int {
        let name = profileName.lowercased()
        if name.contains("guitar") { return generalMIDIProgram(26) }
        if name.contains("cello") { return generalMIDIProgram(43) }
        if name.contains("xylophone") { return generalMIDIProgram(14) }
        if name.contains("handpan") { return generalMIDIProgram(115) }
        if name.contains("nyckelharpa") { return generalMIDIProgram(111) }
        return generalMIDIProgram(1)
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
