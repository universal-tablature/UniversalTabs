// Copyright 2026 Mattias Holm
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import UTABComposerCore

public struct TextParser: Sendable {
    public init() {}

    public func parse(_ source: TextSource) -> TextParseResult {
        let lexed = TextLexer().lex(source)
        var parser = Parser(tokens: lexed.tokens, diagnostics: lexed.diagnostics)
        let syntax = parser.parseDocument()
        return .init(syntax: parser.hasErrors ? nil : syntax, tokens: lexed.tokens, diagnostics: parser.diagnostics)
    }

    private struct Parser {
        enum ScopedUsing {
            case technique(TextToken)
            case dynamic(TextToken)
            case voiceLeading(TextToken)
        }

        let tokens: [TextToken]
        var index = 0
        var notation: TextQualifiedNameSyntax?
        var notationUses: [TextQualifiedNameSyntax] = []
        var diagnostics: [TextDiagnostic]
        var hasErrors: Bool { diagnostics.contains { $0.severity == .error } }
        var current: TextToken { tokens[index] }

        mutating func parseDocument() -> TextCompositionSyntax {
            let start = current.range.start
            var title: TextToken?
            var module: TextQualifiedNameSyntax?
            var imports: [TextImportSyntax] = []
            var constants: [TextConstantSyntax] = []
            var namingSystems: [TextNamingSyntax] = []
            var scaleDefinitions: [TextScaleDefinitionSyntax] = []
            var chordQualityDefinitions: [TextChordQualityDefinitionSyntax] = []
            var profiles: [TextInstrumentProfileSyntax] = []
            var models: [TextInstrumentModelSyntax] = []
            var extensions: [TextInstrumentExtensionSyntax] = []
            var meter: (TextToken, TextToken)?
            var tempo: TextToken?
            var scale: (TextToken, TextToken)?
            var instruments: [TextInstrumentInstanceSyntax] = []
            var performancePatterns: [TextPerformancePatternSyntax] = []
            var bassPatterns: [TextBassPatternSyntax] = []
            var phrases: [TextPhraseSyntax] = []
            var sections: [TextSectionSyntax] = []
            var main: [TextToken] = []
            var compositionBody = false
            var compositionClosed = false
            var compositionNotation: TextQualifiedNameSyntax?

            while current.kind != .endOfFile {
                if takeKeyword("composition") {
                    if compositionBody || compositionClosed { diagnose("Only one composition body is allowed") }
                    _ = expect(.leftBrace, "Expected '{' after composition")
                    compositionBody = true
                    parseNotationDirective()
                    compositionNotation = notation
                } else if current.kind == .rightBrace && compositionBody {
                    advance()
                    compositionBody = false
                    compositionClosed = true
                    notation = nil
                } else if takeKeyword("module") { module = parseQualifiedName() }
                else if takeKeyword("import") {
                    if let name = parseQualifiedName() { imports.append(.init(name: name, range: name.range)) }
                } else if takeKeyword("naming") {
                    if let system = parseNaming() { namingSystems.append(system) }
                } else if takeKeyword("let") {
                    if let name = expect(.identifier, "Expected constant name") {
                        _ = take(.equal)
                        if let value = parseConstantValue() {
                            constants.append(.init(name: name, notation: notation, value: value.value, range: spanning(name, value.end)))
                        }
                    }
                } else if takeKeyword("profile") {
                    if let profile = parseInstrumentProfile() { profiles.append(profile) }
                } else if takeKeyword("model") {
                    if let model = parseInstrumentModel() { models.append(model) }
                } else if takeKeyword("extension") {
                    if let value = parseInstrumentExtension() { extensions.append(value) }
                } else if takeKeyword("title") { title = expect(.stringLiteral, "Expected a quoted title") }
                else if takeKeyword("meter") {
                    let numerator = expect(.integerLiteral, "Expected meter numerator")
                    _ = expect(.slash, "Expected '/' in meter")
                    let denominator = expect(.integerLiteral, "Expected meter denominator")
                    if let numerator, let denominator { meter = (numerator, denominator) }
                } else if takeKeyword("tempo") { tempo = expectNumber("Expected tempo") }
                else if takeKeyword("scale") {
                    let first = expect(.identifier, "Expected scale name or tonic")
                    if let first, current.kind == .leftBrace {
                        if let definition = parseScaleDefinition(symbol: first) { scaleDefinitions.append(definition) }
                    } else {
                        let mode = expect(.identifier, "Expected scale mode")
                        if let first, let mode { scale = (first, mode) }
                    }
                } else if takeKeyword("chordQuality") {
                    if let definition = parseChordQualityDefinition() { chordQualityDefinitions.append(definition) }
                } else if takeKeyword("instrument") {
                    if let instrument = parseInstrumentInstance() { instruments.append(instrument) }
                } else if takeKeyword("performancePattern") {
                    if let pattern = parsePerformancePattern() { performancePatterns.append(pattern) }
                } else if takeKeyword("bassPattern") {
                    if let pattern = parseBassPattern() { bassPatterns.append(pattern) }
                } else if takeKeyword("phrase") { if let value = parsePhrase() { phrases.append(value) } }
                else if takeKeyword("section") { if let value = parseSection() { sections.append(value) } }
                else if takeKeyword("main") { main = parseNameBlock() }
                else {
                    diagnose("Expected module, import, profile, model, extension, title, meter, tempo, scale, chordQuality, instrument, performancePattern, bassPattern, phrase, section, or main declaration")
                    advance()
                }
                _ = take(.semicolon)
            }
            if compositionBody { diagnose("Expected closing composition brace") }
            return .init(
                module: module,
                imports: imports,
                notationUses: notationUses,
                defaultNotation: compositionNotation,
                namingSystems: namingSystems,
                constants: constants,
                scaleDefinitions: scaleDefinitions,
                chordQualityDefinitions: chordQualityDefinitions,
                profiles: profiles,
                models: models,
                extensions: extensions,
                title: title,
                meter: meter,
                tempo: tempo,
                scale: scale,
                instruments: instruments,
                performancePatterns: performancePatterns,
                bassPatterns: bassPatterns,
                phrases: phrases,
                sections: sections,
                main: main,
                range: .init(fileID: current.range.fileID, start: start, end: current.range.end)
            )
        }

        mutating func parseChordQualityDefinition() -> TextChordQualityDefinitionSyntax? {
            guard let symbol = expect(.identifier, "Expected chord-quality name"),
                  let open = expect(.leftBrace, "Expected '{' after chord-quality name") else { return nil }
            var degrees: [TextToken] = []
            var semitones: [TextToken] = []
            while current.kind != .rightBrace && current.kind != .endOfFile {
                if take(.semicolon) { continue }
                let destination: Bool
                if takeKeyword("degrees") { destination = true }
                else if takeKeyword("semitones") { destination = false }
                else { diagnose("Expected degrees or semitones in chord quality"); synchronizeBlockItem(); continue }
                while current.kind == .integerLiteral || current.kind == .comma {
                    if take(.comma) { continue }
                    if destination { degrees.append(advance()) } else { semitones.append(advance()) }
                }
                _ = take(.semicolon)
            }
            let close = expect(.rightBrace, "Expected '}' after chord quality") ?? current
            return .init(symbol: symbol, degrees: degrees, semitones: semitones, range: spanning(open, close))
        }

        mutating func parseConstantValue() -> (value: TextConstantSyntax.Value, end: TextToken)? {
            if current.kind == .integerLiteral {
                let token = advance()
                return (.integer(token), token)
            }
            if take(.atSign) {
                guard let degree = expect(.integerLiteral, "Expected scale degree after '@'") else { return nil }
                let alteration = parseAlteration()
                return (.scaleDegree(degree: degree, alteration: alteration), tokens[index - 1])
            }
            if takeKeyword("chord") {
                if take(.atSign) {
                    guard let degree = expect(.integerLiteral, "Expected scale degree after '@'") else { return nil }
                    let alteration = parseAlteration()
                    guard let quality = expect(.identifier, "Expected chord quality") else { return nil }
                    return (.chordRelative(degree: degree, alteration: alteration, quality: quality), quality)
                }
                guard let root = expect(.identifier, "Expected chord root"),
                      let quality = expect(.identifier, "Expected chord quality") else { return nil }
                return (.chordAbsolute(root: root, quality: quality), quality)
            }
            guard let pitch = expect(.identifier, "Expected integer, pitch, scale degree, or chord value") else { return nil }
            return (.pitchClass(pitch), pitch)
        }

        mutating func parseAlteration() -> Int {
            var alteration = 0
            while current.kind == .accidental || (current.kind == .identifier && current.lexeme == "b") {
                alteration += current.kind == .accidental ? 1 : -1
                advance()
            }
            return alteration
        }

