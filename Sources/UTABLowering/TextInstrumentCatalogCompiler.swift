import UTABComposerCore
import UTABComposerText
import UTABInstruments

public struct TextInstrumentCatalogResult: Sendable {
    public let catalog: InstrumentCatalog
    public let scaleBindings: [String: InstrumentID]
    public let profileBindings: [String: InstrumentID]
    /// Names visible to the root module, plus fully qualified names from loaded modules.
    public let modelBindings: [String: InstrumentID]
    public let diagnostics: [TextDiagnostic]

    public var succeeded: Bool { !diagnostics.contains { $0.severity == .error } }
}

/// Builds a catalogue from dependency-ordered language modules. Model and tuning IDs are
/// explicit when supplied, otherwise they are deterministically derived from module and symbol names.
public struct TextInstrumentCatalogCompiler: Sendable {
    public init() {}

    public func compile(_ modules: [TextLoadedModule], extending base: InstrumentCatalog) -> TextInstrumentCatalogResult {
        var worker = Worker(base: base, modules: modules)
        worker.addConstants()
        for module in modules { worker.addScales(from: module) }
        for module in modules { worker.addProfiles(from: module) }
        for module in modules { worker.addModels(from: module) }
        for module in modules { worker.applyExtensions(from: module) }
        if let root = modules.first(where: \.isRoot) {
            worker.validateInstrumentReferences(in: root)
        }
        return .init(
            catalog: worker.catalog,
            scaleBindings: worker.visibleBindings(worker.scaleSymbols),
            profileBindings: worker.visibleBindings(worker.profileSymbols),
            modelBindings: worker.visibleBindings(worker.modelSymbols),
            diagnostics: worker.diagnostics
        )
    }

    private struct Worker {
        var scales: [InstrumentScaleDefinition]
        var profiles: [InstrumentProfileDefinition]
        var tunings: [InstrumentTuningDefinition]
        var fingerings: [FingeringDefinition]
        var chordShapes: [ChordShapeDefinition]
        var models: [InstrumentModelDefinition]
        let modules: [TextLoadedModule]
        var modelSymbols: [String: InstrumentID]
        var profileSymbols: [String: InstrumentID]
        var scaleSymbols: [String: InstrumentID]
        var integerConstants: [String: Int]
        var diagnostics: [TextDiagnostic] = []

        init(base: InstrumentCatalog, modules: [TextLoadedModule]) {
            scales = base.scales
            profiles = base.profiles
            tunings = base.tunings
            fingerings = base.fingerings
            chordShapes = base.chordShapes
            models = base.models
            self.modules = modules
            modelSymbols = [:]
            profileSymbols = [:]
            scaleSymbols = [:]
            integerConstants = [:]
        }

        var catalog: InstrumentCatalog { .init(scales: scales, tunings: tunings, fingerings: fingerings, chordShapes: chordShapes, profiles: profiles, models: models) }

        mutating func addConstants() {
            for module in modules {
                for constant in module.syntax.constants {
                    let qualified = "\(module.name).\(constant.name.lexeme)"
                    guard integerConstants[qualified] == nil else {
                        error("Duplicate constant '\(constant.name.lexeme)'", at: constant.range)
                        continue
                    }
                    if let value = constant.value.integerValue { integerConstants[qualified] = value }
                }
            }
        }

        mutating func addScales(from module: TextLoadedModule) {
            for syntax in module.syntax.scaleDefinitions {
                let symbol = String(syntax.symbol.lexeme)
                let qualifiedSymbol = "\(module.name).\(symbol)"
                guard scaleSymbols[qualifiedSymbol] == nil else {
                    error("Duplicate scale definition '\(symbol)'", at: syntax.range); continue
                }
                let intervals = syntax.centIntervals.compactMap(\.integerValue)
                guard intervals.count == syntax.centIntervals.count,
                      intervals.first == 0,
                      intervals.allSatisfy({ 0 <= $0 && $0 < 1_200 }),
                      zip(intervals, intervals.dropFirst()).allSatisfy(<) else {
                    error("Scale '\(symbol)' must start at 0 cents and contain strictly increasing offsets below 1200 cents", at: syntax.range)
                    continue
                }
                let id = InstrumentID(rawValue: "scale:\(module.name):\(symbol)")
                guard !scales.contains(where: { $0.id == id }) else {
                    error("Duplicate scale ID '\(id)'", at: syntax.range); continue
                }
                scales.append(.init(id: id, name: symbol, centIntervals: intervals))
                scaleSymbols[qualifiedSymbol] = id
            }
        }

