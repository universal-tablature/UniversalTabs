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
        let tokens: [TextToken]
        var index = 0
        var diagnostics: [TextDiagnostic]
        var hasErrors: Bool { diagnostics.contains { $0.severity == .error } }
        var current: TextToken { tokens[index] }

        mutating func parseDocument() -> TextCompositionSyntax {
            let start = current.range.start
            var title: TextToken?
            var module: TextQualifiedNameSyntax?
            var imports: [TextImportSyntax] = []
            var profiles: [TextInstrumentProfileSyntax] = []
            var models: [TextInstrumentModelSyntax] = []
            var extensions: [TextInstrumentExtensionSyntax] = []
            var meter: (TextToken, TextToken)?
            var tempo: TextToken?
            var scale: (TextToken, TextToken)?
            var instruments: [TextInstrumentInstanceSyntax] = []
            var phrases: [TextPhraseSyntax] = []
            var sections: [TextSectionSyntax] = []
            var main: [TextToken] = []

            while current.kind != .endOfFile {
                if takeKeyword("module") { module = parseQualifiedName() }
                else if takeKeyword("import") {
                    if let name = parseQualifiedName() { imports.append(.init(name: name, range: name.range)) }
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
                    let tonic = expect(.identifier, "Expected scale tonic")
                    let mode = expect(.identifier, "Expected scale mode")
                    if let tonic, let mode { scale = (tonic, mode) }
                } else if takeKeyword("instrument") {
                    if let instrument = parseInstrumentInstance() { instruments.append(instrument) }
                } else if takeKeyword("phrase") { if let value = parsePhrase() { phrases.append(value) } }
                else if takeKeyword("section") { if let value = parseSection() { sections.append(value) } }
                else if takeKeyword("main") { main = parseNameBlock() }
                else {
                    diagnose("Expected module, import, profile, model, extension, title, meter, tempo, scale, instrument, phrase, section, or main declaration")
                    advance()
                }
                _ = take(.semicolon)
            }
            return .init(
                module: module,
                imports: imports,
                profiles: profiles,
                models: models,
                extensions: extensions,
                title: title,
                meter: meter,
                tempo: tempo,
                scale: scale,
                instruments: instruments,
                phrases: phrases,
                sections: sections,
                main: main,
                range: .init(fileID: current.range.fileID, start: start, end: current.range.end)
            )
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
            while current.kind != .rightBrace && current.kind != .endOfFile {
                if take(.semicolon) { continue }
                if takeKeyword("targets") { targets.append(contentsOf: parseIdentifierList()) }
                else if takeKeyword("effectors") { effectors.append(contentsOf: parseIdentifierList()) }
                else { diagnose("Expected targets or effectors in interaction"); synchronizeBlockItem() }
                _ = take(.semicolon)
            }
            let close = expect(.rightBrace, "Expected '}' after interaction") ?? current
            return .init(name: name, targets: targets, effectors: effectors, range: spanning(open, close))
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
            guard let name = expect(.identifier, "Expected property name") else { return nil }
            guard current.kind == .identifier || current.kind == .stringLiteral || current.kind == .integerLiteral || current.kind == .decimalLiteral else {
                diagnose("Expected property value"); return nil
            }
            let value = advance()
            return .init(name: name, value: value, range: spanning(name, value))
        }

        mutating func parseInstrumentExtension() -> TextInstrumentExtensionSyntax? {
            guard let model = parseSymbolReference("Expected instrument model name"),
                  let open = expect(.leftBrace, "Expected '{' after extension target") else { return nil }
            var tunings: [TextTuningSyntax] = []
            var fingerings: [TextFingeringSyntax] = []
            while current.kind != .rightBrace && current.kind != .endOfFile {
                if take(.semicolon) { continue }
                if takeKeyword("tuning") {
                    if let tuning = parseTuning() { tunings.append(tuning) }
                } else if takeKeyword("fingering") {
                    if let fingering = parseFingering() { fingerings.append(fingering) }
                } else { diagnose("Expected tuning or fingering declaration"); synchronizeBlockItem(); continue }
                _ = take(.semicolon)
            }
            let close = expect(.rightBrace, "Expected '}' after extension") ?? current
            return .init(model: model, tunings: tunings, fingerings: fingerings, range: spanning(open, close))
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
            return .init(symbol: symbol, isDefault: isDefault, properties: properties, tags: tags, courses: courses, range: spanning(open, close))
        }

        mutating func parseInstrumentInstance() -> TextInstrumentInstanceSyntax? {
            guard let name = expect(.identifier, "Expected instrument instance name"),
                  expect(.colon, "Expected ':' after instrument instance name") != nil else { return nil }
            guard let model = parseSymbolReference("Expected instrument model name") else { return nil }
            var displayName: TextToken?
            if takeKeyword("as") { displayName = expect(.stringLiteral, "Expected quoted instrument display name") }
            let end = displayName?.range.end ?? model.range.end
            return .init(name: name, model: model, displayName: displayName, range: .init(fileID: name.range.fileID, start: name.range.start, end: end))
        }

        mutating func parsePhrase() -> TextPhraseSyntax? {
            guard let name = expect(.identifier, "Expected phrase name"), let open = expect(.leftBrace, "Expected '{' after phrase name") else { return nil }
            let expressions = parseExpressions(until: .rightBrace)
            let close = expect(.rightBrace, "Expected '}' after phrase") ?? current
            return .init(name: name, expressions: expressions, range: spanning(open, close))
        }

        mutating func parseSection() -> TextSectionSyntax? {
            guard let name = expect(.identifier, "Expected section name") else { return nil }
            var bars: TextToken?
            if take(.colon) {
                bars = expect(.integerLiteral, "Expected section bar count")
                _ = expectKeyword("bars", "Expected 'bars' after section length")
            }
            guard let open = expect(.leftBrace, "Expected '{' after section name") else { return nil }
            var instruments: [TextInstrumentSyntax] = []
            while current.kind != .rightBrace && current.kind != .endOfFile {
                if take(.semicolon) { continue }
                if let instrument = parseInstrument() { instruments.append(instrument) } else { synchronizeBlockItem() }
            }
            let close = expect(.rightBrace, "Expected '}' after section") ?? current
            return .init(name: name, barCount: bars, instruments: instruments, range: spanning(open, close))
        }

        mutating func parseInstrument() -> TextInstrumentSyntax? {
            guard current.kind == .identifier || current.kind == .stringLiteral else {
                diagnose("Expected instrument instance name"); return nil
            }
            let name = advance()
            guard let open = expect(.leftBrace, "Expected '{' after instrument instance name") else { return nil }
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

        mutating func parseExpressions(until end: TextTokenKind) -> [TextExpressionSyntax] {
            var result: [TextExpressionSyntax] = []
            while current.kind != end && current.kind != .endOfFile {
                if take(.semicolon) { continue }
                if let expression = parseTemporalGroup() { result.append(expression) }
                else { synchronizeBlockItem() }
                requireSequenceSeparator(unlessAt: end)
            }
            return result
        }

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

        mutating func parseExpression() -> TextExpressionSyntax? {
            if take(.atSign) {
                let start = tokens[index - 1]
                guard let degree = expect(.integerLiteral, "Expected scale degree after '@'"),
                      expect(.leftBracket, "Expected '[' before relative octave") != nil,
                      let octave = expect(.integerLiteral, "Expected relative octave"),
                      expect(.rightBracket, "Expected ']' after relative octave") != nil,
                      let duration = expect(.identifier, "Expected note duration") else { return nil }
                return .init(kind: .relativeNote(degree: degree, octave: octave, duration: duration), range: spanning(start, duration))
            }
            if takeKeyword("chord") {
                let start = tokens[index - 1]
                guard let root = expect(.identifier, "Expected chord root"),
                      let quality = expect(.identifier, "Expected chord quality"),
                      let duration = expect(.identifier, "Expected chord duration") else { return nil }
                return .init(kind: .chord(root: root, quality: quality, duration: duration), range: spanning(start, duration))
            }
            if takeKeyword("repeat") {
                let keyword = tokens[index - 1]
                guard let count = expect(.integerLiteral, "Expected repeat count"), expect(.leftBrace, "Expected '{' after repeat count") != nil else { return nil }
                let children = parseExpressions(until: .rightBrace)
                let close = expect(.rightBrace, "Expected '}' after repeat") ?? current
                return .init(kind: .repeated(count: count, expressions: children), range: spanning(keyword, close))
            }
            if takeKeyword("bar") {
                let keyword = tokens[index - 1]
                guard expect(.leftBrace, "Expected '{' after bar") != nil else { return nil }
                let children = parseExpressions(until: .rightBrace)
                let close = expect(.rightBrace, "Expected '}' after bar") ?? current
                return .init(kind: .bar(children), range: spanning(keyword, close))
            }
            if takeKeyword("rest") {
                let keyword = tokens[index - 1]
                guard let duration = expect(.identifier, "Expected rest duration") else { return nil }
                return .init(kind: .rest(duration: duration), range: spanning(keyword, duration))
            }
            guard current.kind == .identifier else { diagnose("Expected musical expression"); return nil }
            let first = advance()
            if current.kind == .identifier, isDuration(current) {
                let duration = advance()
                return .init(kind: .note(pitch: first, duration: duration), range: spanning(first, duration))
            }
            return .init(kind: .reference(first), range: first.range)
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

        func isDuration(_ token: TextToken) -> Bool { ["w", "h", "q", "e", "s"].contains(String(token.lexeme)) }
        mutating func expectNumber(_ message: String) -> TextToken? {
            if current.kind == .integerLiteral || current.kind == .decimalLiteral { return advance() }
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