        mutating func parseScaleDefinition(symbol: TextToken) -> TextScaleDefinitionSyntax? {
            guard let open = expect(.leftBrace, "Expected '{' after scale name") else { return nil }
            guard takeKeyword("cents") else {
                diagnose("Expected 'cents' in scale definition")
                return nil
            }
            var intervals: [TextToken] = []
            while current.kind != .rightBrace && current.kind != .endOfFile {
                guard let interval = expect(.integerLiteral, "Expected a whole-number cent offset") else { break }
                intervals.append(interval)
                if !take(.comma) { break }
            }
            _ = take(.semicolon)
            let close = expect(.rightBrace, "Expected '}' after scale definition") ?? current
            return .init(symbol: symbol, centIntervals: intervals, range: spanning(open, close))
        }

        mutating func parseInstrumentProfile() -> TextInstrumentProfileSyntax? {
            guard let symbol = expect(.identifier, "Expected instrument profile name"),
                  let open = expect(.leftBrace, "Expected '{' after instrument profile name") else { return nil }
            var properties: [TextPropertySyntax] = []
            var actuators: [TextActuatorSyntax] = []
            var interactions: [TextInteractionSyntax] = []
            var techniques: [TextTechniqueSyntax] = []
            while current.kind != .rightBrace && current.kind != .endOfFile {
                if take(.semicolon) { continue }
                if takeKeyword("actuator") {
                    if let actuator = parseActuator() { actuators.append(actuator) }
                } else if takeKeyword("interaction") {
                    if let interaction = parseInteraction() { interactions.append(interaction) }
                } else if takeKeyword("technique") {
                    if let technique = parseTechnique() { techniques.append(technique) }
                } else if let property = parseProperty() { properties.append(property) }
                _ = take(.semicolon)
            }
            let close = expect(.rightBrace, "Expected '}' after instrument profile") ?? current
            return .init(symbol: symbol, properties: properties, actuators: actuators, interactions: interactions, techniques: techniques, range: spanning(open, close))
        }

        mutating func parseActuator() -> TextActuatorSyntax? {
            guard let name = expect(.identifier, "Expected actuator group name") else { return nil }
            guard take(.leftBrace) else { return .init(name: name, properties: [], range: name.range) }
            let open = tokens[index - 1]
            let properties = parseProperties(until: .rightBrace)
            let close = expect(.rightBrace, "Expected '}' after actuator group") ?? current
            return .init(name: name, properties: properties, range: spanning(open, close))
        }

        mutating func parseInteraction() -> TextInteractionSyntax? {
            guard let name = expect(.identifier, "Expected interaction name"),
                  let open = expect(.leftBrace, "Expected '{' after interaction name") else { return nil }
            var targets: [TextToken] = []
            var effectors: [TextToken] = []
            var arguments: [TextInteractionArgumentSyntax] = []
            var modifiers: [TextToken] = []
            var parameters: [TextInteractionParameterSyntax] = []
            while current.kind != .rightBrace && current.kind != .endOfFile {
                if take(.semicolon) { continue }
                if takeKeyword("targets") { targets.append(contentsOf: parseIdentifierList()) }
                else if takeKeyword("effectors") { effectors.append(contentsOf: parseIdentifierList()) }
                else if takeKeyword("argument") {
                    if let argument = parseInteractionArgument() { arguments.append(argument) }
                } else if takeKeyword("modifier") {
                    if let modifier = expect(.identifier, "Expected modifier name") { modifiers.append(modifier) }
                } else if takeKeyword("parameter") {
                    if let parameter = parseInteractionParameter() { parameters.append(parameter) }
                } else { diagnose("Expected targets, effectors, argument, modifier, or parameter in interaction"); synchronizeBlockItem() }
                _ = take(.semicolon)
            }
            let close = expect(.rightBrace, "Expected '}' after interaction") ?? current
            return .init(name: name, targets: targets, effectors: effectors, arguments: arguments, modifiers: modifiers, parameters: parameters, range: spanning(open, close))
        }

        mutating func parseInteractionArgument() -> TextInteractionArgumentSyntax? {
            guard let name = expect(.identifier, "Expected interaction argument name"),
                  let open = expect(.leftBrace, "Expected '{' after interaction argument") else { return nil }
            var values: [TextToken] = []
            var required = false
            while current.kind != .rightBrace && current.kind != .endOfFile {
                if take(.semicolon) { continue }
                if takeKeyword("values") { values.append(contentsOf: parseIdentifierList()) }
                else if takeKeyword("required") { required = true }
                else { diagnose("Expected values or required in interaction argument"); synchronizeBlockItem() }
                _ = take(.semicolon)
            }
            let close = expect(.rightBrace, "Expected '}' after interaction argument") ?? current
            return .init(name: name, values: values, isRequired: required, range: spanning(open, close))
        }

        mutating func parseInteractionParameter() -> TextInteractionParameterSyntax? {
            guard let name = expect(.identifier, "Expected interaction parameter name"),
                  let open = expect(.leftBrace, "Expected '{' after interaction parameter") else { return nil }
            let properties = parseProperties(until: .rightBrace)
            let close = expect(.rightBrace, "Expected '}' after interaction parameter") ?? current
            return .init(name: name, properties: properties, range: spanning(open, close))
        }

        mutating func parseTechnique() -> TextTechniqueSyntax? {
            guard let name = expect(.identifier, "Expected technique name") else { return nil }
            guard take(.leftBrace) else { return .init(name: name, properties: [], range: name.range) }
            let open = tokens[index - 1]
            let properties = parseProperties(until: .rightBrace)
            let close = expect(.rightBrace, "Expected '}' after technique") ?? current
            return .init(name: name, properties: properties, range: spanning(open, close))
        }

        mutating func parseProperties(until end: TextTokenKind) -> [TextPropertySyntax] {
            var result: [TextPropertySyntax] = []
            while current.kind != end && current.kind != .endOfFile {
                if take(.semicolon) { continue }
                if let property = parseProperty() { result.append(property) }
                _ = take(.semicolon)
            }
            return result
        }

        mutating func parseIdentifierList() -> [TextToken] {
            var result: [TextToken] = []
            if let value = expect(.identifier, "Expected identifier") { result.append(value) }
            while take(.comma) {
                if let value = expect(.identifier, "Expected identifier after ','") { result.append(value) }
            }
            return result
        }

        mutating func parseQualifiedName() -> TextQualifiedNameSyntax? {
            guard let first = expect(.identifier, "Expected module name") else { return nil }
            var components = [first]
            while take(.dot) {
                guard let component = expect(.identifier, "Expected module name component after '.'") else { break }
                components.append(component)
            }
            return .init(components: components, range: spanning(first, components.last ?? first))
        }

        mutating func parseSymbolReference(_ message: String) -> TextSymbolReferenceSyntax? {
            if current.kind == .stringLiteral {
                let token = advance()
                return .init(components: [token], range: token.range)
            }
            guard current.kind == .identifier else { diagnose(message); return nil }
            guard let name = parseQualifiedName() else { return nil }
            return .init(components: name.components, range: name.range)
        }

        mutating func parseInstrumentModel() -> TextInstrumentModelSyntax? {
            guard let symbol = expect(.identifier, "Expected instrument model name"),
                  expect(.colon, "Expected ':' after instrument model name") != nil else { return nil }
            guard let profile = parseSymbolReference("Expected capability profile name") else { return nil }
            guard let open = expect(.leftBrace, "Expected '{' after instrument model profile") else { return nil }
            var properties: [TextPropertySyntax] = []
            var geometries: [TextGeometrySyntax] = []
            while current.kind != .rightBrace && current.kind != .endOfFile {
                if take(.semicolon) { continue }
                if takeKeyword("geometry") {
                    if let geometry = parseGeometry() { geometries.append(geometry) }
                } else if let property = parseProperty() { properties.append(property) }
                _ = take(.semicolon)
            }
            let close = expect(.rightBrace, "Expected '}' after instrument model") ?? current
            return .init(symbol: symbol, profile: profile, properties: properties, geometries: geometries, range: spanning(open, close))
        }

        mutating func parseGeometry() -> TextGeometrySyntax? {
            guard let name = expect(.identifier, "Expected geometry name"),
                  let open = expect(.leftBrace, "Expected '{' after geometry name") else { return nil }
            var properties: [TextPropertySyntax] = []
            while current.kind != .rightBrace && current.kind != .endOfFile {
                if take(.semicolon) { continue }
                if let property = parseProperty() { properties.append(property) }
                _ = take(.semicolon)
            }
            let close = expect(.rightBrace, "Expected '}' after geometry") ?? current
            return .init(name: name, properties: properties, range: spanning(open, close))
        }

        mutating func parseProperty() -> TextPropertySyntax? {
            guard current.kind == .identifier else {
                diagnose("Expected property name")
                advance()
                return nil
            }
            let name = advance()
            _ = take(.equal)
            guard current.kind == .identifier || current.kind == .stringLiteral || current.kind == .integerLiteral || current.kind == .decimalLiteral else {
                diagnose("Expected property value")
                advance()
                return nil
            }
            var values = [advance()]
            while take(.dot) {
                guard let component = expect(.identifier, "Expected reference component after '.'") else { break }
                values.append(component)
            }
            while take(.comma) {
                guard current.kind == .identifier || current.kind == .stringLiteral || current.kind == .integerLiteral || current.kind == .decimalLiteral else {
                    diagnose("Expected property value after ','")
                    break
                }
                values.append(advance())
            }
            return .init(name: name, values: values, range: spanning(name, values.last ?? name))
        }