        mutating func addProfiles(from module: TextLoadedModule) {
            for syntax in module.syntax.profiles {
                let symbol = String(syntax.symbol.lexeme)
                let qualifiedSymbol = "\(module.name).\(symbol)"
                guard profileSymbols[qualifiedSymbol] == nil else {
                    error("Duplicate instrument profile '\(symbol)'", at: syntax.range); continue
                }
                let idString = property("id", in: syntax.properties) ?? "profile:\(module.name):\(symbol)"
                guard !profiles.contains(where: { $0.id.rawValue == idString }) else {
                    error("Duplicate instrument profile ID '\(idString)'", at: syntax.range); continue
                }
                let actuators = syntax.actuators.compactMap { lowerActuator($0) }
                let actuatorNames = Set(actuators.map(\.id))
                let interactions = syntax.interactions.compactMap { interaction -> Interaction? in
                    let targets = interaction.targets.map { String($0.lexeme) }
                    let unknown = targets.filter { !actuatorNames.contains($0) }
                    guard unknown.isEmpty else {
                        error("Interaction '\(interaction.name.lexeme)' targets unknown actuator group '\(unknown[0])'", at: interaction.range)
                        return nil
                    }
                    return .init(
                        String(interaction.name.lexeme),
                        targets: targets,
                        effectors: interaction.effectors.map { String($0.lexeme) },
                        arguments: interaction.arguments.map {
                            .init(
                                String($0.name.lexeme),
                                values: $0.values.map { String($0.lexeme) },
                                isRequired: $0.isRequired
                            )
                        },
                        modifiers: interaction.modifiers.map { String($0.lexeme) },
                        parameters: interaction.parameters.map { parameter in
                            .init(
                                String(parameter.name.lexeme),
                                properties: Dictionary(uniqueKeysWithValues: parameter.properties.map {
                                    (String($0.name.lexeme), instrumentValue($0.value))
                                })
                            )
                        }
                    )
                }
                let techniques = syntax.techniques.compactMap { technique -> InstrumentTechnique? in
                    let target = property("target", in: technique.properties)
                    if let target, !actuatorNames.contains(target) {
                        error("Technique '\(technique.name.lexeme)' targets unknown actuator group '\(target)'", at: technique.range)
                        return nil
                    }
                    return .init(String(technique.name.lexeme), target: target)
                }
                let profile = InstrumentProfileDefinition(
                    id: .init(rawValue: idString),
                    version: property("version", in: syntax.properties) ?? "1",
                    actuators: actuators,
                    interactions: interactions,
                    techniques: techniques
                )
                profiles.append(profile)
                profileSymbols[qualifiedSymbol] = profile.id
            }
        }

        mutating func lowerActuator(_ syntax: TextActuatorSyntax) -> ActuatorGroup? {
            let name = String(syntax.name.lexeme)
            let cardinality: ActuatorCardinality
            if let count = integerProperty("count", in: syntax.properties) {
                guard count >= 0 else { error("Actuator count cannot be negative", at: syntax.range); return nil }
                cardinality = .exact(count)
            } else if let minimum = integerProperty("minimumCount", in: syntax.properties),
                      let maximum = integerProperty("maximumCount", in: syntax.properties) {
                guard minimum >= 0, maximum >= minimum else { error("Invalid actuator cardinality range", at: syntax.range); return nil }
                cardinality = .range(minimum...maximum)
            } else {
                cardinality = .unconstrained
            }
            let controlName = property("control", in: syntax.properties) ?? "discrete"
            let control: ActuatorControl
            switch controlName {
            case "discrete": control = .discrete
            case "binary": control = .binary
            case "continuous":
                if let minimum = decimalProperty("minimum", in: syntax.properties),
                   let maximum = decimalProperty("maximum", in: syntax.properties), minimum <= maximum {
                    control = .continuous(range: minimum...maximum)
                } else { control = .continuous(range: nil) }
            case "orderedBitset":
                guard let width = integerProperty("width", in: syntax.properties), width > 0 else {
                    error("An orderedBitset actuator requires a positive width", at: syntax.range); return nil
                }
                control = .orderedBitset(width: width)
            default:
                error("Unknown actuator control '\(controlName)'", at: syntax.range); return nil
            }
            return .init(name, cardinality: cardinality, control: control)
        }

