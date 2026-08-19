import UTABComposerCore
import UTABComposerText
import UTABInstruments

public struct TextInstrumentCatalogResult: Sendable {
    public let catalog: InstrumentCatalog
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
        for module in modules { worker.addProfiles(from: module) }
        for module in modules { worker.addModels(from: module) }
        for module in modules { worker.applyExtensions(from: module) }
        if let root = modules.first(where: \.isRoot) {
            worker.validateInstrumentReferences(in: root)
        }
        return .init(
            catalog: worker.catalog,
            profileBindings: worker.visibleBindings(worker.profileSymbols),
            modelBindings: worker.visibleBindings(worker.modelSymbols),
            diagnostics: worker.diagnostics
        )
    }

    private struct Worker {
        var profiles: [InstrumentProfileDefinition]
        var tunings: [InstrumentTuningDefinition]
        var models: [InstrumentModelDefinition]
        let modules: [TextLoadedModule]
        var modelSymbols: [String: InstrumentID]
        var profileSymbols: [String: InstrumentID]
        var diagnostics: [TextDiagnostic] = []

        init(base: InstrumentCatalog, modules: [TextLoadedModule]) {
            profiles = base.profiles
            tunings = base.tunings
            models = base.models
            self.modules = modules
            modelSymbols = [:]
            profileSymbols = [:]
        }

        var catalog: InstrumentCatalog { .init(tunings: tunings, profiles: profiles, models: models) }

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
                        effectors: interaction.effectors.map { String($0.lexeme) }
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
                let geometry = syntax.geometries.map { geometry in
                    InstrumentGeometry(String(geometry.name.lexeme), properties: Dictionary(uniqueKeysWithValues: geometry.properties.map {
                        (String($0.name.lexeme), instrumentValue($0.value))
                    }))
                }
                let model = InstrumentModelDefinition(id: .init(rawValue: id), name: name, profile: profile.id, geometry: geometry)
                models.append(model)
                modelSymbols[qualifiedSymbol] = model.id
            }
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
                model = .init(id: model.id, name: model.name, profile: model.profile, geometry: model.geometry, tunings: tuningIDs, defaultTuning: defaultTuning, defaults: model.defaults)
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

        mutating func error(_ message: String, at range: SourceRange) {
            diagnostics.append(.init(.error, message: message, range: range))
        }
    }
}