        mutating func parseInstrumentExtension() -> TextInstrumentExtensionSyntax? {
            guard let model = parseSymbolReference("Expected instrument model name"),
                  let open = expect(.leftBrace, "Expected '{' after extension target") else { return nil }
            var tunings: [TextTuningSyntax] = []
            var fingerings: [TextFingeringSyntax] = []
            var chordShapes: [TextChordShapeSyntax] = []
            while current.kind != .rightBrace && current.kind != .endOfFile {
                if take(.semicolon) { continue }
                if takeKeyword("tuning") {
                    if let tuning = parseTuning() { tunings.append(tuning) }
                } else if takeKeyword("fingering") {
                    if let fingering = parseFingering() { fingerings.append(fingering) }
                } else if takeKeyword("chordShape") {
                    if let shape = parseChordShape() { chordShapes.append(shape) }
                } else { diagnose("Expected tuning, fingering, or chordShape declaration"); synchronizeBlockItem(); continue }
                _ = take(.semicolon)
            }
            let close = expect(.rightBrace, "Expected '}' after extension") ?? current
            return .init(model: model, tunings: tunings, fingerings: fingerings, chordShapes: chordShapes, range: spanning(open, close))
        }

        mutating func parseChordShape() -> TextChordShapeSyntax? {
            guard let symbol = expect(.identifier, "Expected chord shape name"),
                  expect(.colon, "Expected ':' after chord shape name") != nil,
                  let root = expect(.identifier, "Expected chord root"),
                  let quality = expect(.identifier, "Expected chord quality"),
                  let open = expect(.leftBrace, "Expected '{' after chord shape") else { return nil }
            var strings: [TextChordShapeStringSyntax] = []
            while current.kind != .rightBrace && current.kind != .endOfFile {
                if take(.semicolon) { continue }
                guard takeKeyword("string"),
                      let number = expect(.integerLiteral, "Expected string number"),
                      expectKeyword("fret", "Expected 'fret' after string number") != nil,
                      let fret = expect(.integerLiteral, "Expected fret number") else {
                    synchronizeBlockItem()
                    continue
                }
                strings.append(.init(number: number, fret: fret, range: spanning(number, fret)))
                _ = take(.semicolon)
            }
            let close = expect(.rightBrace, "Expected '}' after chord shape") ?? current
            return .init(symbol: symbol, root: root, quality: quality, strings: strings, range: spanning(open, close))
        }

        mutating func parseFingering() -> TextFingeringSyntax? {
            guard let symbol = expect(.identifier, "Expected fingering name") else { return nil }
            let isDefault = takeKeyword("default")
            guard let open = expect(.leftBrace, "Expected '{' after fingering name") else { return nil }
            var properties: [TextPropertySyntax] = []
            var bitOrder: [TextToken] = []
            var entries: [TextFingeringEntrySyntax] = []
            while current.kind != .rightBrace && current.kind != .endOfFile {
                if take(.semicolon) { continue }
                if takeKeyword("bitOrder") {
                    bitOrder = parseIdentifierList()
                } else if takeKeyword("effect") {
                    let effect = expect(.identifier, "Expected effect name")
                    let pattern = expectFingeringPattern()
                    if let effect, let pattern { entries.append(parseFingeringEntry(pitch: nil, effect: effect, pattern: pattern)) }
                } else if current.kind == .identifier, parsePitchToken(current) {
                    let pitch = advance()
                    if let pattern = expectFingeringPattern() { entries.append(parseFingeringEntry(pitch: pitch, effect: nil, pattern: pattern)) }
                } else if let property = parseProperty() { properties.append(property) }
                _ = take(.semicolon)
            }
            let close = expect(.rightBrace, "Expected '}' after fingering") ?? current
            return .init(symbol: symbol, isDefault: isDefault, properties: properties, bitOrder: bitOrder, entries: entries, range: spanning(open, close))
        }

        mutating func expectFingeringPattern() -> TextToken? {
            guard current.kind == .integerLiteral || current.kind == .stringLiteral else {
                diagnose("Expected a fingering bitmap"); return nil
            }
            return advance()
        }

        mutating func parseFingeringEntry(pitch: TextToken?, effect: TextToken?, pattern: TextToken) -> TextFingeringEntrySyntax {
            var register: TextToken?
            var preference: TextToken?
            var label: TextToken?
            if takeKeyword("register") { register = expect(.integerLiteral, "Expected register number") }
            if current.kind == .identifier, current.lexeme == "preferred" || current.lexeme == "alternate" { preference = advance() }
            if current.kind == .stringLiteral { label = advance() }
            let first = pitch ?? effect ?? pattern
            return .init(pitch: pitch, effect: effect, pattern: pattern, register: register, preference: preference, label: label, range: spanning(first, label ?? preference ?? register ?? pattern))
        }

        func parsePitchToken(_ token: TextToken) -> Bool {
            let text = String(token.lexeme)
            guard text.count >= 2, let first = text.first, "ABCDEFGabcdefg".contains(first) else { return false }
            return text.last?.isNumber == true
        }

        mutating func parseTuning() -> TextTuningSyntax? {
            guard let symbol = expect(.identifier, "Expected tuning name") else { return nil }
            let isDefault = takeKeyword("default")
            guard let open = expect(.leftBrace, "Expected '{' after tuning name") else { return nil }
            let inheritedNotation = notation
            defer { notation = inheritedNotation }
            parseNotationDirective()
            var properties: [TextPropertySyntax] = []
            var tags: [TextToken] = []
            var courses: [[TextToken]] = []
            while current.kind != .rightBrace && current.kind != .endOfFile {
                if take(.semicolon) { continue }
                if takeKeyword("course") {
                    var pitches: [TextToken] = []
                    if let pitch = expect(.identifier, "Expected course pitch") { pitches.append(pitch) }
                    while take(.comma) {
                        if let pitch = expect(.identifier, "Expected course pitch after ','") { pitches.append(pitch) }
                    }
                    courses.append(pitches)
                } else if takeKeyword("tags") {
                    if let tag = expect(.identifier, "Expected tuning tag") { tags.append(tag) }
                    while take(.comma) {
                        if let tag = expect(.identifier, "Expected tuning tag after ','") { tags.append(tag) }
                    }
                } else if let property = parseProperty() { properties.append(property) }
                _ = take(.semicolon)
            }
            let close = expect(.rightBrace, "Expected '}' after tuning") ?? current
            return .init(notation: notation, symbol: symbol, isDefault: isDefault, properties: properties, tags: tags, courses: courses, range: spanning(open, close))
        }

        mutating func parseInstrumentInstance() -> TextInstrumentInstanceSyntax? {
            guard let name = expect(.identifier, "Expected instrument instance name"),
                  expect(.colon, "Expected ':' after instrument instance name") != nil else { return nil }
            guard let model = parseSymbolReference("Expected instrument model name") else { return nil }
            var displayName: TextToken?
            var tuning: TextSymbolReferenceSyntax?
            var fingering: TextSymbolReferenceSyntax?
            while current.kind == .identifier, current.lexeme == "as" || current.lexeme == "tuning" || current.lexeme == "fingering" {
                if takeKeyword("as") { displayName = expect(.stringLiteral, "Expected quoted instrument display name") }
                else if takeKeyword("tuning") { tuning = parseSymbolReference("Expected tuning name or stable ID") }
                else if takeKeyword("fingering") { fingering = parseSymbolReference("Expected fingering name or stable ID") }
            }
            let end = displayName?.range.end ?? fingering?.range.end ?? tuning?.range.end ?? model.range.end
            return .init(name: name, model: model, tuning: tuning, fingering: fingering, displayName: displayName, range: .init(fileID: name.range.fileID, start: name.range.start, end: end))
        }

        mutating func parsePerformancePattern() -> TextPerformancePatternSyntax? {
            guard let name = expect(.identifier, "Expected performance pattern name"),
                  let open = expect(.leftBrace, "Expected '{' after performance pattern name") else { return nil }
            var subdivision: TextDurationSyntax?
            var steps: [TextPerformanceStepSyntax] = []
            while current.kind != .rightBrace && current.kind != .endOfFile {
                if take(.semicolon) { continue }
                if takeKeyword("subdivision") {
                    subdivision = parseDuration()
                    _ = take(.semicolon)
                } else if takeKeyword("steps") {
                    guard expect(.leftBrace, "Expected '{' after steps") != nil else { continue }
                    steps = parsePerformanceSteps(until: .rightBrace)
                    _ = expect(.rightBrace, "Expected '}' after performance pattern steps")
                    _ = take(.semicolon)
                } else {
                    diagnose("Expected subdivision or steps in performance pattern")
                    synchronizeBlockItem()
                }
            }
            let close = expect(.rightBrace, "Expected '}' after performance pattern") ?? current
            guard let subdivision else {
                diagnose("Performance pattern requires a subdivision")
                return nil
            }
            return .init(name: name, subdivision: subdivision, steps: steps, range: spanning(open, close))
        }