        mutating func addModels(from module: TextLoadedModule) {
            for syntax in module.syntax.models {
                let symbol = String(syntax.symbol.lexeme)
                let qualifiedSymbol = "\(module.name).\(symbol)"
                guard modelSymbols[qualifiedSymbol] == nil else {
                    error("Duplicate instrument model '\(symbol)'", at: syntax.range); continue
                }
                guard let profileID = resolve(syntax.profile, from: module, symbols: profileSymbols, kind: "instrument profile"),
                      let profile = profiles.first(where: { $0.id == profileID }) else {
                    continue
                }
                let id = property("id", in: syntax.properties) ?? "instrument:\(module.name):\(symbol)"
                guard !models.contains(where: { $0.id.rawValue == id }) else {
                    error("Duplicate instrument model ID '\(id)'", at: syntax.range); continue
                }
                let name = property("name", in: syntax.properties) ?? symbol
                let geometry = syntax.geometries.map { lowerGeometry($0, from: module) }
                let midiProgram = resolveIntegerProperty("midiProgram", in: syntax.properties, from: module)
                if let midiProgram, !(1...128).contains(midiProgram) {
                    error("MIDI program must be in the documented 1...128 range", at: syntax.range)
                    continue
                }
                let midiPercussion = property("midiPercussion", in: syntax.properties) == "true"
                let midi = midiProgram == nil && !midiPercussion ? nil : MIDIRealization(program: midiProgram, percussion: midiPercussion)
                let realization = midi.map { InstrumentRealization(midi: $0) }
                let model = InstrumentModelDefinition(id: .init(rawValue: id), name: name, profile: profile.id, geometry: geometry, realization: realization)
                models.append(model)
                modelSymbols[qualifiedSymbol] = model.id
            }
        }

        mutating func lowerGeometry(_ syntax: TextGeometrySyntax, from module: TextLoadedModule) -> InstrumentGeometry {
            var properties: [String: InstrumentValue] = [:]
            for propertySyntax in syntax.properties {
                let name = String(propertySyntax.name.lexeme)
                if name == "scale" {
                    if let id = resolveScale(propertySyntax.value, from: module) {
                        properties[name] = .scale(id)
                    }
                } else if name == "scales" {
                    let ids = propertySyntax.values.compactMap { resolveScale($0, from: module) }
                    if ids.count == propertySyntax.values.count {
                        properties[name] = .list(ids.map(InstrumentValue.scale))
                    }
                } else if propertySyntax.values.count > 1 {
                    properties[name] = .list(propertySyntax.values.map(instrumentValue))
                } else {
                    properties[name] = instrumentValue(propertySyntax.value)
                }
            }
            return .init(String(syntax.name.lexeme), properties: properties)
        }

        mutating func resolveScale(_ token: TextToken, from module: TextLoadedModule) -> InstrumentID? {
            let name = token.stringValue ?? String(token.lexeme)
            if token.kind == .stringLiteral {
                if let scale = scales.first(where: { $0.id.rawValue == name }) { return scale.id }
                error("Unknown scale '\(name)'", at: token.range)
                return nil
            }
            let localName = "\(module.name).\(name)"
            if let id = scaleSymbols[localName] { return id }
            let candidates = module.syntax.imports.compactMap { scaleSymbols["\($0.name.value).\(name)"] }
            if candidates.count == 1 { return candidates[0] }
            if candidates.count > 1 { error("Ambiguous scale '\(name)'", at: token.range); return nil }
            error("Unknown scale '\(name)'", at: token.range)
            return nil
        }

