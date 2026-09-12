import Foundation

public struct UTabComposerDecompilationResult: Sendable {
    public let source: String
    public let diagnostics: [String]
}

/// Loss-aware intermediate representation between realized UTAB events and composer syntax.
public struct UTabComposerSourceIR: Sendable {
    public struct Part: Sendable {
        public let identifier: String
        public let displayName: String
        public let bars: [Bar]
    }

    public struct Bar: Sendable {
        public let number: Int
        public let expressions: [Expression]
    }

    public indirect enum Expression: Sendable {
        case note(pitch: String, duration: Duration)
        case rest(duration: Duration, insertedForGap: Bool)
        case simultaneous([Expression])
        case grace(policy: GracePolicy, expressions: [Expression])
    }

    public enum GracePolicy: String, Sendable { case measured, stealFollowing, beforeBeat }

    public struct Duration: Sendable {
        public let quarterNotes: Double
    }

    public let moduleName: String
    public let title: String
    public let meterNumerator: Int
    public let meterDenominator: Int
    public let tempo: Double
    public let barCount: Int
    public let parts: [Part]
}

/// Reconstructs standalone UTAB composer source from a realized UTAB JSON document.
public enum UTabComposerDecompiler {
    public static func decompile(_ data: Data) throws -> UTabComposerDecompilationResult {
        try decompile(JSONDecoder().decode(UTabDocument.self, from: data))
    }

    public static func decompile(_ document: UTabDocument) throws -> UTabComposerDecompilationResult {
        var diagnostics: [String] = []
        let ir = lower(document, diagnostics: &diagnostics)
        return .init(source: UTabComposerSourceRenderer.render(ir), diagnostics: diagnostics)
    }

    /// Lowers realized events without making source-layout decisions.
    public static func lower(_ document: UTabDocument, diagnostics: inout [String]) -> UTabComposerSourceIR {
        let meter = document.setup.time?.meter
        let expanded = document.tracks.map { MusicXMLInterchange.expandedEvents(for: $0, setup: document.setup) }
        let barCount = max(1, expanded.flatMap { $0 }.compactMap { $0.at.musical?.measure }.max() ?? 1)
        var usedNames: Set<String> = []
        var parts: [UTabComposerSourceIR.Part] = []

        for (trackIndex, track) in document.tracks.enumerated() {
            let baseName = identifier(track.name ?? track.id, fallback: "part\(trackIndex + 1)")
            var name = baseName
            var suffix = 2
            while usedNames.contains(name) { name = "\(baseName)_\(suffix)"; suffix += 1 }
            usedNames.insert(name)
            let byMeasure = Dictionary(grouping: expanded[trackIndex]) { $0.at.musical?.measure ?? 1 }
            var bars: [UTabComposerSourceIR.Bar] = []

            for measure in 1...barCount {
                var cursor = 0.0
                var expressions: [UTabComposerSourceIR.Expression] = []
                let groups = Dictionary(grouping: byMeasure[measure] ?? [], by: position).sorted { $0.key < $1.key }
                for (eventPosition, group) in groups {
                    if eventPosition > cursor + 0.000_001 {
                        expressions.append(.rest(duration: .init(quarterNotes: eventPosition - cursor), insertedForGap: true))
                        cursor = eventPosition
                    }
                    let events = group.filter { $0.type == "rest" || $0.action != nil || $0.gesture != nil }
                    guard let first = events.first else { continue }
                    let length = quarterNotes(first.duration?.quarterNotes)
                    if first.type == "rest" {
                        expressions.append(.rest(duration: .init(quarterNotes: length), insertedForGap: false))
                        cursor = max(cursor, eventPosition + length)
                        continue
                    }
                    let notes: [UTabComposerSourceIR.Expression] = events.compactMap { event in
                        guard let value = pitch(event.parameters?["pitch"]) else { return nil }
                        return .note(pitch: value, duration: .init(quarterNotes: quarterNotes(event.duration?.quarterNotes)))
                    }
                    guard !notes.isEmpty else {
                        diagnostics.append("\(track.name ?? track.id): omitted event at measure \(measure), beat \(number(eventPosition + 1)) without a representable pitch")
                        continue
                    }
                    let grouped: UTabComposerSourceIR.Expression = notes.count == 1 ? notes[0] : .simultaneous(notes)
                    if isGrace(first) {
                        expressions.append(.grace(policy: .measured, expressions: [grouped]))
                        cursor = max(cursor, eventPosition + length)
                    } else {
                        expressions.append(grouped)
                        cursor = max(cursor, eventPosition + length)
                    }
                }
                bars.append(.init(number: measure, expressions: expressions))
            }
            parts.append(.init(identifier: name, displayName: track.name ?? track.id, bars: bars))
        }

        return .init(
            moduleName: "generated.decompiled",
            title: document.utab.title ?? "Untitled",
            meterNumerator: meter?.numerator ?? 4,
            meterDenominator: meter?.denominator ?? 4,
            tempo: document.setup.time?.tempo?.quarterNotesPerMinute ?? 120,
            barCount: barCount,
            parts: parts
        )
    }

    private static func position(_ event: PerformanceEvent) -> Double {
        Double((event.at.musical?.beat ?? 1) - 1) + quarterNotes(event.at.musical?.offset)
    }