        mutating func parseBassPattern() -> TextBassPatternSyntax? {
            guard let name = expect(.identifier, "Expected bass pattern name"),
                  let open = expect(.leftBrace, "Expected '{' after bass pattern name"),
                  expectKeyword("degrees", "Expected degrees in bass pattern") != nil else { return nil }
            var degrees: [TextToken] = []
            while current.kind != .rightBrace && current.kind != .endOfFile {
                if take(.semicolon) || take(.comma) { continue }
                if current.kind == .integerLiteral || (current.kind == .identifier && current.lexeme == "root") { degrees.append(advance()) }
                else { diagnose("Expected root or chord degree in bass pattern"); advance() }
            }
            let close = expect(.rightBrace, "Expected '}' after bass pattern") ?? current
            if degrees.isEmpty { diagnose("Bass pattern requires at least one degree") }
            return .init(name: name, degrees: degrees, range: spanning(open, close))
        }

        mutating func parsePerformanceSteps(until end: TextTokenKind) -> [TextPerformanceStepSyntax] {
            var result: [TextPerformanceStepSyntax] = []
            while current.kind != end && current.kind != .endOfFile {
                if take(.semicolon) { continue }
                guard let first = parsePerformanceStep() else { synchronizeBlockItem(); continue }
                var concurrent = [first]
                while take(.comma) {
                    guard let next = parsePerformanceStep() else { diagnose("Expected interaction after ','"); break }
                    concurrent.append(next)
                }
                if concurrent.count == 1 {
                    result.append(first)
                } else if let last = concurrent.last {
                    result.append(.init(kind: .parallel(concurrent), range: .init(fileID: first.range.fileID, start: first.range.start, end: last.range.end)))
                }
                requireSequenceSeparator(unlessAt: end)
            }
            return result
        }

        mutating func parsePerformanceStep() -> TextPerformanceStepSyntax? {
            guard current.kind == .identifier else { diagnose("Expected performance interaction"); return nil }
            var words = [advance()]
            while current.kind == .identifier { words.append(advance()) }
            return .init(kind: .interaction(words), range: spanning(words[0], words.last!))
        }

        mutating func parsePhrase() -> TextPhraseSyntax? {
            guard let name = expect(.identifier, "Expected phrase name") else { return nil }
            var parameters: [TextPhraseParameterSyntax] = []
            if take(.leftParen) {
                while current.kind != .rightParen && current.kind != .endOfFile {
                    guard let parameter = expect(.identifier, "Expected parameter name"),
                          expect(.colon, "Expected ':' after parameter name") != nil,
                          let type = expect(.identifier, "Expected parameter type") else { return nil }
                    parameters.append(.init(name: parameter, type: type, range: spanning(parameter, type)))
                    if !take(.comma) { break }
                }
                guard expect(.rightParen, "Expected ')' after phrase parameters") != nil else { return nil }
            }
            guard let open = expect(.leftBrace, "Expected '{' after phrase declaration") else { return nil }
            let expressions = parseExpressions(until: .rightBrace)
            let close = expect(.rightBrace, "Expected '}' after phrase") ?? current
            return .init(name: name, parameters: parameters, expressions: expressions, range: spanning(open, close))
        }

        mutating func parseSection() -> TextSectionSyntax? {
            guard let name = expect(.identifier, "Expected section name") else { return nil }
            var bars: TextToken?
            if take(.colon) {
                bars = expect(.integerLiteral, "Expected section bar count")
                _ = expectKeyword("bars", "Expected 'bars' after section length")
            }
            guard let open = expect(.leftBrace, "Expected '{' after section name") else { return nil }
            let inheritedNotation = notation
            defer { notation = inheritedNotation }
            parseNotationDirective()
            var harmony: [TextExpressionSyntax] = []
            var instruments: [TextInstrumentSyntax] = []
            while current.kind != .rightBrace && current.kind != .endOfFile {
                if take(.semicolon) { continue }
                if takeKeyword("harmony") {
                    guard expect(.leftBrace, "Expected '{' after harmony") != nil else { continue }
                    harmony.append(contentsOf: parseExpressions(until: .rightBrace))
                    _ = expect(.rightBrace, "Expected '}' after harmony")
                } else if let instrument = parseInstrument() {
                    instruments.append(instrument)
                } else {
                    synchronizeBlockItem()
                }
            }
            let close = expect(.rightBrace, "Expected '}' after section") ?? current
            return .init(name: name, barCount: bars, harmony: harmony, instruments: instruments, range: spanning(open, close))
        }

        mutating func parseInstrument() -> TextInstrumentSyntax? {
            guard current.kind == .identifier || current.kind == .stringLiteral else {
                diagnose("Expected instrument instance name"); return nil
            }
            let name = advance()
            guard let open = expect(.leftBrace, "Expected '{' after instrument instance name") else { return nil }
            let inheritedNotation = notation
            defer { notation = inheritedNotation }
            parseNotationDirective()
            var voices: [TextVoiceSyntax] = []
            while current.kind != .rightBrace && current.kind != .endOfFile {
                if take(.semicolon) { continue }
                guard takeKeyword("voice") else { diagnose("Expected voice declaration"); synchronizeBlockItem(); continue }
                if let voice = parseVoice() { voices.append(voice) }
            }
            let close = expect(.rightBrace, "Expected '}' after instrument") ?? current
            return .init(name: name, voices: voices, range: spanning(open, close))
        }

        mutating func parseVoice() -> TextVoiceSyntax? {
            guard let name = expect(.identifier, "Expected voice name"), let open = expect(.leftBrace, "Expected '{' after voice name") else { return nil }
            let inheritedNotation = notation
            defer { notation = inheritedNotation }
            parseNotationDirective()
            var lyrics: [TextToken] = []
            var expressions: [TextExpressionSyntax] = []
            while current.kind != .rightBrace && current.kind != .endOfFile {
                if take(.semicolon) { continue }
                if takeKeyword("lyrics") {
                    lyrics.append(contentsOf: parseStringBlock())
                } else if let expression = parseTemporalGroup() {
                    expressions.append(expression)
                } else {
                    synchronizeBlockItem()
                }
                requireSequenceSeparator(unlessAt: .rightBrace)
            }
            let close = expect(.rightBrace, "Expected '}' after voice") ?? current
            return .init(name: name, lyrics: lyrics, expressions: expressions, range: spanning(open, close))
        }

        @_optimize(speed)
        @inline(never)
        mutating func parseExpressions(until end: TextTokenKind) -> [TextExpressionSyntax] {
            let inheritedNotation = notation
            defer { notation = inheritedNotation }
            let scopedPolicies = scanUsingDirectives(until: end)
            var result: [TextExpressionSyntax] = []
            while current.kind != end && current.kind != .endOfFile {
                if take(.semicolon) { continue }
                if isKeyword("using") {
                    consumeUsingDirective()
                    requireSequenceSeparator(unlessAt: end)
                    continue
                }
                if let expression = parseTemporalGroup() { result.append(expression) }
                else { synchronizeBlockItem() }
                requireSequenceSeparator(unlessAt: end)
            }
            for policy in scopedPolicies.reversed() {
                guard let first = result.first, let last = result.last else { continue }
                let kind: TextExpressionSyntax.Kind
                switch policy {
                case .technique(let technique): kind = .technique(name: technique, arguments: [], expressions: result)
                case .dynamic(let level): kind = .dynamic(level: level, expressions: result)
                case .voiceLeading(let policy): kind = .voiceLeading(policy: policy, expressions: result)
                }
                result = [.init(kind: kind, range: .init(fileID: first.range.fileID, start: first.range.start, end: last.range.end))]
            }
            return result
        }

        @_optimize(speed)
        @inline(never)
        mutating func parseTemporalGroup() -> TextExpressionSyntax? {
            guard let first = parseExpression() else { return nil }
            var expressions = [first]
            while take(.comma) {
                guard let next = parseExpression() else {
                    diagnose("Expected expression after ','")
                    break
                }
                expressions.append(next)
            }
            guard expressions.count > 1, let last = expressions.last else { return first }
            return .init(
                kind: .parallel(expressions),
                range: .init(fileID: first.range.fileID, start: first.range.start, end: last.range.end)
            )
        }

        @_optimize(speed)
        @inline(never)
        mutating func parseExpression() -> TextExpressionSyntax? {
            var expression = parseExpressionBody()
            expression?.notation = notation
            var modifiers: [TextToken] = []
            while isKeyword("letRing") || isKeyword("rearticulate") || isKeyword("accent") {
                modifiers.append(advance())
            }
            if take(.tie), let original = expression {
                expression = .init(
                    kind: original.kind,
                    range: .init(fileID: original.range.fileID, start: original.range.start, end: tokens[index - 1].range.end),
                    notation: original.notation,
                    tieToNext: true,
                    modifiers: modifiers
                )
            } else if let original = expression, !modifiers.isEmpty {
                expression = .init(
                    kind: original.kind,
                    range: .init(fileID: original.range.fileID, start: original.range.start, end: modifiers.last!.range.end),
                    notation: original.notation,
                    tieToNext: original.tieToNext,
                    modifiers: modifiers
                )
            }
            return expression
        }

