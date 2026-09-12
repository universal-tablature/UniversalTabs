import Foundation

/// Experimental interchange for the MNX 1.0 draft.
///
/// MNX is still evolving. This implementation deliberately accepts only documents whose
/// `mnx.version` is `1` and does not claim compatibility with a future final specification.
public enum MNXDraft1Interchange {
    public static let notice = "MNX draft 1.0 support is experimental and does not target a final MNX specification."

    public static func importDocument(_ data: Data) throws -> MusicXMLResult {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mnx = root["mnx"] as? [String: Any],
              let version = mnx["version"] as? Int else {
            throw MusicXMLError.malformed("expected an MNX document with an integer mnx.version")
        }
        guard version == 1 else {
            throw MusicXMLError.unsupported("MNX version \(version); this tool supports only the MNX 1.0 draft")
        }
        guard let global = root["global"] as? [String: Any],
              let globalMeasures = global["measures"] as? [[String: Any]],
              let parts = root["parts"] as? [[String: Any]] else {
            throw MusicXMLError.malformed("MNX draft 1.0 requires global.measures and parts")
        }

        let initialTime = globalMeasures.first?["time"] as? [String: Any]
        let numerator = initialTime?["count"] as? Int ?? 4
        let denominator = initialTime?["unit"] as? Int ?? 4
        var tracks: [[String: Any]] = []
        var diagnostics = [notice]

        for (partIndex, part) in parts.enumerated() {
            guard let measures = part["measures"] as? [[String: Any]] else {
                diagnostics.append("part \(partIndex + 1): omitted because it has no measures")
                continue
            }
            var events: [[String: Any]] = []
            for (measureIndex, measure) in measures.enumerated() {
                let sequences = measure["sequences"] as? [[String: Any]] ?? []
                for (sequenceIndex, sequence) in sequences.enumerated() {
                    var cursor = 0.0
                    let content = sequence["content"] as? [[String: Any]] ?? []
                    for item in content {
                        if item["type"] as? String == "grace" {
                            for graceEvent in item["content"] as? [[String: Any]] ?? [] {
                                append(event: graceEvent, measure: measureIndex + 1, cursor: cursor, type: "grace", to: &events, diagnostics: &diagnostics)
                            }
                            continue
                        }
                        let duration = quarterNotes(item["duration"] as? [String: Any])
                        append(event: item, measure: measureIndex + 1, cursor: cursor, type: nil, to: &events, diagnostics: &diagnostics)
                        cursor += duration
                    }
                    if sequenceIndex > 0 {
                        diagnostics.append("part \(partIndex + 1), measure \(measureIndex + 1): imported sequence \(sequenceIndex + 1) as a separate UTAB voice")
                    }
                }
            }
            tracks.append([
                "id": "track-\(partIndex + 1)",
                "name": part["name"] as? String ?? "Part \(partIndex + 1)",
                "instrument": "instrument-\(partIndex + 1)",
                "events": events,
            ])
        }

        let instruments = tracks.indices.map { ["id": "instrument-\($0 + 1)", "profile": "profile:mnx-draft-1"] }
        let document: [String: Any] = [
            "utab": ["version": "0.1-draft", "title": "MNX draft 1.0 import"],
            "setup": [
                "profiles": [["id": "profile:mnx-draft-1", "actuators": ["notes": [:]], "interactions": ["play": [:]]]],
                "instruments": instruments,
                "time": ["meter": ["numerator": numerator, "denominator": denominator]],
            ],
            "tracks": tracks,
        ]
        return MusicXMLResult(data: try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys]), diagnostics: diagnostics)
    }

    public static func exportDocument(_ data: Data) throws -> MusicXMLResult {
        let document = try JSONDecoder().decode(UTabDocument.self, from: data)
        let meter = document.setup.time?.meter
        let count = meter?.numerator ?? 4
        let unit = meter?.denominator ?? 4
        let expanded = document.tracks.map { MusicXMLInterchange.expandedEvents(for: $0, setup: document.setup) }
        let measureCount = max(1, expanded.flatMap { $0 }.compactMap { $0.at.musical?.measure }.max() ?? 1)
        var diagnostics = [notice]
        let globalMeasures: [[String: Any]] = (1...measureCount).map { measure in
            var value: [String: Any] = ["number": measure]
            if measure == 1 { value["time"] = ["count": count, "unit": unit] }
            return value
        }
        var parts: [[String: Any]] = []

        for (trackIndex, track) in document.tracks.enumerated() {
            let byMeasure = Dictionary(grouping: expanded[trackIndex]) { $0.at.musical?.measure ?? 1 }
            let measures: [[String: Any]] = (1...measureCount).map { measure in
                let orderedGroups = Dictionary(grouping: byMeasure[measure] ?? [], by: eventPosition)
                    .sorted { $0.key < $1.key }
                    .map(\.value)
                var content: [[String: Any]] = []
                for group in orderedGroups {
                    let relevant = group.filter { $0.type == "rest" || $0.action != nil || $0.gesture != nil }
                    guard let first = relevant.first else { continue }
                    if first.type == "grace" {
                        let graceEvents = relevant.compactMap { mnxEvent($0, diagnostics: &diagnostics) }
                        if !graceEvents.isEmpty { content.append(["type": "grace", "graceType": "stealFollowing", "content": graceEvents]) }
                    } else if let event = mnxEventGroup(relevant, diagnostics: &diagnostics) {
                        content.append(event)
                    }
                }
                return ["sequences": [["content": content]]]
            }
            parts.append(["name": track.name ?? track.id, "measures": measures])
        }

        let root: [String: Any] = [
            "_c": notice,
            "mnx": ["version": 1, "_c": "Draft 1.0; not the final MNX specification"],
            "global": ["measures": globalMeasures],
            "parts": parts,
        ]
        return MusicXMLResult(data: try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]), diagnostics: diagnostics)
    }

    private static func append(event: [String: Any], measure: Int, cursor: Double, type: String?, to output: inout [[String: Any]], diagnostics: inout [String]) {
        let duration = quarterNotes(event["duration"] as? [String: Any])
        let at: [String: Any] = ["musical": ["measure": measure, "beat": Int(floor(cursor)) + 1, "offset": decimal(cursor - floor(cursor))]]
        let common: [String: Any] = ["at": at, "duration": ["quarterNotes": decimal(duration)]]
        if event["rest"] != nil {
            var rest = common; rest["type"] = "rest"; output.append(rest); return
        }
        guard let notes = event["notes"] as? [[String: Any]], !notes.isEmpty else {
            diagnostics.append("measure \(measure): omitted MNX event without notes or rest")
            return
        }
        for note in notes {
            guard let pitch = note["pitch"] as? [String: Any], let step = pitch["step"] as? String, let octave = pitch["octave"] as? Int else { continue }
            let alter = pitch["alter"] as? Int ?? 0
            let accidental = alter > 0 ? String(repeating: "#", count: alter) : alter < 0 ? String(repeating: "b", count: -alter) : ""
            var value = common
            value["action"] = "play"; value["target"] = "notes"; value["parameters"] = ["pitch": "\(step)\(accidental)\(octave)"]
            if let type { value["type"] = type }
            output.append(value)
        }
    }

    private static func mnxEventGroup(_ events: [PerformanceEvent], diagnostics: inout [String]) -> [String: Any]? {
        guard let first = events.first else { return nil }
        if first.type == "rest" { return ["type": "event", "duration": noteValue(first.duration), "rest": [:]] }
        let notes = events.compactMap { mnxNote($0) }
        if notes.isEmpty { diagnostics.append("omitted UTAB event without a 12-EDO pitch"); return nil }
        return ["type": "event", "duration": noteValue(first.duration), "notes": notes]
    }

    private static func mnxEvent(_ event: PerformanceEvent, diagnostics: inout [String]) -> [String: Any]? {
        mnxEventGroup([event], diagnostics: &diagnostics)
    }

    private static func mnxNote(_ event: PerformanceEvent) -> [String: Any]? {
        guard let value = event.parameters?["pitch"] else { return nil }
        if case .object(let p) = value, case .string(let tuning)? = p["tuning"], tuning == "12edo", case .number(let degree)? = p["degree"], case .number(let period)? = p["period"] {
            return note(degree: Int(degree), octave: Int(period))
        }
        guard case .string(let source) = value, let first = source.first,
              let octaveStart = source.dropFirst().firstIndex(where: { $0.isNumber || $0 == "-" }), let octave = Int(source[octaveStart...]) else { return nil }
        let accidental = source[source.index(after: source.startIndex)..<octaveStart]
        let alter = accidental.reduce(0) { $1 == "#" ? $0 + 1 : $1 == "b" ? $0 - 1 : $0 }
        var pitch: [String: Any] = ["step": String(first).uppercased(), "octave": octave]
        if alter != 0 { pitch["alter"] = alter }
        return ["pitch": pitch]
    }

    private static func note(degree: Int, octave: Int) -> [String: Any] {
        let names: [(String, Int)] = [("C",0),("C",1),("D",0),("E",-1),("E",0),("F",0),("F",1),("G",0),("G",1),("A",0),("B",-1),("B",0)]
        let index = ((degree % 12) + 12) % 12
        var pitch: [String: Any] = ["step": names[index].0, "octave": octave + Int(floor(Double(degree) / 12))]
        if names[index].1 != 0 { pitch["alter"] = names[index].1 }
        return ["pitch": pitch]
    }

    private static func noteValue(_ duration: EventDuration?) -> [String: Any] {
        let q = rational(duration?.quarterNotes)
        let values: [(Double, String, Int)] = [(16,"whole",2),(12,"whole",1),(8,"whole",1),(6,"half",1),(4,"whole",0),(3,"half",1),(2,"half",0),(1.5,"quarter",1),(1,"quarter",0),(0.75,"eighth",1),(0.5,"eighth",0),(0.25,"16th",0),(0.125,"32nd",0)]
        let closest = values.min { abs($0.0 - q) < abs($1.0 - q) } ?? (1,"quarter",0)
        var result: [String: Any] = ["base": closest.1]
        if closest.2 > 0 { result["dots"] = closest.2 }
        return result
    }

    private static func quarterNotes(_ value: [String: Any]?) -> Double {
        guard let base = value?["base"] as? String else { return 1 }
        let baseValue: Double = ["duplexMaxima":32,"maxima":16,"longa":8,"breve":8,"whole":4,"half":2,"quarter":1,"eighth":0.5,"16th":0.25,"32nd":0.125,"64th":0.0625][base] ?? 1
        let dots = value?["dots"] as? Int ?? 0
        return (0...dots).reduce(0.0) { $0 + baseValue / pow(2, Double($1)) }
    }

    private static func rational(_ value: JSONValue?) -> Double {
        if case .number(let number)? = value { return number }
        guard case .string(let source)? = value else { return 0 }
        let pieces = source.split(separator: "/")
        if pieces.count == 2, let numerator = Double(pieces[0]), let denominator = Double(pieces[1]), denominator != 0 { return numerator / denominator }
        return Double(source) ?? 0
    }

    private static func eventPosition(_ event: PerformanceEvent) -> Double {
        Double(event.at.musical?.beat ?? 1) + rational(event.at.musical?.offset)
    }

    private static func decimal(_ value: Double) -> String { String(format: "%.10g", value) }
}
