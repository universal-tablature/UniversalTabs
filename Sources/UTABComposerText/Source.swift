import UTABComposerCore

/// Immutable source storage shared by all token substrings.
public struct TextSource: Sendable, Hashable {
    public let fileID: String
    public let text: String

    public init(_ text: String, fileID: String = UTabComposerLanguage.syntheticFileID) {
        precondition(!fileID.isEmpty, "A source file ID cannot be empty")
        self.fileID = fileID
        self.text = text
    }
}

public enum TextTokenKind: String, Sendable, Hashable {
    case identifier
    case integerLiteral
    case decimalLiteral
    case stringLiteral
    case leftBrace
    case rightBrace
    case leftParen
    case rightParen
    case colon
    case dot
    case comma
    case slash
    case semicolon
    case newline
    case atSign
    case leftBracket
    case rightBracket
    case endOfFile
    case invalid
}

public struct TextToken: Sendable, Hashable {
    public let kind: TextTokenKind
    public let lexeme: Substring
    public let range: SourceRange
    public let isSynthesized: Bool

    public init(kind: TextTokenKind, lexeme: Substring, range: SourceRange, isSynthesized: Bool = false) {
        self.kind = kind
        self.lexeme = lexeme
        self.range = range
        self.isSynthesized = isSynthesized
    }

    public var stringValue: String? {
        guard kind == .stringLiteral, lexeme.count >= 2 else { return nil }
        var result = ""
        var escaped = false
        for character in lexeme.dropFirst().dropLast() {
            if escaped {
                switch character {
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "t": result.append("\t")
                case "\"": result.append("\"")
                case "\\": result.append("\\")
                default: result.append(character)
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                result.append(character)
            }
        }
        return escaped ? nil : result
    }

    public var integerValue: Int? {
        guard kind == .integerLiteral else { return nil }
        return Int(lexeme)
    }

    public var decimalValue: Double? {
        guard kind == .integerLiteral || kind == .decimalLiteral else { return nil }
        return Double(lexeme)
    }
}

public struct TextDiagnostic: Sendable, Hashable, CustomStringConvertible {
    public enum Severity: String, Sendable, Hashable { case warning, error }

    public let severity: Severity
    public let message: String
    public let range: SourceRange

    public init(_ severity: Severity, message: String, range: SourceRange) {
        self.severity = severity
        self.message = message
        self.range = range
    }

    public var description: String {
        "\(range.fileID):\(range.start.line):\(range.start.column): \(severity.rawValue): \(message)"
    }
}

public struct TextLexResult: Sendable {
    public let tokens: [TextToken]
    public let diagnostics: [TextDiagnostic]
}

public struct TextLexer: Sendable {
    public init() {}

    public func lex(_ source: TextSource) -> TextLexResult {
        var scanner = Scanner(source: source)
        return scanner.scan()
    }

    private struct Scanner {
        let source: TextSource
        var index: String.Index
        var line = 1
        var column = 1
        var tokens: [TextToken] = []
        var diagnostics: [TextDiagnostic] = []

        init(source: TextSource) {
            self.source = source
            self.index = source.text.startIndex
        }

        mutating func scan() -> TextLexResult {
            while index < source.text.endIndex {
                skipTrivia()
                guard index < source.text.endIndex else { break }
                let start = index
                let position = SourcePosition(line: line, column: column)
                let character = source.text[index]
                if character == "\n" {
                    advance()
                    append(.newline, from: start, position: position)
                } else if isIdentifierStart(character) { scanIdentifier(from: start, position: position) }
                else if character.isNumber || isSignBeforeNumber(character) {
                    scanNumber(from: start, position: position)
                }
                else if character == "\"" { scanString(from: start, position: position) }
                else if let kind = punctuation(character) {
                    advance()
                    append(kind, from: start, position: position)
                } else {
                    advance()
                    append(.invalid, from: start, position: position)
                    diagnostics.append(.init(.error, message: "Unexpected character '\(character)'", range: tokens[tokens.count - 1].range))
                }
            }
            let position = SourcePosition(line: line, column: column)
            let empty = source.text[index..<index]
            tokens.append(.init(kind: .endOfFile, lexeme: empty, range: .init(fileID: source.fileID, start: position, end: position)))
            return .init(tokens: insertingSemicolons(tokens), diagnostics: diagnostics)
        }

