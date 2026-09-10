// Copyright 2026 Mattias Holm
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation

public enum PitchClass: Int, Sendable, Hashable, CaseIterable {
    case c = 0, cSharp, d, eFlat, e, f, fSharp, g, aFlat, a, bFlat, b
}

public enum NoteLetter: Int, Sendable, Hashable, CaseIterable {
    case c, d, e, f, g, a, b

    fileprivate var naturalPitchClass: Int {
        switch self {
        case .c: 0
        case .d: 2
        case .e: 4
        case .f: 5
        case .g: 7
        case .a: 9
        case .b: 11
        }
    }
}

/// An authored musical spelling. Accidentals are measured in chromatic semitones,
/// allowing flats, sharps, and their repeated forms without changing acoustic identity.
public struct SpelledPitchClass: Sendable, Hashable {
    public let letter: NoteLetter
    public let accidental: Int
    /// Fine tuning relative to the conventionally spelled 12-TET pitch.
    public let tuningOffsetCents: Int

    public init(_ letter: NoteLetter, accidental: Int = 0, tuningOffsetCents: Int = 0) {
        self.letter = letter
        self.accidental = accidental
        self.tuningOffsetCents = tuningOffsetCents
    }

    public var pitchClass: PitchClass {
        let value = ((letter.naturalPitchClass + accidental) % 12 + 12) % 12
        return PitchClass(rawValue: value)!
    }

    public static func canonical(_ pitchClass: PitchClass) -> Self {
        switch pitchClass {
        case .c: .init(.c)
        case .cSharp: .init(.c, accidental: 1)
        case .d: .init(.d)
        case .eFlat: .init(.e, accidental: -1)
        case .e: .init(.e)
        case .f: .init(.f)
        case .fSharp: .init(.f, accidental: 1)
        case .g: .init(.g)
        case .aFlat: .init(.a, accidental: -1)
        case .a: .init(.a)
        case .bFlat: .init(.b, accidental: -1)
        case .b: .init(.b)
        }
    }
}

public struct AbsolutePitch: Sendable, Hashable {
    public let spelling: SpelledPitchClass
    public let octave: Int

    public var pitchClass: PitchClass { spelling.pitchClass }

    public init(_ pitchClass: PitchClass, octave: Int) {
        self.spelling = .canonical(pitchClass)
        self.octave = octave
    }

    public init(_ spelling: SpelledPitchClass, octave: Int) {
        self.spelling = spelling
        self.octave = octave
    }

    public var chromaticIndex: Int { (octave + 1) * 12 + pitchClass.rawValue }
    public var acousticCents: Int { chromaticIndex * 100 + spelling.tuningOffsetCents }

    public static let concertA = AbsolutePitch(.a, octave: 4)

    /// Frequency in hertz, retaining any fine-tuning offset carried by the spelling.
    public func frequency(
        referencePitch: AbsolutePitch = .concertA,
        referenceFrequency: Double = 440
    ) -> Double {
        precondition(referenceFrequency > 0, "Reference frequency must be positive")
        return referenceFrequency * pow(2, Double(acousticCents - referencePitch.acousticCents) / 1_200)
    }

    public func cents(relativeTo other: AbsolutePitch) -> Int {
        acousticCents - other.acousticCents
    }

    /// Returns a canonically spelled pitch at the requested acoustic displacement.
    public func transposed(cents: Int) -> AbsolutePitch {
        AbsolutePitch(acousticCents: acousticCents + cents)
    }

    /// Creates a canonical spelling whose fine offset is within half a semitone.
    public init(acousticCents: Int) {
        let nearestChromaticIndex = Int((Double(acousticCents) / 100).rounded())
        let pitchClassValue = ((nearestChromaticIndex % 12) + 12) % 12
        let pitchClass = PitchClass(rawValue: pitchClassValue)!
        self.spelling = .init(
            SpelledPitchClass.canonical(pitchClass).letter,
            accidental: SpelledPitchClass.canonical(pitchClass).accidental,
            tuningOffsetCents: acousticCents - nearestChromaticIndex * 100
        )
        self.octave = floorDiv(nearestChromaticIndex, by: 12) - 1
    }

    public func isAcousticallyEquivalent(to other: Self) -> Bool {
        acousticCents == other.acousticCents
    }
}

private func floorDiv(_ value: Int, by divisor: Int) -> Int {
    let quotient = value / divisor
    let remainder = value % divisor
    return remainder < 0 ? quotient - 1 : quotient
}

public enum ScaleKind: Sendable, Hashable {
    case major
    case naturalMinor
    case custom(name: String, centIntervals: [Int])

    public var intervals: [Int] {
        centIntervals.map { $0 / 100 }
    }

    /// A 12-TET reference form. Performers may shade neutral degrees by region,
    /// direction, and melodic context; those deviations remain expressible as cents.
    public var centIntervals: [Int] {
        switch self {
        case .major: [0, 200, 400, 500, 700, 900, 1100]
        case .naturalMinor: [0, 200, 300, 500, 700, 800, 1000]
        case .custom(_, let centIntervals): centIntervals
        }
    }
}

public struct Scale: Sendable, Hashable {
    public let tonicSpelling: SpelledPitchClass
    public let kind: ScaleKind

    public var tonic: PitchClass { tonicSpelling.pitchClass }

    public init(_ tonic: PitchClass, _ kind: ScaleKind) {
        self.tonicSpelling = .canonical(tonic)
        self.kind = kind
    }