        @_optimize(speed)
        @inline(never)
        mutating func parseExpressionBody() -> TextExpressionSyntax? {
            if isScopedExpressionStart() {
                return parseScopedExpressionBody()
            }
            return parsePrimaryExpressionBody()
        }

        func isScopedExpressionStart() -> Bool {
            switch current.lexeme {
            case "using", "transpose", "tuplet", "stretch", "augment", "diminish",
                 "meter", "scale", "tempo", "fermata", "rubato", "damp", "dynamics",
                 "crescendo", "diminuendo", "pedal", "grace", "ornament", "bass":
                return true
            case "legato", "slur":
                return tokens[min(index + 1, tokens.count - 1)].kind == .leftBrace
            case "bar", "pickup", "final", "repeat", "perform":
                return false
            default:
                guard current.kind == .identifier else { return false }
                if tokens[min(index + 1, tokens.count - 1)].kind == .leftBrace { return true }
                guard tokens[min(index + 1, tokens.count - 1)].kind == .leftParen else { return false }
                var cursor = index + 1
                var depth = 0
                while cursor < tokens.count {
                    if tokens[cursor].kind == .leftParen { depth += 1 }
                    else if tokens[cursor].kind == .rightParen {
                        depth -= 1
                        if depth == 0 {
                            return cursor + 1 < tokens.count && tokens[cursor + 1].kind == .leftBrace
                        }
                    }
                    cursor += 1
                }
                return false
            }
        }

        @_optimize(speed)
        @inline(never)
        mutating func parseScopedExpressionBody() -> TextExpressionSyntax? {
            if isKeyword("using") {
                diagnose("Notation directives must appear once at the start of a musical scope")
                parseNotationDirective()
                return nil
            }
            if takeKeyword("transpose") {
                let start = tokens[index - 1]
                if takeKeyword("pitch") {
                    guard let semitones = expectIntegerExpression("Expected signed semitone count or integer parameter") else { return nil }
                    guard takeKeyword("semitones") || takeKeyword("semitone") else {
                        diagnose("Expected semitone or semitones after pitch transposition")
                        return nil
                    }
                    guard expect(.leftBrace, "Expected '{' after pitch transposition") != nil else { return nil }
                    let children = parseExpressions(until: .rightBrace)
                    let close = expect(.rightBrace, "Expected '}' after pitch transposition") ?? current
                    return .init(kind: .transposePitch(semitones: semitones, expressions: children), range: spanning(start, close))
                }
                guard expectKeyword("degree", "Expected 'pitch' or 'degree' after 'transpose'") != nil,
                      let degrees = expectIntegerExpression("Expected signed scale-degree count or integer parameter") else { return nil }
                _ = takeKeyword("degrees") || takeKeyword("degree")
                guard expect(.leftBrace, "Expected '{' after degree transposition") != nil else { return nil }
                let children = parseExpressions(until: .rightBrace)
                let close = expect(.rightBrace, "Expected '}' after degree transposition") ?? current
                return .init(kind: .transposeDegree(degrees: degrees, expressions: children), range: spanning(start, close))
            }
            if isKeyword("tuplet") || isKeyword("stretch") {
                return parseProportionalExpression()
            }
            if isKeyword("augment") || isKeyword("diminish") {
                let kind = advance()
                guard let numerator = expect(.integerLiteral, "Expected positive ratio numerator"),
                      expect(.slash, "Expected '/' in rhythmic transform ratio") != nil,
                      let denominator = expect(.integerLiteral, "Expected positive ratio denominator"),
                      expect(.leftBrace, "Expected '{' after rhythmic transform ratio") != nil else { return nil }
                let children = parseExpressions(until: .rightBrace)
                let close = expect(.rightBrace, "Expected '}' after rhythmic transform") ?? current
                return .init(kind: .rhythmicTransform(kind: kind, numerator: numerator, denominator: denominator, expressions: children), range: spanning(kind, close))
            }
            if takeKeyword("meter") {
                let keyword = tokens[index - 1]
                guard let numerator = expect(.integerLiteral, "Expected meter numerator"),
                      expect(.slash, "Expected '/' in meter") != nil,
                      let denominator = expect(.integerLiteral, "Expected meter denominator") else { return nil }
                return .init(kind: .meter(numerator: numerator, denominator: denominator), range: spanning(keyword, denominator))
            }
            if takeKeyword("scale") {
                let keyword = tokens[index - 1]
                guard let tonic = expect(.identifier, "Expected scale tonic"),
                      let mode = expect(.identifier, "Expected scale name") else { return nil }
                return .init(kind: .scale(tonic: tonic, mode: mode), range: spanning(keyword, mode))
            }
            if takeKeyword("tempo") {
                let keyword = tokens[index - 1]
                if takeKeyword("ramp") {
                    guard expectKeyword("to", "Expected 'to' after 'tempo ramp'") != nil,
                          let target = expectNumber("Expected positive target tempo"),
                          expectKeyword("over", "Expected 'over' before ramp duration") != nil,
                          let duration = parseDuration() else { return nil }
                    var steps: TextToken?
                    if takeKeyword("steps") { steps = expect(.integerLiteral, "Expected positive ramp step count") }
                    return .init(kind: .tempoRamp(target: target, duration: duration, steps: steps), range: spanning(keyword, steps ?? tokens[index - 1]))
                }
                if current.kind == .integerLiteral || current.kind == .decimalLiteral {
                    guard let bpm = expectNumber("Expected positive tempo") else { return nil }
                    return .init(kind: .tempo(unit: nil, beatsPerMinute: bpm), range: spanning(keyword, bpm))
                }
                guard let unit = parseDuration(), expect(.equal, "Expected '=' after tempo beat unit") != nil,
                      let bpm = expectNumber("Expected positive tempo") else { return nil }
                return .init(kind: .tempo(unit: unit, beatsPerMinute: bpm), range: spanning(keyword, bpm))
            }
            if takeKeyword("fermata") {
                let keyword = tokens[index - 1]
                guard let duration = parseDuration(),
                      expectKeyword("factor", "Expected 'factor' after fermata duration") != nil,
                      let factor = expectNumber("Expected fermata stretch factor") else { return nil }
                return .init(kind: .fermata(duration: duration, factor: factor), range: spanning(keyword, factor))
            }
            if takeKeyword("rubato") {
                let keyword = tokens[index - 1]
                guard let duration = parseDuration(),
                      expectKeyword("factor", "Expected 'factor' after rubato duration") != nil,
                      let factor = expectNumber("Expected rubato time factor") else { return nil }
                return .init(kind: .rubato(duration: duration, factor: factor), range: spanning(keyword, factor))
            }
            if takeKeyword("damp") {
                let keyword = tokens[index - 1]
                return .init(kind: .damp, range: keyword.range)
            }
            if takeKeyword("dynamics") {
                let keyword = tokens[index - 1]
                guard let level = expect(.identifier, "Expected dynamic level after 'dynamics'"),
                      expect(.leftBrace, "Expected '{' after dynamic level") != nil else { return nil }
                let children = parseExpressions(until: .rightBrace)
                let close = expect(.rightBrace, "Expected '}' after dynamics") ?? current
                return .init(kind: .dynamic(level: level, expressions: children), range: spanning(keyword, close))
            }
            if takeKeyword("crescendo") || takeKeyword("diminuendo") {
                let direction = tokens[index - 1]
                guard expectKeyword("to", "Expected 'to' after \(direction.lexeme)") != nil,
                      let target = expect(.identifier, "Expected target dynamic level"),
                      expect(.leftBrace, "Expected '{' after target dynamic level") != nil else { return nil }
                let children = parseExpressions(until: .rightBrace)
                let close = expect(.rightBrace, "Expected '}' after \(direction.lexeme)") ?? current
                return .init(kind: .dynamicEnvelope(direction: direction, target: target, expressions: children), range: spanning(direction, close))
            }
            if takeKeyword("pedal") {
                let keyword = tokens[index - 1]
                guard expect(.leftBrace, "Expected '{' after pedal") != nil else { return nil }
                let children = parseExpressions(until: .rightBrace)
                let close = expect(.rightBrace, "Expected '}' after pedal") ?? current
                return .init(kind: .pedal(children), range: spanning(keyword, close))
            }
            if takeKeyword("grace") {
                let keyword = tokens[index - 1]
                guard let policy = expect(.identifier, "Expected grace timing policy") else { return nil }
                let budget: TextDurationSyntax?
                if policy.lexeme == "measured" { budget = nil }
                else { budget = parseDuration() }
                guard ["measured", "stealFollowing", "beforeBeat"].contains(String(policy.lexeme)) else {
                    diagnose("Expected measured, stealFollowing, or beforeBeat grace policy")
                    return nil
                }
                guard (policy.lexeme == "measured" || budget != nil),
                      expect(.leftBrace, "Expected '{' after grace policy") != nil else { return nil }
                let children = parseExpressions(until: .rightBrace)
                let close = expect(.rightBrace, "Expected '}' after grace group") ?? current
                return .init(kind: .grace(policy: policy, budget: budget, expressions: children), range: spanning(keyword, close))
            }
            if takeKeyword("ornament") {
                let keyword = tokens[index - 1]
                guard let name = expect(.identifier, "Expected ornament name"),
                      let subdivision = parseDuration(),
                      expect(.leftBrace, "Expected '{' after ornament subdivision") != nil else { return nil }
                let children = parseExpressions(until: .rightBrace)
                let close = expect(.rightBrace, "Expected '}' after ornament") ?? current
                return .init(kind: .ornament(name: name, subdivision: subdivision, expressions: children), range: spanning(keyword, close))
            }
            if takeKeyword("bass") {
                let keyword = tokens[index - 1]
                guard let pattern = expect(.identifier, "Expected bass pattern"),
                      let subdivision = parseDuration(),
                      expectKeyword("octave", "Expected 'octave' after bass subdivision") != nil,
                      let octave = expect(.integerLiteral, "Expected bass octave"),
                      expect(.leftBrace, "Expected '{' after bass octave") != nil else { return nil }
                let chords = parseExpressions(until: .rightBrace)
                let close = expect(.rightBrace, "Expected '}' after bass pattern") ?? current
                return .init(kind: .bass(pattern: pattern, subdivision: subdivision, octave: octave, chords: chords), range: spanning(keyword, close))
            }
            if (isKeyword("legato") || isKeyword("slur")) && tokens[min(index + 1, tokens.count - 1)].kind == .leftBrace {
                let technique = advance()
                _ = advance()
                let children = parseExpressions(until: .rightBrace)
                let close = expect(.rightBrace, "Expected '}' after \(technique.lexeme)") ?? current
                return .init(kind: .technique(name: technique, arguments: [], expressions: children), range: spanning(technique, close))
            }
            if current.kind == .identifier {
                let technique = advance()
                var arguments: [TextTechniqueArgumentSyntax] = []
                if take(.leftParen) {
                    while current.kind != .rightParen && current.kind != .endOfFile {
                        guard let label = expect(.identifier, "Expected technique argument label"),
                              expect(.colon, "Expected ':' after technique argument label") != nil else {
                            return nil
                        }
                        var value: [TextToken] = []
                        var bracketDepth = 0
                        while current.kind != .endOfFile {
                            if bracketDepth == 0 && (current.kind == .comma || current.kind == .rightParen) { break }
                            if current.kind == .leftBracket { bracketDepth += 1 }
                            if current.kind == .rightBracket { bracketDepth -= 1 }
                            value.append(advance())
                        }
                        guard !value.isEmpty, bracketDepth == 0 else {
                            diagnose("Expected a complete technique argument value")
                            return nil
                        }
                        arguments.append(.init(label: label, value: value))
                        if !take(.comma) { break }
                    }
                    guard expect(.rightParen, "Expected ')' after technique arguments") != nil else { return nil }
                }
                guard expect(.leftBrace, "Expected '{' after technique") != nil else { return nil }
                let children = parseExpressions(until: .rightBrace)
                let close = expect(.rightBrace, "Expected '}' after \(technique.lexeme)") ?? current
                return .init(kind: .technique(name: technique, arguments: arguments, expressions: children), range: spanning(technique, close))
            }

            return nil
        }