        mutating func applyExtensions(from module: TextLoadedModule) {
            for syntax in module.syntax.extensions {
                let target = syntax.model.value
                guard let modelID = resolve(syntax.model, from: module, symbols: modelSymbols, kind: "instrument model"),
                      let index = models.firstIndex(where: { $0.id == modelID }) else {
                    continue
                }
                var model = models[index]
                var tuningIDs = model.tunings
                var defaultTuning = model.defaultTuning
                var fingeringIDs = model.fingerings
                var defaultFingering = model.defaultFingering
                for tuningSyntax in syntax.tunings {
                    let symbol = String(tuningSyntax.symbol.lexeme)
                    let idString = property("id", in: tuningSyntax.properties) ?? "tuning:\(module.name):\(symbol)"
                    guard !tunings.contains(where: { $0.id.rawValue == idString }) else {
                        error("Duplicate tuning ID '\(idString)'", at: tuningSyntax.range); continue
                    }
                    let parsedCourses = tuningSyntax.courses.map { course in course.compactMap(parsePitch) }
                    guard !parsedCourses.isEmpty, zip(parsedCourses, tuningSyntax.courses).allSatisfy({ $0.count == $1.count }) else {
                        error("A tuning requires valid pitches in every course", at: tuningSyntax.range); continue
                    }
                    let tuningID = InstrumentID(rawValue: idString)
                    if tuningSyntax.isDefault, defaultTuning != nil, defaultTuning != tuningID {
                        error("Instrument '\(target)' already has a default tuning", at: tuningSyntax.range); continue
                    }
                    tunings.append(.init(
                        id: tuningID,
                        name: property("name", in: tuningSyntax.properties) ?? symbol,
                        courses: parsedCourses.map(TuningCourse.init),
                        tags: Set(tuningSyntax.tags.map { String($0.lexeme) })
                    ))
                    tuningIDs.append(tuningID)
                    if tuningSyntax.isDefault { defaultTuning = tuningID }
                }
                for fingeringSyntax in syntax.fingerings {
                    let symbol = String(fingeringSyntax.symbol.lexeme)
                    let idString = property("id", in: fingeringSyntax.properties) ?? "fingering:\(module.name):\(symbol)"
                    guard !fingerings.contains(where: { $0.id.rawValue == idString }) else {
                        error("Duplicate fingering ID '\(idString)'", at: fingeringSyntax.range); continue
                    }
                    guard let actuatorGroup = property("actuators", in: fingeringSyntax.properties),
                          let profile = profiles.first(where: { $0.id == model.profile }),
                          profile.actuators.contains(where: { $0.id == actuatorGroup }) else {
                        error("A fingering requires a valid actuators group", at: fingeringSyntax.range); continue
                    }
                    let bitOrder = fingeringSyntax.bitOrder.map { String($0.lexeme) }
                    guard !bitOrder.isEmpty else { error("A fingering requires a non-empty bitOrder", at: fingeringSyntax.range); continue }
                    let entries = fingeringSyntax.entries.compactMap { entry -> FingeringEntry? in
                        let pattern = entry.pattern.stringValue ?? String(entry.pattern.lexeme)
                        guard pattern.count == bitOrder.count, pattern.allSatisfy({ $0 == "0" || $0 == "1" || $0 == "h" || $0 == "x" }) else {
                            error("Fingering pattern must contain exactly \(bitOrder.count) characters from 0, 1, h, or x", at: entry.pattern.range); return nil
                        }
                        let result: FingeringResult
                        if let token = entry.pitch, let pitch = parsePitch(token) { result = .pitch(pitch) }
                        else if let effect = entry.effect { result = .effect(String(effect.lexeme)) }
                        else { error("Invalid fingering result", at: entry.range); return nil }
                        let preference = entry.preference?.lexeme == "alternate" ? FingeringPreference.alternate : .preferred
                        return .init(pattern: pattern, result: result, register: entry.register?.integerValue, preference: preference, label: entry.label?.stringValue)
                    }
                    let parent = property("extends", in: fingeringSyntax.properties).map(InstrumentID.init(rawValue:))
                    let fingeringID = InstrumentID(rawValue: idString)
                    if fingeringSyntax.isDefault, defaultFingering != nil, defaultFingering != fingeringID {
                        error("Instrument '\(target)' already has a default fingering", at: fingeringSyntax.range); continue
                    }
                    fingerings.append(.init(id: fingeringID, name: property("name", in: fingeringSyntax.properties) ?? symbol, model: model.id, actuatorGroup: actuatorGroup, bitOrder: bitOrder, parent: parent, entries: entries))
                    fingeringIDs.append(fingeringID)
                    if fingeringSyntax.isDefault { defaultFingering = fingeringID }
                }
                for shapeSyntax in syntax.chordShapes {
                    let symbol = String(shapeSyntax.symbol.lexeme)
                    let id = InstrumentID(rawValue: "chord-shape:\(module.name):\(model.id.rawValue):\(symbol)")
                    guard !chordShapes.contains(where: { $0.id == id || ($0.model == model.id && $0.name == symbol) }) else {
                        error("Duplicate chord shape '\(symbol)' for instrument '\(target)'", at: shapeSyntax.range)
                        continue
                    }
                    guard let root = parsePitchClass(String(shapeSyntax.root.lexeme)),
                          let quality = parseChordQuality(String(shapeSyntax.quality.lexeme)) else {
                        error("Chord shape '\(symbol)' has an unsupported chord", at: shapeSyntax.range)
                        continue
                    }
                    let positions = shapeSyntax.strings.compactMap { item -> ChordShapeString? in
                        guard let number = item.number.integerValue, let fret = item.fret.integerValue, number > 0, fret >= 0 else {
                            error("Chord shape string and fret numbers must be non-negative", at: item.range)
                            return nil
                        }
                        return .init(stringNumber: number, fret: fret)
                    }
                    guard !positions.isEmpty, Set(positions.map(\.stringNumber)).count == positions.count else {
                        error("Chord shape '\(symbol)' requires unique string positions", at: shapeSyntax.range)
                        continue
                    }
                    chordShapes.append(.init(id: id, name: symbol, model: model.id, root: root, quality: quality, strings: positions))
                }
                model = .init(id: model.id, name: model.name, profile: model.profile, geometry: model.geometry, tunings: tuningIDs, defaultTuning: defaultTuning, fingerings: fingeringIDs, defaultFingering: defaultFingering, defaults: model.defaults, realization: model.realization)
                models[index] = model
            }
        }

