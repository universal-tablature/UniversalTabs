import Foundation

public enum Pitch {
    public static func midiNote(_ name: String) -> Int? {
        let pattern = #"^([A-Ga-g])([#b]?)(-?\d+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              let letterRange = Range(match.range(at: 1), in: name),
              let accidentalRange = Range(match.range(at: 2), in: name),
              let octaveRange = Range(match.range(at: 3), in: name),
              let octave = Int(name[octaveRange]) else { return nil }

        let offsets: [Character: Int] = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]
        guard var semitone = offsets[Character(name[letterRange].uppercased())] else { return nil }
        switch name[accidentalRange] {
        case "#": semitone += 1
        case "b": semitone -= 1
        default: break
        }
        let result = (octave + 1) * 12 + semitone
        return (0...127).contains(result) ? result : nil
    }
}
