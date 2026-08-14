public enum PitchClass: Int, Sendable, Hashable, CaseIterable {
    case c = 0, cSharp, d, eFlat, e, f, fSharp, g, aFlat, a, bFlat, b
}

public struct AbsolutePitch: Sendable, Hashable {
    public let pitchClass: PitchClass
    public let octave: Int

    public init(_ pitchClass: PitchClass, octave: Int) {
        self.pitchClass = pitchClass
        self.octave = octave
    }

    public var chromaticIndex: Int { (octave + 1) * 12 + pitchClass.rawValue }
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
    public let tonic: PitchClass
    public let kind: ScaleKind

    public init(_ tonic: PitchClass, _ kind: ScaleKind) {
        self.tonic = tonic
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
    public let root: PitchClass
    public let quality: ChordQuality

    public init(_ root: PitchClass, _ quality: ChordQuality) {
        self.root = root
        self.quality = quality
    }
}

public enum PerformanceConstraint: Sendable, Hashable {
    case group(String)
    case actuator(group: String, position: Int)
    case fingering(Int)
}
