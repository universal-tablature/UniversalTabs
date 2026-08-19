import UTABComposerCore
import UTABComposerText
import UTABInstruments

public struct TextInstrumentCatalogResult: Sendable {
    public let catalog: InstrumentCatalog
    /// Unqualified and module-qualified names exported by the loaded language modules.
    public let modelBindings: [String: InstrumentID]
    public let diagnostics: [TextDiagnostic]

    public var succeeded: Bool { !diagnostics.contains { $0.severity == .error } }
}

/// Builds a catalogue from dependency-ordered language modules. Model and tuning IDs are
/// explicit when supplied, otherwise they are deterministically derived from module and symbol names.
public struct TextInstrumentCatalogCompiler: Sendable {
    public init() {}

    public func compile(_ modules: [TextLoadedModule], extending base: InstrumentCatalog) -> TextInstrumentCatalogResult {
        var worker = Worker(base: base)
        for module in modules { worker.addModels(from: module) }
        for module in modules { worker.applyExtensions(from: module) }
        return .init(catalog: worker.catalog, modelBindings: worker.symbols, diagnostics: worker.diagnostics)
    }

    private struct Worker {
        let profiles: [InstrumentProfileDefinition]
        var tunings: [InstrumentTuningDefinition]
        var models: [InstrumentModelDefinition]
        var symbols: [String: InstrumentID]
        var diagnostics: [TextDiagnostic] = []

        init(base: InstrumentCatalog) {
            profiles = base.profiles
            tunings = base.tunings
            models = base.models
            symbols = Dictionary(uniqueKeysWithValues: base.models.map { ($0.name, $0.id) })
        }

        var catalog: InstrumentCatalog { .init(tunings: tunings, profiles: profiles, models: models) }

        mutating func addModels(from module: TextLoadedModule) {
            for syntax in module.syntax.models {
                let symbol = String(syntax.symbol.lexeme)
                let qualifiedSymbol = "\(module.name).\(symbol)"
                guard symbols[symbol] == nil, symbols[qualifiedSymbol] == nil else {
                    error("Duplicate instrument model '\(symbol)'", at: syntax.range); continue
                }
                let profileName = syntax.profile.stringValue ?? String(syntax.profile.lexeme)
                guard let profile = profiles.first(where: { $0.id.rawValue == profileName }) else {
                    error("Unknown instrument profile '\(profileName)'", at: syntax.profile.range); continue
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
                symbols[symbol] = model.id
                symbols[qualifiedSymbol] = model.id
            }
        }

        mutating func applyExtensions(from module: TextLoadedModule) {
            for syntax in module.syntax.extensions {
                let target = String(syntax.model.lexeme)
                guard let modelID = symbols[target], let index = models.firstIndex(where: { $0.id == modelID }) else {
                    error("Unknown instrument model '\(target)'", at: syntax.model.range); continue
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

        func property(_ name: String, in properties: [TextPropertySyntax]) -> String? {
            properties.first { String($0.name.lexeme) == name }.map { $0.value.stringValue ?? String($0.value.lexeme) }
        }

        func instrumentValue(_ token: TextToken) -> InstrumentValue {
            if let value = token.integerValue { return .integer(value) }
            if token.kind == .decimalLiteral, let value = token.decimalValue { return .decimal(value) }
            if let value = token.stringValue { return .text(value) }
            if token.lexeme == "true" { return .boolean(true) }
            if token.lexeme == "false" { return .boolean(false) }
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
