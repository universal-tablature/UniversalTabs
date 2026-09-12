import Foundation

public enum LilyPondInterchange {
    public static func exportDocument(_ data: Data) throws -> MusicXMLResult {
        let document = try JSONDecoder().decode(UTabDocument.self, from: data)
        var diagnostics: [String] = []
        var staves: [String] = []
        let instruments = Dictionary(document.setup.instruments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (trackIndex, track) in document.tracks.enumerated() {
            let events = MusicXMLInterchange.expandedEvents(for: track, setup: document.setup).sorted { position($0) < position($1) }
            let instrument = instruments[track.instrument]
            let isGuitar = instrument?.realization?.midi?.program == 25
                || instrument?.name?.localizedCaseInsensitiveContains("guitar") == true
            let isRhythmGuitar = isGuitar && (track.name?.localizedCaseInsensitiveContains("rhythm") == true)
            let eventGroups = Dictionary(grouping: events, by: position).sorted { $0.key < $1.key }.map(\.value)
            let tokens = eventGroups.compactMap { group -> String? in
                let musicalEvents = group.filter { $0.type == "rest" || $0.action != nil || $0.gesture != nil }
                guard let first = musicalEvents.first else { return nil }
                let duration = durationToken(first.duration)
                if first.type == "rest" { return "r\(duration)" }
                let pitches = musicalEvents.compactMap { pitchToken($0.parameters?["pitch"]) }
                guard !pitches.isEmpty else {
                    diagnostics.append("\(track.id): omitted event without a pitched LilyPond representation")
                    return nil
                }
                if first.type == "grace" { return "\\grace { \(pitches[0])16 }" }
                return pitches.count == 1 ? pitches[0] + duration : "<\(pitches.joined(separator: " "))>\(duration)"
            }
            let name = escaped(track.name ?? track.id)
            let voiceName = "utabVoice\(trackIndex + 1)"
            let clef = isRhythmGuitar ? "\\clef \"bass_8\" " : isGuitar ? "\\clef \"treble_8\" " : ""
            var staff = "\\new Staff \\with { instrumentName = \"\(name)\" } << \\new Voice = \"\(voiceName)\" { \(clef)\(tokens.joined(separator: " ")) } >>"
            let lyrics = lyricTokens(events)
            if !lyrics.isEmpty { staff += "\n    \\new Lyrics \\lyricsto \"\(voiceName)\" { \(lyrics.joined(separator: " ")) }" }
            staves.append(staff)
        }
        let title = escaped(document.utab.title ?? "Untitled")
        let source = """
        \\version "2.24.0"
        \\header { title = "\(title)" }
        \\score {
          <<
            \(staves.joined(separator: "\n    "))
          >>
          \\layout { }
        }

        """
        return MusicXMLResult(data: Data(source.utf8), diagnostics: diagnostics)
    }

    private static func position(_ event: PerformanceEvent) -> Double {
        guard let p = event.at.musical else { return 0 }
        return Double(p.measure * 1000 + (p.beat ?? 1)) + rational(p.offset) / 10
    }
    private static func durationToken(_ duration: EventDuration?) -> String {
        let quarters = rational(duration?.quarterNotes)
        return quarters == 1 ? "4" : "4*\(fraction(quarters))"
    }
    private static func pitchToken(_ value: JSONValue?, octaveOffset: Int = 0) -> String? {
        if case .object(let pitch)? = value,
           case .string(let tuning)? = pitch["tuning"], tuning == "12edo",
           case .number(let degreeValue)? = pitch["degree"],
           case .number(let periodValue)? = pitch["period"] {
            let degree = Int(degreeValue)
            let names = ["c", "cis", "d", "ees", "e", "f", "fis", "g", "gis", "a", "bes", "b"]
            let normalizedDegree = ((degree % 12) + 12) % 12
            let octave = Int(periodValue) + Int(floor(Double(degree) / 12.0)) + octaveOffset
            let marks = octave >= 3 ? String(repeating: "'", count: octave - 3) : String(repeating: ",", count: 3 - octave)
            return names[normalizedDegree] + marks
        }
        guard case .string(let value)? = value, let letter = value.first else { return nil }
        let tail = value.dropFirst()
        guard let octaveStart = tail.firstIndex(where: { $0.isNumber || $0 == "-" }), let sourceOctave = Int(tail[octaveStart...]) else { return nil }
        let octave = sourceOctave + octaveOffset
        let accidental = tail[..<octaveStart].map { $0 == "#" ? "is" : $0 == "b" ? "es" : "" }.joined()
        let marks = octave >= 3 ? String(repeating: "'", count: octave - 3) : String(repeating: ",", count: 3 - octave)
        return String(letter).lowercased() + accidental + marks
    }
    private static func lyricTokens(_ events: [PerformanceEvent]) -> [String] {
        let hasLyrics = events.contains { event in
            if case .array(let lyrics)? = event.parameters?["_lyrics"] { return !lyrics.isEmpty }
            return false
        }
        guard hasLyrics else { return [] }
        return events.flatMap { event -> [String] in
            guard case .array(let lyrics)? = event.parameters?["_lyrics"],
                  case .object(let lyric)? = lyrics.first,
                  case .string(let text)? = lyric["text"] else { return ["_"] }
            var result = ["\"\(escaped(text))\""]
            if case .string(let position)? = lyric["position"], position == "beginning" || position == "middle" { result.append("--") }
            return result
        }
    }
    private static func rational(_ value: JSONValue?) -> Double {
        if case .number(let n)? = value { return n }
        guard case .string(let s)? = value else { return 0 }
        let p = s.split(separator: "/"); if p.count == 2, let a = Double(p[0]), let b = Double(p[1]), b != 0 { return a / b }
        return Double(s) ?? 0
    }
    private static func fraction(_ value: Double) -> String {
        for d in 1...64 { let n = Int((value * Double(d)).rounded()); if abs(Double(n) / Double(d) - value) < 0.000001 { return "\(n)/\(d)" } }
        return String(format: "%.6g", value)
    }
    private static func escaped(_ value: String) -> String { value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
}
