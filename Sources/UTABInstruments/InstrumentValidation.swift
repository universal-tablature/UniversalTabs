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
        return result
    }

    public func validate(_ instance: InstrumentInstanceDefinition, in catalog: InstrumentCatalog) -> [InstrumentDiagnostic] {
        catalog.models.contains { $0.id == instance.model }
            ? []
            : [.init(path: "instance.model", message: "Unknown model '\(instance.model)'")]
    }
}