        @_optimize(speed)
        @inline(never)
        mutating func parsePrimaryExpressionBody() -> TextExpressionSyntax? {
            if take(.atSign) {
                let start = tokens[index - 1]
                guard let degree = expect(.integerLiteral, "Expected scale degree after '@'") else { return nil }
                var alteration = 0
                while current.kind == .accidental || (current.kind == .identifier && current.lexeme == "b") {
                    alteration += current.kind == .accidental ? 1 : -1
                    advance()
                }
                guard expect(.leftBracket, "Expected '[' before relative octave") != nil,
                      let octave = expect(.integerLiteral, "Expected relative octave"),
                      expect(.rightBracket, "Expected ']' after relative octave") != nil,
                      let duration = parseDuration() else { return nil }
                return .init(
                    kind: .relativeNote(degree: degree, alteration: alteration, octave: octave, duration: duration),
                    range: spanning(start, tokens[index - 1])
                )
            }
            if isKeyword("chord") { return parseChordExpression() }
            if takeKeyword("perform") {
                let start = tokens[index - 1]
                guard let pattern = expect(.identifier, "Expected performance pattern name"),
                      expect(.leftBrace, "Expected '{' after performance pattern name") != nil else { return nil }
                let chords = parseExpressions(until: .rightBrace)
                let close = expect(.rightBrace, "Expected '}' after performed chord progression") ?? current
                return .init(kind: .performed(pattern: pattern, chords: chords), range: spanning(start, close))
            }
            if takeKeyword("repeat") {
                return parseRepeatedExpression(keyword: tokens[index - 1])
            }
            if takeKeyword("bar") {
                return parseBarExpression(keyword: tokens[index - 1])
            }
            if takeKeyword("pickup") || takeKeyword("final") {
                let keyword = tokens[index - 1]
                guard expect(.leftBrace, "Expected '{' after \(keyword.lexeme)") != nil else { return nil }
                let children = parseExpressions(until: .rightBrace)
                let close = expect(.rightBrace, "Expected '}' after \(keyword.lexeme)") ?? current
                let kind: TextExpressionSyntax.Kind = keyword.lexeme == "pickup" ? .pickup(children) : .finalBar(children)
                return .init(kind: kind, range: spanning(keyword, close))
            }
            if take(.leftParen) {
                let open = tokens[index - 1]
                let children = parseExpressions(until: .rightParen)
                let close = expect(.rightParen, "Expected ')' after grouped sequence") ?? current
                return .init(kind: .sequence(children), range: spanning(open, close))
            }
            if takeKeyword("rest") || takeKeyword("_") {
                let restToken = tokens[index - 1]
                guard let duration = parseDuration() else { return nil }
                return .init(kind: .rest(duration: duration), range: spanning(restToken, tokens[index - 1]))
            }
            if isActuatorExpressionStart() {
                return parseActuatorExpression()
            }
            guard current.kind == .identifier else { diagnose("Expected musical expression"); return nil }
            var first = advance()
            if current.kind == .dot {
                var name = String(first.lexeme)
                while take(.dot) {
                    guard let component = expect(.identifier, "Expected qualified phrase name") else { return nil }
                    name += "." + component.lexeme
                }
                first = .init(kind: .identifier, lexeme: Substring(name), range: spanning(first, tokens[index - 1]))
            }
            if take(.leftParen) {
                var arguments: [TextPhraseArgumentSyntax] = []
                while current.kind != .rightParen && current.kind != .endOfFile {
                    guard let label = expect(.identifier, "Expected argument label"),
                          expect(.colon, "Expected ':' after argument label") != nil,
                          let value = parseValueExpression() else { return nil }
                    arguments.append(.init(label: label, value: value, range: .init(fileID: label.range.fileID, start: label.range.start, end: value.range.end)))
                    if !take(.comma) { break }
                }
                let close = expect(.rightParen, "Expected ')' after phrase arguments") ?? current
                return .init(kind: .reference(first, arguments: arguments), range: spanning(first, close))
            }
            let alteration = parseAlteration()
            if current.kind == .leftBracket && tokens[min(index + 2, tokens.count - 1)].kind != .slash, take(.leftBracket) {
                guard let octave = expect(.integerLiteral, "Expected octave"),
                      expect(.rightBracket, "Expected ']' after octave") != nil,
                      let duration = parseDuration() else { return nil }
                return .init(kind: .symbol(name: first, alteration: alteration, octave: octave, duration: duration), range: spanning(first, tokens[index - 1]))
            }
            if isDuration(current) || current.kind == .leftBracket {
                guard let duration = parseDuration() else { return nil }
                let isConcretePitch = first.lexeme.contains(where: \.isNumber)
                return .init(kind: isConcretePitch && alteration == 0 ? .note(pitch: first, duration: duration) : .symbol(name: first, alteration: alteration, octave: nil, duration: duration), range: spanning(first, tokens[index - 1]))
            }
            return .init(kind: .reference(first, arguments: []), range: first.range)
        }

