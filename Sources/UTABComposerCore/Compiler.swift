public struct CompilerStageResult<Output: Sendable>: Sendable {
    public let output: Output?
    public let diagnostics: [ComposerDiagnostic]

    public init(output: Output?, diagnostics: [ComposerDiagnostic] = []) {
        self.output = output
        self.diagnostics = diagnostics
    }

    public var succeeded: Bool {
        output != nil && !diagnostics.contains { $0.severity == .error }
    }
}

public protocol CompilerStage: Sendable {
    associatedtype Input: Sendable
    associatedtype Output: Sendable

    func run(_ input: Input) -> CompilerStageResult<Output>
}

public enum ResolvedDeclarationKind: String, Sendable, Hashable {
    case phrase
    case section
}

public struct ResolvedDeclaration: Sendable, Hashable {
    public let id: SemanticID
    public let name: String
    public let kind: ResolvedDeclarationKind

    public init(id: SemanticID, name: String, kind: ResolvedDeclarationKind) {
        self.id = id
        self.name = name
        self.kind = kind
    }
}

public struct ResolvedReference: Sendable, Hashable {
    public let originExpressionID: SemanticID?
    public let declaration: ResolvedDeclaration

    public init(originExpressionID: SemanticID?, declaration: ResolvedDeclaration) {
        self.originExpressionID = originExpressionID
        self.declaration = declaration
    }
}

public enum NameResolvedVoiceContent: Sendable, Hashable {
    case expression(MusicalExpression)
    case reference(ResolvedReference)
}

public struct NameResolvedVoice: Sendable, Hashable {
    public let source: Voice
    public let content: [NameResolvedVoiceContent]
}

public struct NameResolvedPart: Sendable, Hashable {
    public let source: Part
    public let voices: [NameResolvedVoice]
}

public struct NameResolvedSection: Sendable, Hashable {
    public let source: Section
    public let parts: [NameResolvedPart]
}

/// Output of name resolution. The semantic source remains immutable while every
/// reference-bearing expression is associated with a validated declaration target.
public struct NameResolvedComposition: Sendable {
    public let source: Composition
    public let declarations: [SemanticID: ResolvedDeclaration]
    public let expressionReferences: [SemanticID: ResolvedReference]
    public let sections: [NameResolvedSection]

    public init(
        source: Composition,
        declarations: [SemanticID: ResolvedDeclaration],
        expressionReferences: [SemanticID: ResolvedReference],
        sections: [NameResolvedSection]
    ) {
        self.source = source
        self.declarations = declarations
        self.expressionReferences = expressionReferences
        self.sections = sections
    }
}

public struct NameResolutionStage: CompilerStage {
    public init() {}

    public func run(_ input: Composition) -> CompilerStageResult<NameResolvedComposition> {
        var resolver = Resolver(composition: input)
        return resolver.resolve()
    }

    private struct Resolver {
        let composition: Composition
        var diagnostics: [ComposerDiagnostic] = []
        var declarations: [SemanticID: ResolvedDeclaration] = [:]
        var phraseNames: [String: ResolvedDeclaration] = [:]
        var expressionReferences: [SemanticID: ResolvedReference] = [:]
        var phraseDependencies: [SemanticID: Set<SemanticID>] = [:]

        mutating func resolve() -> CompilerStageResult<NameResolvedComposition> {
            indexDeclarations()
            resolvePhraseExpressions()
            let sections = resolveSections()
            resolveMain()
            diagnosePhraseCycles()

            guard !diagnostics.contains(where: { $0.severity == .error }) else {
                return .init(output: nil, diagnostics: diagnostics)
            }
            return .init(
                output: .init(
                    source: composition,
                    declarations: declarations,
                    expressionReferences: expressionReferences,
                    sections: sections
                ),
                diagnostics: diagnostics
            )
        }

        mutating func indexDeclarations() {
            var sectionNames = Set<String>()
            for (index, phrase) in composition.phrases.enumerated() {
                let declaration = ResolvedDeclaration(id: phrase.id, name: phrase.name, kind: .phrase)
                insert(declaration, path: "phrases[\(index)]")
                if phraseNames.updateValue(declaration, forKey: phrase.name) != nil {
                    diagnostics.append(.init(.error, path: "phrases[\(index)].name", message: "Duplicate phrase name '\(phrase.name)'"))
                }
            }
            for (index, section) in composition.sections.enumerated() {
                insert(.init(id: section.id, name: section.name, kind: .section), path: "sections[\(index)]")
                if !sectionNames.insert(section.name).inserted {
                    diagnostics.append(.init(.error, path: "sections[\(index)].name", message: "Duplicate section name '\(section.name)'"))
                }
            }
        }

        mutating func insert(_ declaration: ResolvedDeclaration, path: String) {
            if let previous = declarations.updateValue(declaration, forKey: declaration.id) {
                diagnostics.append(.init(
                    .error,
                    path: "\(path).id",
                    message: "Declaration ID '\(declaration.id)' is already used by \(previous.kind.rawValue) '\(previous.name)'"
                ))
            }
        }