        mutating func validateInstrumentReferences(in module: TextLoadedModule) {
            for instrument in module.syntax.instruments {
                _ = resolve(instrument.model, from: module, symbols: modelSymbols, kind: "instrument model")
            }
        }

        mutating func resolve(
            _ reference: TextSymbolReferenceSyntax,
            from module: TextLoadedModule,
            symbols: [String: InstrumentID],
            kind: String
        ) -> InstrumentID? {
            let name = reference.value
            if reference.isStableID {
                let definitions = kind == "instrument profile" ? profiles.map { $0.id } : models.map { $0.id }
                if let id = definitions.first(where: { $0.rawValue == name }) { return id }
                error("Unknown \(kind) '\(name)'", at: reference.range)
                return nil
            }
            if reference.isQualified {
                if let id = symbols[name] { return id }
                error("Unknown \(kind) '\(name)'", at: reference.range)
                return nil
            }

            let localName = "\(module.name).\(name)"
            if let id = symbols[localName] { return id }
            let candidates = module.syntax.imports
                .map { "\($0.name.value).\(name)" }
                .compactMap { qualified in symbols[qualified].map { (qualified, $0) } }
            if candidates.count == 1 { return candidates[0].1 }
            if candidates.count > 1 {
                error("Ambiguous \(kind) '\(name)'; use one of: \(candidates.map(\.0).sorted().joined(separator: ", "))", at: reference.range)
                return nil
            }

            let baseMatches: [InstrumentID]
            if kind == "instrument profile" {
                baseMatches = profiles.filter { $0.id.rawValue == name }.map { $0.id }
            } else {
                baseMatches = models.filter { $0.name == name || $0.id.rawValue == name }.map { $0.id }
            }
            if baseMatches.count == 1 { return baseMatches[0] }
            error("Unknown \(kind) '\(name)'", at: reference.range)
            return nil
        }