    private static func isGrace(_ event: PerformanceEvent) -> Bool {
        if event.type == "grace" || event.techniques?.contains("grace") == true { return true }
        if case .boolean(true)? = event.parameters?["grace"] { return true }
        return false
    }

    fileprivate static func quarterNotes(_ value: JSONValue?) -> Double {
        if case .number(let value)? = value { return value }
        guard case .string(let source)? = value else { return 0 }
        let pieces = source.split(separator: "/")
        if pieces.count == 2, let a = Double(pieces[0]), let b = Double(pieces[1]), b != 0 { return a / b }
        return Double(source) ?? 0
    }

    private static func pitch(_ value: JSONValue?) -> String? {
        if case .string(let source)? = value { return validPitch(source) ? source : nil }
        guard case .object(let value)? = value else { return nil }
        if case .string(let legacy)? = value["legacyName"] { return validPitch(legacy) ? legacy : nil }
        if case .string(let name)? = value["name"], case .number(let period)? = value["period"] { return "\(name)\(Int(period))" }
        guard case .string(let tuning)? = value["tuning"], tuning == "12edo", case .number(let degreeValue)? = value["degree"], case .number(let periodValue)? = value["period"] else { return nil }
        let spellings = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]
        let degree = Int(degreeValue), index = ((degree % 12) + 12) % 12
        return "\(spellings[index])\(Int(periodValue) + Int(floor(Double(degree) / 12)))"
    }

    private static func validPitch(_ value: String) -> Bool {
        guard let first = value.first, "ABCDEFGabcdefg".contains(first) else { return false }
        return value.contains(where: \.isNumber)
    }

    private static func identifier(_ value: String, fallback: String) -> String {
        var result = value.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "_" ? Character(String($0)) : "_" }
        if result.isEmpty { return fallback }
        if result[0].isNumber { result.insert("_", at: 0) }
        let joined = String(result)
        return joined.allSatisfy { $0 == "_" } ? fallback : joined
    }

    fileprivate static func number(_ value: Double) -> String { String(format: "%.10g", value) }
}

/// The only stage that knows concrete composer-language spelling and whitespace.
public enum UTabComposerSourceRenderer {
    public static func render(_ document: UTabComposerSourceIR) -> String {
        var lines = [
            "// Decompiled from realized UTAB JSON.",
            "// Generated names and structure may differ from the original composer source.",
            "module \(document.moduleName)", "",
            "title \(quoted(document.title))",
            "meter \(document.meterNumerator)/\(document.meterDenominator)",
            "tempo \(UTabComposerDecompiler.number(document.tempo))", "",
            "profile DecompiledNotes {",
            "    id \"profile:utab-decompiled-notes\"", "    version \"1\"", "    actuator notes",
            "    interaction play { targets notes }", "}", "",
            "model DecompiledInstrument : DecompiledNotes {",
            "    id \"instrument:utab-decompiled\"", "    name \"Decompiled instrument\"", "}", "",
        ]
        for part in document.parts { lines.append("instrument \(part.identifier) : DecompiledInstrument as \(quoted(part.displayName))") }
        for part in document.parts {
            lines += ["", "phrase \(part.identifier)_material {"]
            for bar in part.bars {
                lines.append("    bar {")
                for expression in bar.expressions { lines.append("        \(render(expression))") }
                lines.append("    }")
            }
            lines.append("}")
        }
        lines += ["", "section imported : \(document.barCount) bars {"]
        for (index, part) in document.parts.enumerated() {
            lines += ["    \(part.identifier) {", "        voice importedVoice\(index + 1) { \(part.identifier)_material }", "    }"]
        }
        lines += ["}", "", "main { imported }", ""]
        return lines.joined(separator: "\n")
    }

    private static func render(_ expression: UTabComposerSourceIR.Expression) -> String {
        switch expression {
        case .note(let pitch, let duration): return "\(pitch) \(render(duration))"
        case .rest(let duration, _): return "rest \(render(duration))"
        case .simultaneous(let expressions): return expressions.map(render).joined(separator: ", ")
        case .grace(let policy, let expressions): return "grace \(policy.rawValue) { \(expressions.map(render).joined(separator: ", ")) }"
        }
    }

    private static func render(_ duration: UTabComposerSourceIR.Duration) -> String {
        let q = duration.quarterNotes
        let named: [(Double, String)] = [(4,"w"),(3,"h."),(2,"h"),(1.5,"q."),(1,"q"),(0.75,"e."),(0.5,"e"),(0.25,"s")]
        if let match = named.first(where: { abs($0.0 - q) < 0.000_001 }) { return match.1 }
        let fraction = approximate(q / 4)
        return "[\(fraction.0)/\(fraction.1)]"
    }

    private static func approximate(_ value: Double) -> (Int, Int) {
        var best = (Int(value.rounded()), 1), error = abs(Double(Int(value.rounded())) - value)
        for denominator in 1...4096 {
            let numerator = Int((value * Double(denominator)).rounded()), candidate = abs(Double(numerator) / Double(denominator) - value)
            if candidate < error { best = (numerator, denominator); error = candidate }
            if candidate < 1e-10 { break }
        }
        let divisor = gcd(abs(best.0), best.1)
        return (best.0 / divisor, best.1 / divisor)
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        var x = a, y = b
        while y != 0 { (x, y) = (y, x % y) }
        return max(1, x)
    }

    private static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n") + "\""
    }
}
