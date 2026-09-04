import Foundation
import UniversalTabs
import UTABComposerCore

public struct UTABTimedNoteEdit: Sendable, Equatable {
    public let id: String
    public let midiPitch: Int
    public let startBeat: Double
    public let durationBeats: Double
    public let pitchText: String?

    public init(
        id: String,
        midiPitch: Int,
        startBeat: Double,
        durationBeats: Double,
        pitchText: String? = nil
    ) {
        self.id = id
        self.midiPitch = midiPitch
        self.startBeat = startBeat
        self.durationBeats = durationBeats
        self.pitchText = pitchText
    }
}

public enum UTABMeasureSourceEditor {
    public static func rewriteBar(
        in source: String,
        range: SourceRange,
        notes: [UTABTimedNoteEdit],
        beatsPerMeasure: Double,
        explicitBar: Bool = true
    ) throws -> UTABSourceEdit {
        guard let authoredRange = stringRange(for: range, in: source) else {
            throw UTABSourceEditingError.invalidSourceRange(range)
        }
        let sourceRange = explicitBar ? authoredRange : enclosingParenthesizedRange(authoredRange, in: source)
        let lanes = partition(notes.sorted {
            $0.startBeat == $1.startBeat ? $0.id < $1.id : $0.startBeat < $1.startBeat
        })
        let indent = indentation(at: sourceRange.lowerBound, in: source)
        let sequenceIndent = explicitBar ? indent + "    " : indent
        let renderedLanes = try lanes.map { lane in
            let expressions = try render(lane: lane, length: beatsPerMeasure)
            return "(" + expressions.joined(separator: "; ") + ")"
        }
        let lanesText = renderedLanes.joined(separator: ", ")
        let replacement = explicitBar
            ? "bar {\n" + sequenceIndent + lanesText + "\n" + indent + "}"
            : lanesText
        let updated = source.replacingCharacters(in: sourceRange, with: replacement)
        let start = position(of: sourceRange.lowerBound, in: source)
        return UTABSourceEdit(
            source: updated,
            replacementRange: SourceRange(fileID: range.fileID, start: start),
            replacement: replacement,
            representationChange: .preserved
        )
    }

    private static func partition(_ notes: [UTABTimedNoteEdit]) -> [[UTABTimedNoteEdit]] {
        var lanes: [[UTABTimedNoteEdit]] = []
        var laneEnds: [Double] = []
        for note in notes {
            if let index = laneEnds.firstIndex(where: { $0 <= note.startBeat + 0.000_001 }) {
                lanes[index].append(note)
                laneEnds[index] = note.startBeat + note.durationBeats
            } else {
                lanes.append([note])
                laneEnds.append(note.startBeat + note.durationBeats)
            }
        }
        return lanes
    }

    private static func render(lane: [UTABTimedNoteEdit], length: Double) throws -> [String] {
        var result: [String] = []
        var cursor = 0.0
        for note in lane {
            result += try rests(for: note.startBeat - cursor)
            guard let duration = UTABDurationSourceEditor.durationToken(for: note.durationBeats) else {
                throw UTABSourceEditingError.unsupportedDuration(note.durationBeats)
            }
            let pitch = note.pitchText ?? UTABPitchSourceEditor.pitchName(for: note.midiPitch)
            result.append("\(pitch) \(duration)")
            cursor = note.startBeat + note.durationBeats
        }
        result += try rests(for: length - cursor)
        return result
    }

    private static func rests(for beats: Double) throws -> [String] {
        guard beats >= -0.000_001 else { throw UTABSourceEditingError.unsupportedDuration(beats) }
        var remaining = max(0, beats)
        var result: [String] = []
        for (value, token) in [(4.0, "w"), (2.0, "h"), (1.0, "q"), (0.5, "e"), (0.25, "s")] {
            while remaining + 0.000_001 >= value {
                result.append("_ \(token)")
                remaining -= value
            }
        }
        guard remaining < 0.000_001 else { throw UTABSourceEditingError.unsupportedDuration(beats) }
        return result
    }

    private static func enclosingParenthesizedRange(
        _ initialRange: Range<String.Index>,
        in source: String
    ) -> Range<String.Index> {
        var result = initialRange
        while true {
            var lower = result.lowerBound
            while lower > source.startIndex {
                let previous = source.index(before: lower)
                guard source[previous].isWhitespace, source[previous] != "\n" else { break }
                lower = previous
            }
            guard lower > source.startIndex else { break }
            let open = source.index(before: lower)
            guard source[open] == "(" else { break }

            var upper = result.upperBound
            while upper < source.endIndex, source[upper].isWhitespace, source[upper] != "\n" {
                upper = source.index(after: upper)
            }
            guard upper < source.endIndex, source[upper] == ")" else { break }
            result = open..<source.index(after: upper)
        }
        return result
    }

    private static func stringRange(for range: SourceRange, in source: String) -> Range<String.Index>? {
        guard let end = range.end,
              let lower = index(at: range.start, in: source),
              let upper = index(at: end, in: source),
              lower <= upper else { return nil }
        return lower..<upper
    }

    private static func index(at position: SourcePosition, in source: String) -> String.Index? {
        guard position.line > 0, position.column > 0 else { return nil }
        var lineStart = source.startIndex
        for _ in 1..<position.line {
            guard let newline = source[lineStart...].firstIndex(of: "\n") else { return nil }
            lineStart = source.index(after: newline)
        }
        let lineEnd = source[lineStart...].firstIndex(of: "\n") ?? source.endIndex
        return source.index(lineStart, offsetBy: position.column - 1, limitedBy: lineEnd)
    }

    private static func indentation(at index: String.Index, in source: String) -> String {
        let lineStart = source[..<index].lastIndex(of: "\n").map { source.index(after: $0) } ?? source.startIndex
        return String(source[lineStart..<index].prefix { $0 == " " || $0 == "\t" })
    }

    private static func position(of target: String.Index, in source: String) -> SourcePosition {
        let prefix = source[..<target]
        let line = prefix.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        let lineStart = prefix.lastIndex(of: "\n").map { source.index(after: $0) } ?? source.startIndex
        return SourcePosition(line: line, column: source.distance(from: lineStart, to: target) + 1)
    }
}