        mutating func resolvePhraseExpressions() {
            for (index, phrase) in composition.phrases.enumerated() {
                phraseDependencies[phrase.id] = []
                resolveExpression(phrase.expression, path: "phrases[\(index)].expression", allowedKinds: [.phrase], ownerPhrase: phrase.id)
            }
        }

        mutating func resolveSections() -> [NameResolvedSection] {
            composition.sections.enumerated().map { sectionIndex, section in
                let parts = section.parts.enumerated().map { partIndex, part in
                    let voices = part.voices.enumerated().map { voiceIndex, voice in
                        let basePath = "sections[\(sectionIndex)].parts[\(partIndex)].voices[\(voiceIndex)]"
                        let content: [NameResolvedVoiceContent] = voice.content.enumerated().compactMap { contentIndex, item in
                            let path = "\(basePath).content[\(contentIndex)]"
                            switch item {
                            case .expression(let expression):
                                resolveExpression(expression, path: path, allowedKinds: [.phrase], ownerPhrase: nil)
                                return .expression(expression)
                            case .phrase(let name):
                                guard let declaration = phraseNames[name] else {
                                    diagnostics.append(.init(.error, path: path, message: "Unknown phrase '\(name)'"))
                                    return nil
                                }
                                return .reference(.init(originExpressionID: nil, declaration: declaration))
                            case .reference(let id):
                                guard let reference = resolveReference(id, expressionID: nil, path: path, allowedKinds: [.phrase]) else {
                                    return nil
                                }
                                return .reference(reference)
                            }
                        }
                        return NameResolvedVoice(source: voice, content: content)
                    }
                    return NameResolvedPart(source: part, voices: voices)
                }
                return NameResolvedSection(source: section, parts: parts)
            }
        }

        mutating func resolveMain() {
            guard let main = composition.main else { return }
            resolveExpression(main, path: "main", allowedKinds: [.section], ownerPhrase: nil)
        }

        mutating func resolveExpression(
            _ expression: MusicalExpression,
            path: String,
            allowedKinds: Set<ResolvedDeclarationKind>,
            ownerPhrase: SemanticID?
        ) {
            switch expression.kind {
            case .reference(let id):
                guard let reference = resolveReference(id, expressionID: expression.id, path: path, allowedKinds: allowedKinds) else { return }
                expressionReferences[expression.id] = reference
                if let ownerPhrase, reference.declaration.kind == .phrase {
                    phraseDependencies[ownerPhrase, default: []].insert(reference.declaration.id)
                }
            case .sequence(let children), .parallel(let children):
                for (index, child) in children.enumerated() {
                    resolveExpression(child, path: "\(path)[\(index)]", allowedKinds: allowedKinds, ownerPhrase: ownerPhrase)
                }
            case .repeated(_, let child):
                resolveExpression(child, path: "\(path).repeated", allowedKinds: allowedKinds, ownerPhrase: ownerPhrase)
            case .technique(let application):
                for (index, operand) in application.operands.enumerated() {
                    resolveExpression(operand, path: "\(path).technique.operands[\(index)]", allowedKinds: allowedKinds, ownerPhrase: ownerPhrase)
                }
            case .note, .rest, .chord, .actuator:
                break
            }
        }

        mutating func resolveReference(
            _ id: SemanticID,
            expressionID: SemanticID?,
            path: String,
            allowedKinds: Set<ResolvedDeclarationKind>
        ) -> ResolvedReference? {
            guard let declaration = declarations[id] else {
                diagnostics.append(.init(.error, path: path, message: "Unknown declaration '\(id)'"))
                return nil
            }
            guard allowedKinds.contains(declaration.kind) else {
                let expected = allowedKinds.map(\.rawValue).sorted().joined(separator: " or ")
                diagnostics.append(.init(.error, path: path, message: "Reference to \(declaration.kind.rawValue) '\(declaration.name)' is not valid here; expected \(expected)"))
                return nil
            }
            return .init(originExpressionID: expressionID, declaration: declaration)
        }

        mutating func diagnosePhraseCycles() {
            enum VisitState { case visiting, visited }
            var states: [SemanticID: VisitState] = [:]
            var stack: [SemanticID] = []

            func visit(_ id: SemanticID) -> [SemanticID]? {
                if states[id] == .visiting {
                    guard let start = stack.firstIndex(of: id) else { return [id] }
                    return Array(stack[start...]) + [id]
                }
                if states[id] == .visited { return nil }
                states[id] = .visiting
                stack.append(id)
                for dependency in phraseDependencies[id, default: []].sorted(by: { $0.rawValue < $1.rawValue }) {
                    if let cycle = visit(dependency) { return cycle }
                }
                _ = stack.popLast()
                states[id] = .visited
                return nil
            }

            for id in phraseDependencies.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
                guard let cycle = visit(id) else { continue }
                diagnostics.append(.init(
                    .error,
                    path: "phrases",
                    message: "Recursive phrase reference: \(cycle.map(\.rawValue).joined(separator: " -> "))"
                ))
                return
            }
        }
    }
}