        func visibleBindings(_ symbols: [String: InstrumentID]) -> [String: InstrumentID] {
            var result = symbols
            guard let root = modules.first(where: \.isRoot) else { return result }
            let localPrefix = "\(root.name)."
            for (qualified, id) in symbols where qualified.hasPrefix(localPrefix) {
                result[String(qualified.dropFirst(localPrefix.count))] = id
            }
            var imported: [String: [(String, InstrumentID)]] = [:]
            for importedModule in root.syntax.imports.map(\.name.value) {
                let prefix = "\(importedModule)."
                for (qualified, id) in symbols where qualified.hasPrefix(prefix) {
                    imported[String(qualified.dropFirst(prefix.count)), default: []].append((qualified, id))
                }
            }
            for (name, candidates) in imported where result[name] == nil && candidates.count == 1 {
                result[name] = candidates[0].1
            }
            return result
        }

        func property(_ name: String, in properties: [TextPropertySyntax]) -> String? {
            properties.first { String($0.name.lexeme) == name }.map { $0.value.stringValue ?? String($0.value.lexeme) }
        }

        func integerProperty(_ name: String, in properties: [TextPropertySyntax]) -> Int? {
            properties.first { String($0.name.lexeme) == name }?.value.integerValue
        }

        mutating func resolveIntegerProperty(_ name: String, in properties: [TextPropertySyntax], from module: TextLoadedModule) -> Int? {
            guard let property = properties.first(where: { String($0.name.lexeme) == name }) else { return nil }
            if let literal = property.value.integerValue { return literal }
            guard let reference = property.reference else {
                error("Expected an integer or constant reference for '\(name)'", at: property.range)
                return nil
            }
            if let direct = integerConstants[reference] { return direct }
            let parts = reference.split(separator: ".")
            if parts.count > 1,
               let imported = module.syntax.imports.first(where: { $0.name.value.split(separator: ".").last == parts.first }) {
                let suffix = parts.dropFirst().joined(separator: ".")
                if let value = integerConstants["\(imported.name.value).\(suffix)"] { return value }
            }
            error("Unknown integer constant '\(reference)'", at: property.range)
            return nil
        }

        func decimalProperty(_ name: String, in properties: [TextPropertySyntax]) -> Double? {
            properties.first { String($0.name.lexeme) == name }?.value.decimalValue
        }

        func instrumentValue(_ token: TextToken) -> InstrumentValue {
            if let value = token.integerValue { return .integer(value) }
            if token.kind == .decimalLiteral, let value = token.decimalValue { return .decimal(value) }
            if let value = token.stringValue { return .text(value) }
            if token.lexeme == "true" { return .boolean(true) }
            if token.lexeme == "false" { return .boolean(false) }
            if let pitch = parsePitch(token) { return .pitch(pitch) }
            return .text(String(token.lexeme))
        }

        func parsePitch(_ token: TextToken) -> AbsolutePitch? {
            let text = String(token.lexeme)
            guard let first = text.first, let letter = NoteLetter(rawValue: ["C", "D", "E", "F", "G", "A", "B"].firstIndex(of: String(first).uppercased()) ?? -1) else { return nil }
            var index = text.index(after: text.startIndex)
            var accidental = 0
            while index < text.endIndex, text[index] == "#" || text[index] == "b" {
                accidental += text[index] == "#" ? 1 : -1
                index = text.index(after: index)
            }
            guard let octave = Int(text[index...]) else { return nil }
            return .init(.init(letter, accidental: accidental), octave: octave)
        }

        func parsePitchClass(_ text: String) -> PitchClass? {
            let names = ["C": 0, "C#": 1, "Db": 1, "D": 2, "D#": 3, "Eb": 3,
                         "E": 4, "F": 5, "F#": 6, "Gb": 6, "G": 7, "G#": 8,
                         "Ab": 8, "A": 9, "A#": 10, "Bb": 10, "B": 11]
            return names[text].flatMap(PitchClass.init(rawValue:))
        }

        func parseChordQuality(_ text: String) -> ChordQuality? {
            switch text {
            case "major": .major
            case "minor": .minor
            case "diminished": .diminished
            case "sus4", "suspendedFourth": .suspendedFourth
            default: nil
            }
        }

        mutating func error(_ message: String, at range: SourceRange) {
            diagnostics.append(.init(.error, message: message, range: range))
        }
    }
}