        mutating func parseChordExpression() -> TextExpressionSyntax? {
            _ = takeKeyword("chord")
            let start = tokens[index - 1]
            if take(.atSign) {
                guard let degree = expect(.integerLiteral, "Expected scale degree after '@'") else { return nil }
                let alteration = parseAlteration()
                guard let quality = expect(.identifier, "Expected chord quality"), let duration = parseDuration() else { return nil }
                var shape: TextToken?; var bass: TextToken?; var inversion: TextToken?; var omissions: [TextToken] = []; var doublings: [TextToken] = []; var additions: [TextChordToneSyntax] = []; var alterations: [TextChordToneSyntax] = []; var range: TextPitchRangeSyntax?
                while ["using", "bass", "inversion", "omit", "double", "add", "alter", "range"].contains(String(current.lexeme)) {
                    if takeKeyword("using") { shape = expect(.identifier, "Expected chord shape name") }
                    else if takeKeyword("bass") { bass = expect(.identifier, "Expected chord bass pitch") }
                    else if takeKeyword("inversion") { inversion = expect(.integerLiteral, "Expected inversion number") }
                    else if takeKeyword("omit"), let value = expectChordMember() { omissions.append(value) }
                    else if takeKeyword("double"), let value = expectChordMember() { doublings.append(value) }
                    else if takeKeyword("add"), let value = expect(.integerLiteral, "Expected chord degree to add") { additions.append(.init(degree: value, alteration: parseAlteration())) }
                    else if takeKeyword("alter"), let value = expect(.integerLiteral, "Expected chord degree to alter") { alterations.append(.init(degree: value, alteration: parseAlteration())) }
                    else if takeKeyword("range"), let low = expect(.identifier, "Expected low pitch"), let high = expect(.identifier, "Expected high pitch") { range = .init(low: low, high: high) }
                }
                return .init(kind: .relativeChord(degree: degree, alteration: alteration, quality: quality, duration: duration, shape: shape, bass: bass, inversion: inversion, omissions: omissions, doublings: doublings, additions: additions, alterations: alterations, range: range), range: spanning(start, tokens[index - 1]))
            }
            guard let root = expect(.identifier, "Expected chord root") else { return nil }
            var slashBass: TextToken?
            if take(.slash) { slashBass = expect(.identifier, "Expected bass pitch after '/'") }
            guard let quality = expect(.identifier, "Expected chord quality"), let duration = parseDuration() else { return nil }
            var shape: TextToken?; var bass = slashBass; var inversion: TextToken?; var omissions: [TextToken] = []; var doublings: [TextToken] = []; var additions: [TextChordToneSyntax] = []; var alterations: [TextChordToneSyntax] = []; var range: TextPitchRangeSyntax?
            while ["using", "bass", "inversion", "omit", "double", "add", "alter", "range"].contains(String(current.lexeme)) {
                if takeKeyword("using") { shape = expect(.identifier, "Expected chord shape name") }
                else if takeKeyword("bass") {
                    let explicitBass = expect(.identifier, "Expected chord bass pitch")
                    if bass != nil { diagnose("Chord bass is already specified by slash notation") } else { bass = explicitBass }
                }
                else if takeKeyword("inversion") { inversion = expect(.integerLiteral, "Expected inversion number") }
                else if takeKeyword("omit"), let value = expectChordMember() { omissions.append(value) }
                else if takeKeyword("double"), let value = expectChordMember() { doublings.append(value) }
                else if takeKeyword("add"), let value = expect(.integerLiteral, "Expected chord degree to add") { additions.append(.init(degree: value, alteration: parseAlteration())) }
                else if takeKeyword("alter"), let value = expect(.integerLiteral, "Expected chord degree to alter") { alterations.append(.init(degree: value, alteration: parseAlteration())) }
                else if takeKeyword("range"), let low = expect(.identifier, "Expected low pitch"), let high = expect(.identifier, "Expected high pitch") { range = .init(low: low, high: high) }
            }
            return .init(kind: .chord(root: root, quality: quality, duration: duration, shape: shape, bass: bass, inversion: inversion, omissions: omissions, doublings: doublings, additions: additions, alterations: alterations, range: range), range: spanning(start, tokens[index - 1]))
        }

        @_optimize(speed)
        @inline(never)
        mutating func parseProportionalExpression() -> TextExpressionSyntax? {
            let start = advance()
            guard let numerator = expect(.integerLiteral, "Expected positive ratio numerator"),
                  expect(start.lexeme == "tuplet" ? .colon : .slash, "Expected ratio separator") != nil,
                  let denominator = expect(.integerLiteral, "Expected positive ratio denominator"),
                  expect(.leftBrace, "Expected '{' after ratio") != nil else { return nil }
            let children = parseExpressions(until: .rightBrace)
            let close = expect(.rightBrace, "Expected '}' after proportional group") ?? current
            return .init(kind: .proportional(numerator: numerator, denominator: denominator, tuplet: start.lexeme == "tuplet", expressions: children), range: spanning(start, close))
        }

        @_optimize(speed)
        @inline(never)
        mutating func parseRepeatedExpression(keyword: TextToken) -> TextExpressionSyntax? {
            guard let count = expect(.integerLiteral, "Expected repeat count"),
                  expect(.leftBrace, "Expected '{' after repeat count") != nil else { return nil }
            let children = parseExpressions(until: .rightBrace)
            let close = expect(.rightBrace, "Expected '}' after repeat") ?? current
            return .init(kind: .repeated(count: count, expressions: children), range: spanning(keyword, close))
        }

        @_optimize(speed)
        @inline(never)
        mutating func parseBarExpression(keyword: TextToken) -> TextExpressionSyntax? {
            guard expect(.leftBrace, "Expected '{' after bar") != nil else { return nil }
            let children = parseExpressions(until: .rightBrace)
            let close = expect(.rightBrace, "Expected '}' after bar") ?? current
            return .init(kind: .bar(children), range: spanning(keyword, close))
        }

        mutating func parseValueExpression() -> TextValueExpressionSyntax? {
            guard current.kind == .identifier || current.kind == .integerLiteral else {
                diagnose("Expected pitch or integer argument")
                return nil
            }
            var result: TextValueExpressionSyntax = .atom(advance())
            if current.kind == .plus || current.kind == .minus {
                let operation = advance()
                guard let amount = expect(.integerLiteral, "Expected integer offset"),
                      current.kind == .identifier else {
                    diagnose("Expected semitone(s) or degree(s) after offset")
                    return nil
                }
                let unit = advance()
                result = .pitchOffset(base: result, operation: operation, amount: amount, unit: unit)
            }
            return result
        }

        /// Parses a direct instrument interaction such as `pluck strings[2] q`.
        /// The target uses the canonical actuator path and optional single-member
        /// selector shared with UTAB JSON.
        mutating func parseActuatorExpression() -> TextExpressionSyntax? {
            let action = advance()
            guard let target = parseQualifiedName() else { return nil }
            var member: TextToken?
            if take(.leftBracket) {
                guard current.kind == .integerLiteral || current.kind == .stringLiteral else {
                    diagnose("Expected actuator member index or name")
                    return nil
                }
                member = advance()
                if member?.kind == .integerLiteral, (member?.integerValue ?? 0) < 1 {
                    diagnostics.append(.init(
                        .error,
                        message: "Actuator member indices are one-based positive integers",
                        range: member?.range ?? current.range
                    ))
                    return nil
                }
                guard expect(.rightBracket, "Expected ']' after actuator member") != nil else { return nil }
            }
            guard let duration = parseDuration() else { return nil }
            return .init(kind: .actuator(action: action, target: target, member: member, duration: duration), range: spanning(action, tokens[index - 1]))
        }

        func isActuatorExpressionStart() -> Bool {
            guard current.kind == .identifier, index + 2 < tokens.count,
                  tokens[index + 1].kind == .identifier else { return false }
            var cursor = index + 2
            while cursor + 1 < tokens.count, tokens[cursor].kind == .dot,
                  tokens[cursor + 1].kind == .identifier { cursor += 2 }
            if cursor < tokens.count, tokens[cursor].kind == .leftBracket {
                guard cursor + 3 < tokens.count,
                      tokens[cursor + 1].kind == .integerLiteral || tokens[cursor + 1].kind == .stringLiteral,
                      tokens[cursor + 2].kind == .rightBracket else { return false }
                cursor += 3
            }
            return cursor < tokens.count && tokens[cursor].kind == .identifier && isDuration(tokens[cursor])
        }

        mutating func parseNameBlock() -> [TextToken] {
            guard expect(.leftBrace, "Expected '{'") != nil else { return [] }
            var names: [TextToken] = []
            while current.kind != .rightBrace && current.kind != .endOfFile {
                if take(.semicolon) { continue }
                if let name = expect(.identifier, "Expected section name") { names.append(name) } else { advance() }
                _ = take(.comma); _ = take(.semicolon)
            }
            _ = expect(.rightBrace, "Expected '}'")
            return names
        }

        mutating func parseStringBlock() -> [TextToken] {
            guard expect(.leftBrace, "Expected '{' after lyrics") != nil else { return [] }
            var strings: [TextToken] = []
            while current.kind != .rightBrace && current.kind != .endOfFile {
                if take(.semicolon) { continue }
                if let value = expect(.stringLiteral, "Expected lyric string") { strings.append(value) } else { advance() }
                _ = take(.semicolon)
            }
            _ = expect(.rightBrace, "Expected '}' after lyrics")
            return strings
        }

