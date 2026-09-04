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
        guard degree > 0 else { return nil }
        let zeroBased = degree - 1
        let scaleOctave = zeroBased / kind.centIntervals.count
        let cents = tonic.rawValue * 100 + kind.centIntervals[zeroBased % kind.centIntervals.count]
        let chromatic = cents / 100
        let pitchClass = PitchClass(rawValue: chromatic % 12)!
        let canonical = SpelledPitchClass.canonical(pitchClass)
        return AbsolutePitch(
            .init(canonical.letter, accidental: canonical.accidental, tuningOffsetCents: cents % 100),
            octave: octave + scaleOctave + chromatic / 12
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

public enum ChordQuality: Sendable, Hashable {
    case major, minor, diminished, suspendedFourth

    public var intervals: [Int] {
        switch self {
        case .major: [0, 4, 7]
        case .minor: [0, 3, 7]
        case .diminished: [0, 3, 6]
        case .suspendedFourth: [0, 5, 7]
        }
    }
}

public struct ChordSymbol: Sendable, Hashable {
    public enum Root: Sendable, Hashable {
        case absolute(SpelledPitchClass)
        case scaleDegree(Int, alteration: Int)
    }

    public let root: Root
    public let quality: ChordQuality

    public init(_ root: PitchClass, _ quality: ChordQuality) {
        self.root = .absolute(.canonical(root))
        self.quality = quality
    }

    public init(_ root: SpelledPitchClass, _ quality: ChordQuality) {
        self.root = .absolute(root)
        self.quality = quality
    }

    public init(scaleDegree: Int, _ quality: ChordQuality) {
        self.root = .scaleDegree(scaleDegree, alteration: 0)
        self.quality = quality
    }

    public init(scaleDegree: Int, alteration: Int, _ quality: ChordQuality) {
        self.root = .scaleDegree(scaleDegree, alteration: alteration)
        self.quality = quality
    }
}

public enum PerformanceConstraint: Sendable, Hashable {
    case group(String)
    case actuator(group: String, position: Int)
    case fingering(Int)
    case chordShape(String)
}
