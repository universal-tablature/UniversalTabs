import UTABNotation

public enum UTabStaffClef: Sendable {
    case automatic
    case treble
    case alto
    case bass
}

public enum UTabStaffLayout: Sendable {
    case automatic
    case single
    case grandStaff
}

/// Platform-neutral engraving rules expressed in staff-space coordinates.
///
/// Renderers supply their own unit conversion. A value of 1 represents the
/// distance between adjacent staff lines; half a unit is one diatonic step.
public enum UTabStaffEngraver {
    public static func clefs(
        for events: [UTabScore.Event],
        preferredClef: UTabStaffClef,
        layout: UTabStaffLayout
    ) -> [UTabStaffClef] {
        let steps = events.compactMap(\.staffStep).sorted()
        if layout == .grandStaff {
            return [.treble, .bass]
        }
        if layout == .automatic,
           let lowest = steps.first,
           let highest = steps.last,
           lowest < 28,
           highest >= 28 {
            return [.treble, .bass]
        }
        guard preferredClef == .automatic else {
            return [preferredClef]
        }
        guard let middle = steps.isEmpty ? nil : steps[steps.count / 2] else {
            return [.treble]
        }
        return [middle < 28 ? .bass : .treble]
    }

    public static func staffIndex(for step: Int, clefs: [UTabStaffClef]) -> Int {
        guard clefs.count > 1 else { return 0 }
        return clefs.enumerated().min {
            abs(centerStep(for: $0.element) - step) < abs(centerStep(for: $1.element) - step)
        }?.offset ?? 0
    }

    public static func verticalOffset(
        for step: Int,
        clef: UTabStaffClef
    ) -> Double {
        Double(topLineStep(for: clef) - step) / 2
    }

    public static func ledgerSteps(
        for step: Int,
        clef: UTabStaffClef
    ) -> [Int] {
        let bounds = ledgerBounds(for: clef)
        if step <= bounds.bottom {
            return Array(stride(from: bounds.bottom, through: step, by: -2))
        }
        if step >= bounds.top {
            return Array(stride(from: bounds.top, through: step, by: 2))
        }
        return []
    }

    public static func referenceStep(for clef: UTabStaffClef) -> Int {
        switch clef {
        case .bass: 24 // F3
        case .alto: 28 // C4
        case .automatic, .treble: 32 // G4
        }
    }

    private static func centerStep(for clef: UTabStaffClef) -> Int {
        switch clef {
        case .bass: 22
        case .alto: 28
        case .automatic, .treble: 34
        }
    }

    private static func topLineStep(for clef: UTabStaffClef) -> Int {
        switch clef {
        case .bass: 26
        case .alto: 32
        case .automatic, .treble: 38
        }
    }

    private static func ledgerBounds(for clef: UTabStaffClef) -> (bottom: Int, top: Int) {
        switch clef {
        case .bass: (16, 28)
        case .alto: (20, 34)
        case .automatic, .treble: (28, 40)
        }
    }
}