        mutating func parseNotationDirective() {
            while take(.semicolon) {}
            guard takeKeyword("using") else { return }
            guard expectKeyword("notation", "Expected 'notation' after 'using'") != nil else { return }
            notation = parseQualifiedName()
            if let notation { notationUses.append(notation) }
            requireSequenceSeparator(unlessAt: .rightBrace)
        }

        /// Finds declarations belonging to this sequence without descending into
        /// nested groups. This makes `using` scope-wide rather than source-order
        /// dependent, including when it appears after the first note.
        mutating func scanUsingDirectives(until end: TextTokenKind) -> [ScopedUsing] {
            var cursor = index
            var depth = 0
            var foundNotation: TextQualifiedNameSyntax?
            var techniques: [TextToken] = []
            var dynamic: TextToken?
            var voiceLeading: TextToken?
            while cursor < tokens.count {
                let token = tokens[cursor]
                if depth == 0 && token.kind == end { break }
                if token.kind == .leftBrace || token.kind == .leftParen { depth += 1; cursor += 1; continue }
                if token.kind == .rightBrace || token.kind == .rightParen { depth = max(0, depth - 1); cursor += 1; continue }
                guard depth == 0, token.kind == .identifier, token.lexeme == "using", cursor + 1 < tokens.count else {
                    cursor += 1
                    continue
                }
                let policy = tokens[cursor + 1]
                if policy.lexeme == "notation" {
                    var components: [TextToken] = []
                    var nameCursor = cursor + 2
                    if nameCursor < tokens.count, tokens[nameCursor].kind == .identifier {
                        components.append(tokens[nameCursor]); nameCursor += 1
                        while nameCursor + 1 < tokens.count, tokens[nameCursor].kind == .dot, tokens[nameCursor + 1].kind == .identifier {
                            components.append(tokens[nameCursor + 1]); nameCursor += 2
                        }
                    }
                    if let first = components.first, let last = components.last {
                        let candidate = TextQualifiedNameSyntax(components: components, range: spanning(first, last))
                        if foundNotation != nil { diagnostics.append(.init(.error, message: "A musical scope may contain only one 'using notation' declaration", range: token.range)) }
                        else { foundNotation = candidate }
                    }
                    cursor = max(cursor + 1, nameCursor)
                } else if policy.lexeme == "legato" || policy.lexeme == "slur" {
                    if techniques.contains(where: { $0.lexeme == policy.lexeme }) {
                        diagnostics.append(.init(.error, message: "A musical scope may contain only one 'using \(policy.lexeme)' declaration", range: token.range))
                    } else { techniques.append(policy) }
                    cursor += 2
                } else if policy.lexeme == "dynamics", cursor + 2 < tokens.count, tokens[cursor + 2].kind == .identifier {
                    if dynamic != nil { diagnostics.append(.init(.error, message: "A musical scope may contain only one 'using dynamics' declaration", range: token.range)) }
                    else { dynamic = tokens[cursor + 2] }
                    cursor += 3
                } else if policy.lexeme == "voiceLeading", cursor + 2 < tokens.count, tokens[cursor + 2].kind == .identifier {
                    if voiceLeading != nil { diagnostics.append(.init(.error, message: "A musical scope may contain only one 'using voiceLeading' declaration", range: token.range)) }
                    else { voiceLeading = tokens[cursor + 2] }
                    cursor += 3
                } else { cursor += 1 }
            }
            if let foundNotation {
                notation = foundNotation
                notationUses.append(foundNotation)
            }
            return techniques.map(ScopedUsing.technique) + (dynamic.map { [.dynamic($0)] } ?? []) + (voiceLeading.map { [.voiceLeading($0)] } ?? [])
        }

        mutating func consumeUsingDirective() {
            _ = advance()
            if takeKeyword("notation") { _ = parseQualifiedName(); return }
            if isKeyword("legato") || isKeyword("slur") { _ = advance(); return }
            if takeKeyword("dynamics") { _ = expect(.identifier, "Expected dynamic level after 'using dynamics'"); return }
            if takeKeyword("voiceLeading") { _ = expect(.identifier, "Expected policy after 'using voiceLeading'"); return }
            diagnose("Expected notation, legato, slur, dynamics, or voiceLeading after 'using'")
            if current.kind == .identifier { _ = advance() }
        }

        mutating func parseNaming() -> TextNamingSyntax? {
            guard let name = expect(.identifier, "Expected naming system name"),
                  let open = expect(.leftBrace, "Expected '{' after naming system"),
                  expectKeyword("register", "Expected register policy") != nil,
                  let register = expect(.identifier, "Expected register policy") else { return nil }
            _ = take(.semicolon)
            var entries: [TextNamingSyntax.Entry] = []
            while current.kind != .rightBrace && current.kind != .endOfFile {
                if take(.semicolon) { continue }
                guard expectKeyword("note", "Expected note entry") != nil,
                      let name = expect(.identifier, "Expected note name"),
                      expect(.equal, "Expected '='") != nil,
                      let constructor = expect(.identifier, "Expected letter or degree"),
                      expect(.leftParen, "Expected '('") != nil else { synchronizeBlockItem(); continue }
                let relative = constructor.lexeme == "degree"
                if !relative && constructor.lexeme != "letter" { diagnose("Expected letter or degree constructor") }
                guard let target = expect(relative ? .integerLiteral : .identifier, "Expected canonical pitch target"),
                      expect(.comma, "Expected ','") != nil,
                      let alteration = expect(.integerLiteral, "Expected accidental steps"),
                      expect(.rightParen, "Expected ')'") != nil else { synchronizeBlockItem(); continue }
                entries.append(.init(name: name, target: target, alteration: alteration, relative: relative))
                requireSequenceSeparator(unlessAt: .rightBrace)
            }
            let close = expect(.rightBrace, "Expected '}' after naming system") ?? current
            return .init(name: name, register: register, entries: entries, range: spanning(open, close))
        }

        @_optimize(speed)
        @inline(never)
        mutating func parseDuration() -> TextDurationSyntax? {
            let start = current
            if take(.leftBracket) {
                guard let numerator = expect(.integerLiteral, "Expected duration numerator"),
                      expect(.slash, "Expected '/' in duration") != nil,
                      let denominator = expect(.integerLiteral, "Expected duration denominator"),
                      let close = expect(.rightBracket, "Expected ']' after duration") else { return nil }
                return .init(kind: .fraction(numerator, denominator), range: spanning(start, close))
            }
            guard let name = expect(.identifier, "Expected duration") else { return nil }
            var dots = 0
            var last = name
            while current.kind == .dot {
                if last.range.end != current.range.start { diagnose("Duration dots must immediately follow the duration") }
                last = advance()
                dots += 1
            }
            return .init(kind: .named(name, dots: dots), range: spanning(name, last))
        }

        func isDuration(_ token: TextToken) -> Bool { ["w", "h", "q", "e", "s"].contains(String(token.lexeme)) }
        mutating func expectNumber(_ message: String) -> TextToken? {
            if current.kind == .integerLiteral || current.kind == .decimalLiteral { return advance() }
            diagnose(message); return nil
        }
        mutating func expectIntegerExpression(_ message: String) -> TextToken? {
            if current.kind == .integerLiteral || current.kind == .decimalLiteral || current.kind == .identifier { return advance() }
            diagnose(message); return nil
        }
        mutating func expectKeyword(_ keyword: String, _ message: String) -> TextToken? {
            guard isKeyword(keyword) else { diagnose(message); return nil }
            return advance()
        }
        mutating func takeKeyword(_ keyword: String) -> Bool {
            guard isKeyword(keyword) else { return false }; advance(); return true
        }
        func isKeyword(_ keyword: String) -> Bool { current.kind == .identifier && current.lexeme == keyword }
        mutating func expect(_ kind: TextTokenKind, _ message: String) -> TextToken? {
            guard current.kind == kind else { diagnose(message); return nil }
            return advance()
        }

        mutating func expectChordMember() -> TextToken? {
            if current.kind == .integerLiteral || current.kind == .identifier { return advance() }
            diagnose("Expected root, 3, or 5")
            return nil
        }
        mutating func take(_ kind: TextTokenKind) -> Bool {
            guard current.kind == kind else { return false }; advance(); return true
        }
        @discardableResult mutating func advance() -> TextToken {
            let token = current
            if index < tokens.count - 1 { index += 1 }
            return token
        }
        mutating func diagnose(_ message: String) { diagnostics.append(.init(.error, message: message, range: current.range)) }
        mutating func synchronizeBlockItem() {
            if current.kind != .rightBrace && current.kind != .endOfFile { advance() }
        }
        mutating func requireSequenceSeparator(unlessAt end: TextTokenKind) {
            if take(.semicolon) { return }
            if current.kind != end && current.kind != .endOfFile {
                diagnose("Expected ';' or newline between sequential expressions")
            }
        }
        func spanning(_ first: TextToken, _ last: TextToken) -> SourceRange {
            .init(fileID: first.range.fileID, start: first.range.start, end: last.range.end)
        }
    }
}
