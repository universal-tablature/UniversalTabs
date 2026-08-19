public struct InstrumentDiagnostic: Sendable, Hashable, CustomStringConvertible {
    public let path: String
    public let message: String
    public init(path: String, message: String) { self.path = path; self.message = message }
    public var description: String { "error: \(path): \(message)" }
}

public struct InstrumentCatalogValidator: Sendable {
    public init() {}

    public func validate(_ catalog: InstrumentCatalog) -> [InstrumentDiagnostic] {
        var result: [InstrumentDiagnostic] = []
        var tuningIDs = Set<InstrumentID>()
        for (tuningIndex, tuning) in catalog.tunings.enumerated() {
            let path = "tunings[\(tuningIndex)]"
            if !tuningIDs.insert(tuning.id).inserted { result.append(.init(path: "\(path).id", message: "Duplicate tuning '\(tuning.id)'")) }
            if tuning.courses.isEmpty { result.append(.init(path: "\(path).courses", message: "A tuning must contain at least one course")) }
            for (courseIndex, course) in tuning.courses.enumerated() where course.pitches.isEmpty {
                result.append(.init(path: "\(path).courses[\(courseIndex)]", message: "A course must contain at least one pitch"))
            }
        }
        var profileIDs = Set<InstrumentID>()
        for (profileIndex, profile) in catalog.profiles.enumerated() {
            let path = "profiles[\(profileIndex)]"
            if profile.id.rawValue.isEmpty { result.append(.init(path: "\(path).id", message: "ID must not be empty")) }
            if !profileIDs.insert(profile.id).inserted { result.append(.init(path: "\(path).id", message: "Duplicate profile '\(profile.id)'")) }
            var actuatorIDs = Set<String>()
            for (index, actuator) in profile.actuators.enumerated() {
                switch actuator.cardinality {
                case .exact(let count) where count < 1:
                    result.append(.init(path: "\(path).actuators[\(index)].cardinality", message: "Count must be positive"))
                case .range(let range) where range.lowerBound < 1:
                    result.append(.init(path: "\(path).actuators[\(index)].cardinality", message: "Range must contain only positive counts"))
                default: break
                }
                if !actuatorIDs.insert(actuator.id).inserted { result.append(.init(path: "\(path).actuators[\(index)].id", message: "Duplicate actuator group '\(actuator.id)'")) }
                if case .orderedBitset(let width) = actuator.control,
                   case .exact(let count) = actuator.cardinality, width < count {
                    result.append(.init(path: "\(path).actuators[\(index)].control", message: "Bitset width cannot be smaller than actuator count"))
                }
                if !actuator.members.isEmpty && !actuator.cardinality.contains(actuator.members.count) {
                    result.append(.init(path: "\(path).actuators[\(index)].members", message: "Member count must equal actuator count"))
                }
            }
            for (index, interaction) in profile.interactions.enumerated() {
                for target in interaction.targets where !actuatorIDs.contains(target) {
                    result.append(.init(path: "\(path).interactions[\(index)].targets", message: "Unknown actuator group '\(target)'"))
                }
            }
        }

        var modelIDs = Set<InstrumentID>()
        let fingeringIDs = Set(catalog.fingerings.map(\.id))
        for (index, model) in catalog.models.enumerated() {
            let path = "models[\(index)]"
            if !modelIDs.insert(model.id).inserted { result.append(.init(path: "\(path).id", message: "Duplicate model '\(model.id)'")) }
            if !profileIDs.contains(model.profile) { result.append(.init(path: "\(path).profile", message: "Unknown profile '\(model.profile)'")) }
            for tuning in model.tunings where !tuningIDs.contains(tuning) {
                result.append(.init(path: "\(path).tunings", message: "Unknown tuning '\(tuning)'"))
            }
            if let defaultTuning = model.defaultTuning, !model.tunings.contains(defaultTuning) {
                result.append(.init(path: "\(path).defaultTuning", message: "Default tuning must be listed in model tunings"))
            }
            for fingering in model.fingerings where !fingeringIDs.contains(fingering) {
                result.append(.init(path: "\(path).fingerings", message: "Unknown fingering '\(fingering)'"))
            }
            if let defaultFingering = model.defaultFingering, !model.fingerings.contains(defaultFingering) {
                result.append(.init(path: "\(path).defaultFingering", message: "Default fingering must be listed in model fingerings"))
            }
            if let profile = catalog.profiles.first(where: { $0.id == model.profile }) {
                for actuator in profile.actuators {
                    guard let geometry = model.geometry.first(where: { $0.id == actuator.id }),
                          case .integer(let count) = geometry.properties["count"] else { continue }
                    if !actuator.cardinality.contains(count) {
                        result.append(.init(path: "\(path).geometry.\(actuator.id).count", message: "Count \(count) is incompatible with the profile"))
                    }
                }
            }
            let courseCount = model.geometry.first(where: { $0.id == "strings" || $0.id == "courses" })
                .flatMap { geometry -> Int? in
                    guard case .integer(let count) = geometry.properties["count"] else { return nil }
                    return count
                }
            if let courseCount {
                for tuningID in model.tunings {
                    guard let tuning = catalog.tunings.first(where: { $0.id == tuningID }) else { continue }
                    if tuning.courses.count != courseCount {
                        result.append(.init(path: "\(path).tunings", message: "Tuning '\(tuningID)' has \(tuning.courses.count) courses; expected \(courseCount)"))
                    }
                }
            }
        }
        var seenFingerings = Set<InstrumentID>()
        for (index, fingering) in catalog.fingerings.enumerated() {
            let path = "fingerings[\(index)]"
            if !seenFingerings.insert(fingering.id).inserted { result.append(.init(path: "\(path).id", message: "Duplicate fingering '\(fingering.id)'")) }
            guard let model = catalog.models.first(where: { $0.id == fingering.model }),
                  let profile = catalog.profiles.first(where: { $0.id == model.profile }) else {
                result.append(.init(path: "\(path).model", message: "Unknown fingering model '\(fingering.model)'")); continue
            }
            if !profile.actuators.contains(where: { $0.id == fingering.actuatorGroup }) {
                result.append(.init(path: "\(path).actuatorGroup", message: "Unknown fingering actuator group '\(fingering.actuatorGroup)'"))
            }
            if fingering.bitOrder.isEmpty || Set(fingering.bitOrder).count != fingering.bitOrder.count {
                result.append(.init(path: "\(path).bitOrder", message: "Fingering bitOrder must contain unique actuator names"))
            }
            if let parent = fingering.parent {
                if parent == fingering.id { result.append(.init(path: "\(path).parent", message: "A fingering cannot extend itself")) }
                else if let base = catalog.fingerings.first(where: { $0.id == parent }) {
                    if base.model != fingering.model { result.append(.init(path: "\(path).parent", message: "A fingering can only extend a map for the same model")) }
                    if base.bitOrder != fingering.bitOrder { result.append(.init(path: "\(path).bitOrder", message: "An extending fingering must preserve bitOrder")) }
                } else { result.append(.init(path: "\(path).parent", message: "Unknown parent fingering '\(parent)'")) }
            }
            for entry in fingering.entries where entry.pattern.count != fingering.bitOrder.count || !entry.pattern.allSatisfy({ $0 == "0" || $0 == "1" || $0 == "h" || $0 == "x" }) {
                result.append(.init(path: "\(path).entries", message: "Invalid fingering pattern"))
            }
            for left in fingering.entries.indices {
                for right in fingering.entries.indices where right > left {
                    let lhs = fingering.entries[left]
                    let rhs = fingering.entries[right]
                    if lhs.specificity == rhs.specificity, lhs.overlaps(rhs), lhs.result != rhs.result {
                        result.append(.init(path: "\(path).entries[\(right)]", message: "Ambiguous equal-specificity fingering patterns '\(lhs.pattern)' and '\(rhs.pattern)'"))
                    }
                }
            }
            var ancestors = Set<InstrumentID>()
            var ancestor = fingering.parent
            while let current = ancestor, let definition = catalog.fingerings.first(where: { $0.id == current }) {
                if current == fingering.id || !ancestors.insert(current).inserted {
                    result.append(.init(path: "\(path).parent", message: "Fingering inheritance cycle")); break
                }
                ancestor = definition.parent
            }
        }
        return result
    }

    public func validate(_ instance: InstrumentInstanceDefinition, in catalog: InstrumentCatalog) -> [InstrumentDiagnostic] {
        guard let model = catalog.models.first(where: { $0.id == instance.model }) else {
            return [.init(path: "instance.model", message: "Unknown model '\(instance.model)'")]
        }
        if let fingering = instance.fingering, !model.fingerings.contains(fingering) {
            return [.init(path: "instance.fingering", message: "Fingering '\(fingering)' is not supported by model '\(model.id)'")]
        }
        return []
    }
}
