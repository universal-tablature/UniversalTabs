public extension UTabDocument {
    init(publicly _: Void = (), utab: UTabMetadata, setup: PerformanceSetup, tracks: [EventTrack]) {
        self.utab = utab; self.setup = setup; self.tracks = tracks
    }
}

public extension UTabMetadata {
    init(
        publicly _: Void = (),
        version: String,
        documentId: String? = nil,
        title: String? = nil,
        authors: [String]? = nil,
        work: UTabWorkMetadata? = nil,
        movement: UTabMovementMetadata? = nil,
        contributors: [UTabContributor]? = nil,
        rights: [UTabRights]? = nil,
        source: String? = nil,
        relations: [String]? = nil,
        encoding: UTabEncodingMetadata? = nil,
        miscellaneous: [String: String]? = nil
    ) {
        self.version = version; self.documentId = documentId; self.title = title; self.authors = authors
        self.work = work; self.movement = movement; self.contributors = contributors; self.rights = rights
        self.source = source; self.relations = relations; self.encoding = encoding; self.miscellaneous = miscellaneous
    }
}

public extension UTabEncodingMetadata {
    init(publicly _: Void = (), date: String? = nil, software: [String]? = nil, encoders: [String]? = nil, description: String? = nil) {
        self.date = date; self.software = software; self.encoders = encoders; self.description = description
    }
}

public extension PerformanceSetup {
    init(
        publicly _: Void = (),
        profiles: [InstrumentProfile],
        instruments: [InstrumentInstance],
        performers: [Performer]? = nil,
        time: TimeSetup? = nil,
        sections: [SectionDefinition]? = nil,
        arrangement: [ArrangementEntry]? = nil,
        tunings: [TuningDefinition]? = nil
    ) {
        self.profiles = profiles; self.instruments = instruments; self.performers = performers
        self.time = time; self.sections = sections; self.arrangement = arrangement; self.tunings = tunings
    }
}

public extension TuningDefinition {
    init(publicly _: Void = (), id: String, type: String, periodRatio: String, divisions: Int? = nil, degrees: [String]? = nil, reference: TuningReference, names: [String: Int]? = nil) {
        self.id = id; self.type = type; self.periodRatio = periodRatio; self.divisions = divisions
        self.degrees = degrees; self.reference = reference; self.names = names
    }
}

public extension TuningReference {
    init(publicly _: Void = (), pitch: TuningCoordinate, frequencyHz: Double) { self.pitch = pitch; self.frequencyHz = frequencyHz }
}

public extension TuningCoordinate {
    init(publicly _: Void = (), degree: Int, period: Int) { self.degree = degree; self.period = period }
}

public extension PitchValue {
    init(frequencyHz: Double? = nil, tuning: String? = nil, degree: Int? = nil, name: String? = nil, period: Int? = nil, legacyName: String? = nil) {
        self.frequencyHz = frequencyHz; self.tuning = tuning; self.degree = degree
        self.name = name; self.period = period; self.legacyName = legacyName
    }
}

public extension SectionDefinition {
    init(publicly _: Void = (), id: String, name: String? = nil, role: String? = nil, length: SectionLength, meterMap: [MeterChange]? = nil) {
        self.id = id; self.name = name; self.role = role; self.length = length; self.meterMap = meterMap
    }
}

public extension SectionLength {
    init(publicly _: Void = (), measures: Int) { self.measures = measures }
}

public extension ArrangementEntry {
    init(publicly _: Void = (), id: String, section: String, playCount: Int? = nil) { self.id = id; self.section = section; self.playCount = playCount }
}

public extension InstrumentProfile {
    init(
        publicly _: Void = (),
        id: String,
        name: String? = nil,
        profileVersion: String? = nil,
        source: String? = nil,
        actuators: [String: ActuatorDefinition]? = nil,
        geometry: [String: JSONValue]? = nil,
        interactions: [String: JSONValue]? = nil,
        techniques: [String: JSONValue]? = nil,
        performerDefaults: [String: JSONValue]? = nil,
        constraints: [JSONValue]? = nil
    ) {
        self.id = id; self.name = name; self.profileVersion = profileVersion; self.source = source
        self.actuators = actuators; self.geometry = geometry; self.interactions = interactions
        self.techniques = techniques; self.performerDefaults = performerDefaults; self.constraints = constraints
    }
}