    public init(_ tonic: SpelledPitchClass, _ kind: ScaleKind) {
        self.tonicSpelling = tonic
        self.kind = kind
    }

    public func resolve(degree: Int, octave: Int) -> AbsolutePitch? {
        let intervals = kind.centIntervals
        guard !intervals.isEmpty else { return nil }
        let zeroBased = degree - 1
        let scaleOctave = Int(floor(Double(zeroBased) / Double(intervals.count)))
        let degreeIndex = ((zeroBased % intervals.count) + intervals.count) % intervals.count
        let intervalCents = intervals[degreeIndex] + scaleOctave * 1_200
        let targetCents = AbsolutePitch(tonicSpelling, octave: octave).acousticCents + intervalCents

        // Seven-degree scales retain the authored tonic's diatonic spelling. This
        // keeps, for example, D-major's third as F# rather than canonicalizing it
        // to Gb, while acoustic cents still include fine tuning on the tonic.
        guard intervals.count == NoteLetter.allCases.count else {
            return AbsolutePitch(acousticCents: targetCents)
        }
        let letterIndex = tonicSpelling.letter.rawValue + zeroBased
        let normalizedLetterIndex = ((letterIndex % NoteLetter.allCases.count) + NoteLetter.allCases.count) % NoteLetter.allCases.count
        let letter = NoteLetter.allCases[normalizedLetterIndex]
        let resolvedOctave = octave + Int(floor(Double(letterIndex) / Double(NoteLetter.allCases.count)))
        let naturalCents = ((resolvedOctave + 1) * 12 + letter.naturalPitchClass) * 100
        let displacement = targetCents - naturalCents
        let accidental = Int((Double(displacement) / 100).rounded())
        return AbsolutePitch(
            .init(letter, accidental: accidental, tuningOffsetCents: displacement - accidental * 100),
            octave: resolvedOctave
        )
    }
}

public enum MusicalPitch: Sendable, Hashable {
    case absolute(AbsolutePitch)
    case scaleDegree(Int, octave: Int, alteration: Int)

    public static func scaleDegree(_ degree: Int, octave: Int) -> Self {
        .scaleDegree(degree, octave: octave, alteration: 0)
    }
}

public struct ChordQuality: Sendable, Hashable {
    public let name: String
    public let degrees: [Int]
    public let intervals: [Int]

    public init(name: String, degrees: [Int], intervals: [Int]) {
        precondition(!name.isEmpty && !degrees.isEmpty && degrees.count == intervals.count)
        self.name = name
        self.degrees = degrees
        self.intervals = intervals
    }

    public static let major = Self(name: "major", degrees: [1, 3, 5], intervals: [0, 4, 7])
    public static let minor = Self(name: "minor", degrees: [1, 3, 5], intervals: [0, 3, 7])
    public static let diminished = Self(name: "diminished", degrees: [1, 3, 5], intervals: [0, 3, 6])
    public static let suspendedFourth = Self(name: "sus4", degrees: [1, 4, 5], intervals: [0, 5, 7])
    public static let majorSeventh = Self(name: "major7", degrees: [1, 3, 5, 7], intervals: [0, 4, 7, 11])
    public static let minorSeventh = Self(name: "minor7", degrees: [1, 3, 5, 7], intervals: [0, 3, 7, 10])
    public static let dominantSeventh = Self(name: "dominant7", degrees: [1, 3, 5, 7], intervals: [0, 4, 7, 10])
    public static let power = Self(name: "power", degrees: [1, 5], intervals: [0, 7])
}

public struct ChordSymbol: Sendable, Hashable {
    public enum Root: Sendable, Hashable {
        case absolute(SpelledPitchClass)
        case scaleDegree(Int, alteration: Int)
    }

    public let root: Root
    public let quality: ChordQuality
    public let bass: SpelledPitchClass?
    public let inversion: Int?

    public init(root: Root, quality: ChordQuality, bass: SpelledPitchClass? = nil, inversion: Int? = nil) {
        self.root = root
        self.quality = quality
        self.bass = bass
        self.inversion = inversion
    }

    public init(_ root: PitchClass, _ quality: ChordQuality, bass: SpelledPitchClass? = nil, inversion: Int? = nil) {
        self.root = .absolute(.canonical(root))
        self.quality = quality
        self.bass = bass
        self.inversion = inversion
    }

    public init(_ root: SpelledPitchClass, _ quality: ChordQuality, bass: SpelledPitchClass? = nil, inversion: Int? = nil) {
        self.root = .absolute(root)
        self.quality = quality
        self.bass = bass
        self.inversion = inversion
    }

    public init(scaleDegree: Int, _ quality: ChordQuality) {
        self.root = .scaleDegree(scaleDegree, alteration: 0)
        self.quality = quality
        self.bass = nil
        self.inversion = nil
    }

    public init(scaleDegree: Int, alteration: Int, _ quality: ChordQuality, bass: SpelledPitchClass? = nil, inversion: Int? = nil) {
        self.root = .scaleDegree(scaleDegree, alteration: alteration)
        self.quality = quality
        self.bass = bass
        self.inversion = inversion
    }
}

public enum PerformanceConstraint: Sendable, Hashable {
    case group(String)
    case actuator(group: String, position: Int)
    case fingering(Int)
    case chordShape(String)
    case chordShapeRootString(Int)
    case chordOmit(Int)
    case chordDouble(Int)
    case chordAdd(degree: Int, alteration: Int)
    case chordAlter(degree: Int, semitones: Int)
    case pitchRange(AbsolutePitch, AbsolutePitch)
}