        mutating func skipTrivia() {
            while index < source.text.endIndex {
                if source.text[index] == " " || source.text[index] == "\t" || source.text[index] == "\r" { advance(); continue }
                let next = source.text.index(after: index)
                if source.text[index] == "/", next < source.text.endIndex, source.text[next] == "/" {
                    while index < source.text.endIndex, source.text[index] != "\n" { advance() }
                    continue
                }
                break
            }
        }

        mutating func scanIdentifier(from start: String.Index, position: SourcePosition) {
            while index < source.text.endIndex, isIdentifierContinue(source.text[index]) { advance() }
            append(.identifier, from: start, position: position)
        }

        mutating func scanNumber(from start: String.Index, position: SourcePosition) {
            if source.text[index] == "-" || source.text[index] == "+" { advance() }
            while index < source.text.endIndex, source.text[index].isNumber { advance() }
            var kind = TextTokenKind.integerLiteral
            if index < source.text.endIndex, source.text[index] == "." {
                let afterDot = source.text.index(after: index)
                if afterDot < source.text.endIndex, source.text[afterDot].isNumber {
                    kind = .decimalLiteral
                    advance()
                    while index < source.text.endIndex, source.text[index].isNumber { advance() }
                }
            }
            append(kind, from: start, position: position)
        }

        func isSignBeforeNumber(_ character: Character) -> Bool {
            guard character == "-" || character == "+" else { return false }
            let next = source.text.index(after: index)
            return next < source.text.endIndex && source.text[next].isNumber
        }

        mutating func scanString(from start: String.Index, position: SourcePosition) {
            advance()
            var escaped = false
            while index < source.text.endIndex {
                let character = source.text[index]
                if character == "\n" && !escaped { break }
                advance()
                if character == "\"" && !escaped {
                    append(.stringLiteral, from: start, position: position)
                    return
                }
                escaped = character == "\\" && !escaped
                if character != "\\" { escaped = false }
            }
            append(.invalid, from: start, position: position)
            diagnostics.append(.init(.error, message: "Unterminated string literal", range: tokens[tokens.count - 1].range))
        }

        mutating func append(_ kind: TextTokenKind, from start: String.Index, position: SourcePosition) {
            let range = SourceRange(fileID: source.fileID, start: position, end: .init(line: line, column: column))
            tokens.append(.init(kind: kind, lexeme: source.text[start..<index], range: range))
        }

        mutating func advance() {
            let character = source.text[index]
            index = source.text.index(after: index)
            if character == "\n" { line += 1; column = 1 } else { column += 1 }
        }

        func isIdentifierStart(_ character: Character) -> Bool { character == "_" || character.isLetter }
        func isIdentifierContinue(_ character: Character) -> Bool { isIdentifierStart(character) || character.isNumber || character == "-" || character == "#" }
        func punctuation(_ character: Character) -> TextTokenKind? {
            switch character {
            case "{": .leftBrace; case "}": .rightBrace; case "(": .leftParen; case ")": .rightParen
            case "[": .leftBracket; case "]": .rightBracket; case "@": .atSign
            case ":": .colon; case ".": .dot; case ",": .comma; case "/": .slash; case ";": .semicolon
            default: nil
            }
        }

        func insertingSemicolons(_ input: [TextToken]) -> [TextToken] {
            var result: [TextToken] = []
            var parenthesisDepth = 0
            for (tokenIndex, token) in input.enumerated() {
                if token.kind == .leftParen { parenthesisDepth += 1 }
                if token.kind == .rightParen { parenthesisDepth = max(0, parenthesisDepth - 1) }
                guard token.kind == .newline else {
                    result.append(token)
                    continue
                }
                guard parenthesisDepth == 0,
                      let previous = result.last,
                      let next = input[(tokenIndex + 1)...].first(where: { $0.kind != .newline }),
                      canEndStatement(previous.kind),
                      canFollowInsertedSemicolon(next.kind) else { continue }
                let position = token.range.start
                result.append(.init(
                    kind: .semicolon,
                    lexeme: token.lexeme.prefix(0),
                    range: .init(fileID: token.range.fileID, start: position, end: position),
                    isSynthesized: true
                ))
            }
            return result
        }

        func canEndStatement(_ kind: TextTokenKind) -> Bool {
            switch kind {
            case .identifier, .integerLiteral, .decimalLiteral, .stringLiteral, .rightBrace, .rightParen: true
            default: false
            }
        }

        func canFollowInsertedSemicolon(_ kind: TextTokenKind) -> Bool {
            switch kind {
            case .leftBrace, .comma, .semicolon, .colon, .dot, .slash, .rightParen, .endOfFile: false
            default: true
            }
        }
    }
}
