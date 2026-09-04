import Foundation
import UTABComposerCore

public struct UTABSourceEdit: Sendable, Equatable {
    public enum RepresentationChange: Sendable, Equatable {
        case preserved
        case normalizedToAbsolutePitch
    }

    public let source: String
    public let replacementRange: SourceRange
    public let replacement: String
    public let representationChange: RepresentationChange

    public init(
        source: String,
        replacementRange: SourceRange,
        replacement: String,
        representationChange: RepresentationChange
    ) {
        self.source = source
        self.replacementRange = replacementRange
        self.replacement = replacement
        self.representationChange = representationChange
    }
}

public enum UTABSourceEditingError: Error, Sendable, Equatable, LocalizedError {
    case invalidMIDIPitch(Int)
    case invalidSourceRange(SourceRange)
    case pitchNotFound(SourceRange)
    case unsupportedDuration(Double)
    case durationNotFound(SourceRange)

    public var errorDescription: String? {
        switch self {
        case .invalidMIDIPitch(let pitch):
            "MIDI pitch \(pitch) is outside the supported 0...127 range."
        case .invalidSourceRange:
            "The authored source range is missing or no longer matches the document."
        case .pitchNotFound:
            "No editable pitch was found in the authored source range."
        case .unsupportedDuration(let beats):
            "The duration \(beats) beats cannot be represented by the current notation."
        case .durationNotFound:
            "No editable duration was found in the authored source range."
        }
    }
}

public enum UTABDurationSourceEditor {
    public static func setDuration(
        in source: String,
        range: SourceRange,
        durationBeats: Double
    ) throws -> UTABSourceEdit {
        guard let token = durationToken(for: durationBeats) else {
            throw UTABSourceEditingError.unsupportedDuration(durationBeats)
        }
        guard let sourceRange = UTABPitchSourceEditor.stringRange(for: range, in: source) else {
            throw UTABSourceEditingError.invalidSourceRange(range)
        }

        let expression = String(source[sourceRange])
        let regex = try NSRegularExpression(pattern: #"\b(w|h|q|e|s)\b"#)
        let fullRange = NSRange(expression.startIndex..., in: expression)
        guard let match = regex.matches(in: expression, range: fullRange).last,
              let localRange = Range(match.range, in: expression) else {
            throw UTABSourceEditingError.durationNotFound(range)
        }

        let offset = expression.distance(from: expression.startIndex, to: localRange.lowerBound)
        let replacementStart = source.index(sourceRange.lowerBound, offsetBy: offset)
        let replacementEnd = source.index(replacementStart, offsetBy: expression[localRange].count)
        let updatedSource = source.replacingCharacters(in: replacementStart..<replacementEnd, with: token)
        let start = UTABPitchSourceEditor.position(of: replacementStart, in: source)
        let replacementRange = SourceRange(
            fileID: range.fileID,
            start: start,
            end: SourcePosition(line: start.line, column: start.column + token.count)
        )
        return UTABSourceEdit(
            source: updatedSource,
            replacementRange: replacementRange,
            replacement: token,
            representationChange: .preserved
        )
    }

    public static func durationToken(for beats: Double) -> String? {
        [(4.0, "w"), (2.0, "h"), (1.0, "q"), (0.5, "e"), (0.25, "s")]
            .first { abs($0.0 - beats) < 0.000_001 }?.1
    }
}

public enum UTABPitchSourceEditor {
    public static func setPitch(
        in source: String,
        fileID: String,
        startLine: Int,
        startColumn: Int,
        endLine: Int,
        endColumn: Int,
        midiPitch: Int
    ) throws -> UTABSourceEdit {
        try setPitch(
            in: source,
            range: SourceRange(
                fileID: fileID,
                start: SourcePosition(line: startLine, column: startColumn),
                end: SourcePosition(line: endLine, column: endColumn)
            ),
            midiPitch: midiPitch
        )
    }

