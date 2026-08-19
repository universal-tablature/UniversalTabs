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
            var meter: (TextToken, TextToken)?
            var tempo: TextToken?
            var scale: (TextToken, TextToken)?
            var phrases: [TextPhraseSyntax] = []
            var sections: [TextSectionSyntax] = []
            var main: [TextToken] = []

            while current.kind != .endOfFile {
                if takeKeyword("title") { title = expect(.stringLiteral, "Expected a quoted title") }
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
                } else if takeKeyword("phrase") { if let value = parsePhrase() { phrases.append(value) } }
                else if takeKeyword("section") { if let value = parseSection() { sections.append(value) } }
                else if takeKeyword("main") { main = parseNameBlock() }
                else {
                    diagnose("Expected title, meter, tempo, scale, phrase, section, or main declaration")
                    advance()
                }
                _ = take(.semicolon)
            }
            return .init(
                title: title,
                meter: meter,
                tempo: tempo,
                scale: scale,
                phrases: phrases,
                sections: sections,
                main: main,
                range: .init(fileID: current.range.fileID, start: start, end: current.range.end)
            )
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
                if takeKeyword("lyrics") {
                    lyrics.append(contentsOf: parseStringBlock())
                } else if let expression = parseExpression() {
                    expressions.append(expression)
                } else {
                    synchronizeBlockItem()
                }
            }
            let close = expect(.rightBrace, "Expected '}' after voice") ?? current
            return .init(name: name, lyrics: lyrics, expressions: expressions, range: spanning(open, close))
        }

        mutating func parseExpressions(until end: TextTokenKind) -> [TextExpressionSyntax] {
            var result: [TextExpressionSyntax] = []
            while current.kind != end && current.kind != .endOfFile {
                if let expression = parseExpression() { result.append(expression) }
                else { synchronizeBlockItem() }
                _ = take(.comma); _ = take(.semicolon)
            }
            return result
        }

        mutating func parseExpression() -> TextExpressionSyntax? {
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
        func spanning(_ first: TextToken, _ last: TextToken) -> SourceRange {
            .init(fileID: first.range.fileID, start: first.range.start, end: last.range.end)
        }
    }
}
