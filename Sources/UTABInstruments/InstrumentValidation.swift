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
        var profileIDs = Set<InstrumentID>()
        for (profileIndex, profile) in catalog.profiles.enumerated() {
            let path = "profiles[\(profileIndex)]"
            if profile.id.rawValue.isEmpty { result.append(.init(path: "\(path).id", message: "ID must not be empty")) }
            if !profileIDs.insert(profile.id).inserted { result.append(.init(path: "\(path).id", message: "Duplicate profile '\(profile.id)'")) }
            var actuatorIDs = Set<String>()
            for (index, actuator) in profile.actuators.enumerated() {
                if actuator.count < 1 { result.append(.init(path: "\(path).actuators[\(index)].count", message: "Count must be positive")) }
                if !actuatorIDs.insert(actuator.id).inserted { result.append(.init(path: "\(path).actuators[\(index)].id", message: "Duplicate actuator group '\(actuator.id)'")) }
                if case .orderedBitset(let width) = actuator.control, width < actuator.count {
                    result.append(.init(path: "\(path).actuators[\(index)].control", message: "Bitset width cannot be smaller than actuator count"))
                }
                if !actuator.members.isEmpty && actuator.members.count != actuator.count {
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
        }
        return result
    }

    public func validate(_ instance: InstrumentInstanceDefinition, in catalog: InstrumentCatalog) -> [InstrumentDiagnostic] {
        catalog.models.contains { $0.id == instance.model }
            ? []
            : [.init(path: "instance.model", message: "Unknown model '\(instance.model)'")]
    }
}
