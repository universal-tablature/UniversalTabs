public struct MusicalDuration: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let wholeNotes: Rational

    public init(_ numerator: Int, _ denominator: Int = 1) {
        self.wholeNotes = Rational(numerator, denominator)
    }

    public static let zero = MusicalDuration(0)
    public static let whole = MusicalDuration(1)
    public static let half = MusicalDuration(1, 2)
    public static let quarter = MusicalDuration(1, 4)
    public static let eighth = MusicalDuration(1, 8)
    public static let sixteenth = MusicalDuration(1, 16)

    public static func + (lhs: Self, rhs: Self) -> Self {
        Self(
            lhs.wholeNotes.numerator * rhs.wholeNotes.denominator
                + rhs.wholeNotes.numerator * lhs.wholeNotes.denominator,
            lhs.wholeNotes.denominator * rhs.wholeNotes.denominator
        )
    }

    public static func * (lhs: Self, rhs: Int) -> Self {
        precondition(rhs >= 0, "A duration multiplier cannot be negative")
        return Self(lhs.wholeNotes.numerator * rhs, lhs.wholeNotes.denominator)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.wholeNotes < rhs.wholeNotes
    }

    public var description: String { wholeNotes.description }
}

public struct Rational: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let numerator: Int
    public let denominator: Int

    public init(_ numerator: Int, _ denominator: Int = 1) {
        precondition(denominator != 0, "A rational denominator cannot be zero")
        let sign = denominator < 0 ? -1 : 1
        let divisor = Self.gcd(abs(numerator), abs(denominator))
        self.numerator = sign * numerator / divisor
        self.denominator = abs(denominator) / divisor
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.numerator * rhs.denominator < rhs.numerator * lhs.denominator
    }

    public var description: String { "\(numerator)/\(denominator)" }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        var x = a
        var y = b
        while y != 0 { (x, y) = (y, x % y) }
        return max(x, 1)
    }
}
