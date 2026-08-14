import UTABInstruments

public enum ProfileComponent: Sendable {
    case actuator(ActuatorGroup)
    case interaction(Interaction)
    case technique(InstrumentTechnique)
}

@resultBuilder
public enum ProfileBuilder {
    public static func buildBlock(_ components: ProfileComponent...) -> [ProfileComponent] { components }
    public static func buildArray(_ components: [[ProfileComponent]]) -> [ProfileComponent] { components.flatMap { $0 } }
    public static func buildExpression(_ actuator: ActuatorGroup) -> ProfileComponent { .actuator(actuator) }
    public static func buildExpression(_ interaction: Interaction) -> ProfileComponent { .interaction(interaction) }
    public static func buildExpression(_ technique: InstrumentTechnique) -> ProfileComponent { .technique(technique) }
}

public func Actuators(
    _ id: String,
    cardinality: ActuatorCardinality = .unconstrained,
    control: ActuatorControl = .discrete,
    members: [ActuatorMember] = []
) -> ActuatorGroup {
    .init(id, cardinality: cardinality, control: control, members: members)
}

public func Actuators(
    _ id: String,
    count: Int,
    control: ActuatorControl = .discrete,
    members: [ActuatorMember] = []
) -> ActuatorGroup {
    .init(id, count: count, control: control, members: members)
}

public func Can(
    _ interaction: String,
    target: String,
    effectors: [String] = []
) -> Interaction {
    .init(interaction, targets: [target], effectors: effectors)
}

public func Can(
    _ interaction: String,
    targets: [String],
    effectors: [String] = []
) -> Interaction {
    .init(interaction, targets: targets, effectors: effectors)
}

public func Technique(
    _ id: String,
    target: String? = nil,
    parameters: [String: InstrumentValue] = [:]
) -> InstrumentTechnique {
    .init(id, target: target, parameters: parameters)
}

public func Profile(
    _ id: InstrumentID,
    version: String = "0.1-draft",
    @ProfileBuilder _ content: () -> [ProfileComponent]
) -> InstrumentProfileDefinition {
    var actuators: [ActuatorGroup] = []
    var interactions: [Interaction] = []
    var techniques: [InstrumentTechnique] = []
    for component in content() {
        switch component {
        case .actuator(let value): actuators.append(value)
        case .interaction(let value): interactions.append(value)
        case .technique(let value): techniques.append(value)
        }
    }
    return .init(id: id, version: version, actuators: actuators, interactions: interactions, techniques: techniques)
}

public enum InstrumentModelComponent: Sendable {
    case geometry(InstrumentGeometry)
    case supportsTuning(InstrumentID, isDefault: Bool)
    case defaultValue(String, InstrumentValue)
}

@resultBuilder
public enum InstrumentModelBuilder {
    public static func buildBlock(_ components: InstrumentModelComponent...) -> [InstrumentModelComponent] { components }
    public static func buildArray(_ components: [[InstrumentModelComponent]]) -> [InstrumentModelComponent] { components.flatMap { $0 } }
}

public func Geometry(_ id: String, _ properties: [String: InstrumentValue]) -> InstrumentModelComponent {
    .geometry(.init(id, properties: properties))
}

public func Default(_ key: String, _ value: InstrumentValue) -> InstrumentModelComponent {
    .defaultValue(key, value)
}

public func Supports(_ tuning: InstrumentTuningDefinition, default isDefault: Bool = false) -> InstrumentModelComponent {
    .supportsTuning(tuning.id, isDefault: isDefault)
}

public func InstrumentModel(
    _ id: InstrumentID,
    name: String,
    profile: InstrumentID,
    @InstrumentModelBuilder _ content: () -> [InstrumentModelComponent] = { [] }
) -> InstrumentModelDefinition {
    var geometry: [InstrumentGeometry] = []
    var tunings: [InstrumentID] = []
    var defaultTuning: InstrumentID?
    var defaults: [String: InstrumentValue] = [:]
    for component in content() {
        switch component {
        case .geometry(let value): geometry.append(value)
        case .supportsTuning(let id, let isDefault):
            tunings.append(id)
            if isDefault { defaultTuning = id }
        case .defaultValue(let key, let value): defaults[key] = value
        }
    }
    return .init(id: id, name: name, profile: profile, geometry: geometry, tunings: tunings, defaultTuning: defaultTuning, defaults: defaults)
}

public func ConfiguredInstrument(
    _ id: InstrumentID,
    name: String? = nil,
    model: InstrumentID,
    configuration: [String: InstrumentValue] = [:]
) -> InstrumentInstanceDefinition {
    .init(id: id, name: name, model: model, configuration: configuration)
}

public enum CatalogComponent: Sendable {
    case tuning(InstrumentTuningDefinition)
    case profile(InstrumentProfileDefinition)
    case model(InstrumentModelDefinition)
}

@resultBuilder
public enum InstrumentCatalogBuilder {
    public static func buildBlock(_ components: CatalogComponent...) -> [CatalogComponent] { components }
    public static func buildArray(_ components: [[CatalogComponent]]) -> [CatalogComponent] { components.flatMap { $0 } }
    public static func buildExpression(_ tuning: InstrumentTuningDefinition) -> CatalogComponent { .tuning(tuning) }
    public static func buildExpression(_ profile: InstrumentProfileDefinition) -> CatalogComponent { .profile(profile) }
    public static func buildExpression(_ model: InstrumentModelDefinition) -> CatalogComponent { .model(model) }
}

public func InstrumentLibrary(@InstrumentCatalogBuilder _ content: () -> [CatalogComponent]) -> InstrumentCatalog {
    var tunings: [InstrumentTuningDefinition] = []
    var profiles: [InstrumentProfileDefinition] = []
    var models: [InstrumentModelDefinition] = []
    for component in content() {
        switch component {
        case .tuning(let value): tunings.append(value)
        case .profile(let value): profiles.append(value)
        case .model(let value): models.append(value)
        }
    }
    return .init(tunings: tunings, profiles: profiles, models: models)
}

@resultBuilder
public enum TuningBuilder {
    public static func buildBlock(_ components: TuningCourse...) -> [TuningCourse] { components }
    public static func buildArray(_ components: [[TuningCourse]]) -> [TuningCourse] { components.flatMap { $0 } }
}

public func Course(_ pitch: AbsolutePitch) -> TuningCourse { .init([pitch]) }
public func Course(_ pitches: AbsolutePitch...) -> TuningCourse { .init(pitches) }

public func Tuning(
    _ id: InstrumentID,
    name: String,
    tags: Set<String> = [],
    @TuningBuilder _ content: () -> [TuningCourse]
) -> InstrumentTuningDefinition {
    .init(id: id, name: name, courses: content(), tags: tags)
}
