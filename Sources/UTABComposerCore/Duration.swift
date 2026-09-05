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
        let value = lhs.wholeNotes.adding(rhs.wholeNotes)!
        return Self(value.numerator, value.denominator)
    }

    public static func * (lhs: Self, rhs: Int) -> Self {
        precondition(rhs >= 0, "A duration multiplier cannot be negative")
        let value = lhs.wholeNotes.multiplied(by: Rational(rhs))!
        return Self(value.numerator, value.denominator)
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
        let left = lhs.numerator.multipliedFullWidth(by: rhs.denominator)
        let right = rhs.numerator.multipliedFullWidth(by: lhs.denominator)
        return left.high == right.high ? left.low < right.low : left.high < right.high
    }

    /// Checked arithmetic for nonnegative score time. Cross-cancel before multiplying.
    public func multiplied(by other: Self) -> Self? {
        guard numerator >= 0, other.numerator >= 0 else { return nil }
        let a = Self.gcd(numerator, other.denominator)
        let b = Self.gcd(other.numerator, denominator)
        let n = (numerator / a).multipliedReportingOverflow(by: other.numerator / b)
        let d = (denominator / b).multipliedReportingOverflow(by: other.denominator / a)
        guard !n.overflow, !d.overflow else { return nil }
        return Self(n.partialValue, d.partialValue)
    }

    public func adding(_ other: Self) -> Self? {
        guard numerator >= 0, other.numerator >= 0 else { return nil }
        let common = Self.gcd(denominator, other.denominator)
        let left = UInt(numerator).multipliedFullWidth(by: UInt(other.denominator / common))
        let right = UInt(other.numerator).multipliedFullWidth(by: UInt(denominator / common))
        let low = left.low.addingReportingOverflow(right.low)
        let high = left.high + right.high + (low.overflow ? 1 : 0)
        // Reduce the wide numerator before narrowing either component to Int.
        let divisor = UInt(common)
        let remainder = divisor.dividingFullWidth((high: high % divisor, low: low.partialValue)).remainder
        let reduction = UInt(Self.gcd(Int(remainder), common))
        guard high < reduction else { return nil }
        let n = reduction.dividingFullWidth((high: high, low: low.partialValue)).quotient
        let d = (denominator / common).multipliedReportingOverflow(by: other.denominator / Int(reduction))
        guard n <= UInt(Int.max), !d.overflow else { return nil }
        return Self(Int(n), d.partialValue)
    }

    public var description: String { "\(numerator)/\(denominator)" }

    public func subtracting(_ other: Self) -> Self? {
        guard numerator >= 0, other.numerator >= 0, self >= other else { return nil }
        let common = Self.gcd(denominator, other.denominator)
        let left = UInt(numerator).multipliedFullWidth(by: UInt(other.denominator / common))
        let right = UInt(other.numerator).multipliedFullWidth(by: UInt(denominator / common))
        let low = left.low.subtractingReportingOverflow(right.low)
        let high = left.high - right.high - (low.overflow ? 1 : 0)
        // Reduce the wide numerator before narrowing either component to Int.
        let divisor = UInt(common)
        let remainder = divisor.dividingFullWidth((high: high % divisor, low: low.partialValue)).remainder
        let reduction = UInt(Self.gcd(Int(remainder), common))
        guard high < reduction else { return nil }
        let n = reduction.dividingFullWidth((high: high, low: low.partialValue)).quotient
        let d = (denominator / common).multipliedReportingOverflow(by: other.denominator / Int(reduction))
        guard n <= UInt(Int.max), !d.overflow else { return nil }
        return Self(Int(n), d.partialValue)
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        var x = a
        var y = b
        while y != 0 { (x, y) = (y, x % y) }
        return max(x, 1)
    }
}