    public static func setPitch(
        in source: String,
        range: SourceRange,
        midiPitch: Int
    ) throws -> UTABSourceEdit {
        guard (0...127).contains(midiPitch) else {
            throw UTABSourceEditingError.invalidMIDIPitch(midiPitch)
        }
        guard let sourceRange = stringRange(for: range, in: source) else {
            throw UTABSourceEditingError.invalidSourceRange(range)
        }

        let authoredExpression = String(source[sourceRange])
        let pattern = #"^\s*(@[+-]?\d+\[[+-]?\d+\]|[A-Ga-g](?:#|b)*[+-]?\d+)"#
        let regularExpression = try NSRegularExpression(pattern: pattern)
        let fullRange = NSRange(authoredExpression.startIndex..., in: authoredExpression)
        guard let match = regularExpression.firstMatch(in: authoredExpression, range: fullRange),
              match.numberOfRanges > 1,
              let localRange = Range(match.range(at: 1), in: authoredExpression) else {
            throw UTABSourceEditingError.pitchNotFound(range)
        }

        let previousPitch = authoredExpression[localRange]
        let replacement = pitchName(for: midiPitch)
        let localOffset = authoredExpression.distance(
            from: authoredExpression.startIndex,
            to: localRange.lowerBound
        )
        let replacementStart = source.index(sourceRange.lowerBound, offsetBy: localOffset)
        let replacementEnd = source.index(replacementStart, offsetBy: previousPitch.count)
        let updatedSource = source.replacingCharacters(
            in: replacementStart..<replacementEnd,
            with: replacement
        )
        let replacementPosition = position(of: replacementStart, in: source)
        let replacementEndPosition = SourcePosition(
            line: replacementPosition.line,
            column: replacementPosition.column + replacement.count
        )
        let replacementRange = SourceRange(
            fileID: range.fileID,
            start: replacementPosition,
            end: replacementEndPosition
        )

        return UTABSourceEdit(
            source: updatedSource,
            replacementRange: replacementRange,
            replacement: replacement,
            representationChange: previousPitch.first == "@" ? .normalizedToAbsolutePitch : .preserved
        )
    }

    public static func setRelativePitch(
        in source: String,
        range: SourceRange,
        degree: Int,
        octave: Int,
        alteration: Int
    ) throws -> UTABSourceEdit {
        guard degree > 0, let sourceRange = stringRange(for: range, in: source) else {
            throw UTABSourceEditingError.invalidSourceRange(range)
        }
        let expression = String(source[sourceRange])
        let regex = try NSRegularExpression(pattern: #"^\s*@[+-]?\d+(?:#|b)*\[[+-]?\d+\]"#)
        let fullRange = NSRange(expression.startIndex..., in: expression)
        guard let match = regex.firstMatch(in: expression, range: fullRange),
              let localRange = Range(match.range, in: expression) else {
            throw UTABSourceEditingError.pitchNotFound(range)
        }
        let leadingWhitespace = expression[localRange].prefix { $0.isWhitespace }
        let replacement = String(leadingWhitespace) + relativePitchName(
            degree: degree,
            octave: octave,
            alteration: alteration
        )
        let offset = expression.distance(from: expression.startIndex, to: localRange.lowerBound)
        let replacementStart = source.index(sourceRange.lowerBound, offsetBy: offset)
        let replacementEnd = source.index(replacementStart, offsetBy: expression[localRange].count)
        let updated = source.replacingCharacters(in: replacementStart..<replacementEnd, with: replacement)
        let start = position(of: replacementStart, in: source)
        return UTABSourceEdit(
            source: updated,
            replacementRange: SourceRange(
                fileID: range.fileID,
                start: start,
                end: SourcePosition(line: start.line, column: start.column + replacement.count)
            ),
            replacement: replacement,
            representationChange: .preserved
        )
    }

    public static func relativePitchName(degree: Int, octave: Int, alteration: Int) -> String {
        let accidental = alteration >= 0
            ? String(repeating: "#", count: alteration)
            : String(repeating: "b", count: -alteration)
        return "@\(degree)\(accidental)[\(octave)]"
    }

    public static func pitchName(for midiPitch: Int) -> String {
        let pitchClasses = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        let pitchClass = pitchClasses[((midiPitch % 12) + 12) % 12]
        return pitchClass + String(midiPitch / 12 - 1)
    }

    fileprivate static func stringRange(for range: SourceRange, in source: String) -> Range<String.Index>? {
        guard let endPosition = range.end,
              let start = index(at: range.start, in: source),
              let end = index(at: endPosition, in: source),
              start <= end else {
            return nil
        }
        return start..<end
    }

    private static func index(at position: SourcePosition, in source: String) -> String.Index? {
        guard position.line > 0, position.column > 0 else { return nil }

        var index = source.startIndex
        var line = 1
        while line < position.line {
            guard let newline = source[index...].firstIndex(of: "\n") else { return nil }
            index = source.index(after: newline)
            line += 1
        }

        let lineEnd = source[index...].firstIndex(of: "\n") ?? source.endIndex
        return source.index(
            index,
            offsetBy: position.column - 1,
            limitedBy: lineEnd
        )
    }

    fileprivate static func position(of target: String.Index, in source: String) -> SourcePosition {
        var line = 1
        var column = 1
        var index = source.startIndex
        while index < target {
            if source[index] == "\n" {
                line += 1
                column = 1
            } else {
                column += 1
            }
            index = source.index(after: index)
        }
        return SourcePosition(line: line, column: column)
    }
}
