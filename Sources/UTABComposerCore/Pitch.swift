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

    public init(_ letter: NoteLetter, accidental: Int = 0) {
        self.letter = letter
        self.accidental = accidental
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

    public func isAcousticallyEquivalent(to other: Self) -> Bool {
        chromaticIndex == other.chromaticIndex
    }
}

public enum ScaleKind: Sendable, Hashable {
    case major
    case naturalMinor

    public var intervals: [Int] {
        switch self {
        case .major: [0, 2, 4, 5, 7, 9, 11]
        case .naturalMinor: [0, 2, 3, 5, 7, 8, 10]
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
        let scaleOctave = zeroBased / kind.intervals.count
        let chromatic = tonic.rawValue + kind.intervals[zeroBased % kind.intervals.count]
        return AbsolutePitch(
            PitchClass(rawValue: chromatic % 12)!,
            octave: octave + scaleOctave + chromatic / 12
        )
    }
}

public enum MusicalPitch: Sendable, Hashable {
    case absolute(AbsolutePitch)
    case scaleDegree(Int, octave: Int)
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
        case scaleDegree(Int)
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
        self.root = .scaleDegree(scaleDegree)
        self.quality = quality
    }
}

public enum PerformanceConstraint: Sendable, Hashable {
    case group(String)
    case actuator(group: String, position: Int)
    case fingering(Int)
}