public extension ActuatorDefinition {
    init(
        publicly _: Void = (),
        type: String? = nil,
        count: Int? = nil,
        representation: String? = nil,
        width: Int? = nil,
        positionControl: String? = nil,
        directlyActuated: Bool? = nil,
        range: [Double]? = nil,
        members: [ActuatorMember]? = nil,
        bits: [ActuatorBit]? = nil,
        bitValue: [String: String]? = nil
    ) {
        self.type = type; self.count = count; self.representation = representation; self.width = width
        self.positionControl = positionControl; self.directlyActuated = directlyActuated; self.range = range
        self.members = members; self.bits = bits; self.bitValue = bitValue
    }
}

public extension ActuatorMember {
    init(publicly _: Void = (), id: String, type: String? = nil, pitch: PitchValue? = nil, basePitch: PitchValue? = nil) {
        self.id = id; self.type = type; self.pitch = pitch; self.basePitch = basePitch
    }
}

public extension InstrumentInstance {
    init(publicly _: Void = (), id: String, name: String? = nil, profile: String, configuration: [String: JSONValue]? = nil) {
        self.id = id; self.name = name; self.profile = profile; self.configuration = configuration
    }
}

public extension TimeSetup {
    init(publicly _: Void = (), meter: MeterChange? = nil, tempo: TempoChange? = nil, meterMap: [MeterChange]? = nil, tempoMap: [TempoChange]? = nil, absoluteOrigin: Quantity? = nil) {
        self.meter = meter; self.tempo = tempo; self.meterMap = meterMap; self.tempoMap = tempoMap; self.absoluteOrigin = absoluteOrigin
    }
}

public extension MeterChange {
    init(publicly _: Void = (), at: [String: JSONValue]? = nil, numerator: Int, denominator: Int) {
        self.at = at; self.numerator = numerator; self.denominator = denominator
    }
}

public extension TempoChange {
    init(publicly _: Void = (), at: [String: JSONValue]? = nil, quarterNotesPerMinute: Double) {
        self.at = at; self.quarterNotesPerMinute = quarterNotesPerMinute
    }
}

public extension EventTrack {
    init(publicly _: Void = (), id: String, name: String? = nil, instrument: String, performer: String? = nil, role: String? = nil, events: [PerformanceEvent]? = nil, parts: [TrackPart]? = nil) {
        self.id = id; self.name = name; self.instrument = instrument; self.performer = performer
        self.role = role; self.events = events; self.parts = parts
    }
}

public extension TrackPart {
    init(publicly _: Void = (), section: String? = nil, entry: String? = nil, mode: PartMode? = nil, events: [PerformanceEvent]) {
        self.section = section; self.entry = entry; self.mode = mode; self.events = events
    }
}

public extension PerformanceEvent {
    init(
        publicly _: Void = (),
        id: String? = nil,
        at: EventTime,
        duration: EventDuration? = nil,
        type: String? = nil,
        action: String? = nil,
        gesture: String? = nil,
        target: String? = nil,
        targets: [String]? = nil,
        parameter: String? = nil,
        parameters: [String: JSONValue]? = nil,
        techniques: [String]? = nil,
        changes: [StateChange]? = nil,
        curve: [JSONValue]? = nil
    ) {
        self.id = id; self.at = at; self.duration = duration; self.type = type; self.action = action
        self.gesture = gesture; self.target = target; self.targets = targets; self.parameter = parameter
        self.parameters = parameters; self.techniques = techniques; self.changes = changes; self.curve = curve
    }
}

public extension EventTime {
    init(publicly _: Void = (), musical: MusicalPosition? = nil, absolute: Quantity? = nil) { self.musical = musical; self.absolute = absolute }
}

public extension EventDuration {
    init(publicly _: Void = (), quarterNotes: JSONValue? = nil, value: Double? = nil, unit: String? = nil) {
        self.quarterNotes = quarterNotes; self.value = value; self.unit = unit
    }
}
