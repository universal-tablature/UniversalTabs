import UTABComposerCore

public protocol TextModuleProvider: Sendable {
    func source(for moduleName: String) -> TextSource?
}

public struct DictionaryTextModuleProvider: TextModuleProvider {
    public let modules: [String: TextSource]

    public init(_ modules: [String: TextSource]) {
        self.modules = modules
    }

    public func source(for moduleName: String) -> TextSource? {
        modules[moduleName]
    }
}

public struct TextLoadedModule: Sendable {
    public let name: String
    public let syntax: TextCompositionSyntax
    public let isRoot: Bool
}

public struct TextModuleLoadResult: Sendable {
    /// Dependency-first order, with the root module last.
    public let modules: [TextLoadedModule]
    public let diagnostics: [TextDiagnostic]

    public var succeeded: Bool { !diagnostics.contains { $0.severity == .error } }
    public var root: TextLoadedModule? { modules.last { $0.isRoot } }
}

public struct TextModuleLoader: Sendable {
    public init() {}

    public func load(root: TextSource, provider: any TextModuleProvider) -> TextModuleLoadResult {
        var worker = Worker(provider: provider)
        worker.loadRoot(root)
        return .init(modules: worker.modules, diagnostics: worker.diagnostics)
    }

    private struct Worker {
        let provider: any TextModuleProvider
        var modules: [TextLoadedModule] = []
        var loaded: Set<String> = []
        var loading: [String] = []
        var diagnostics: [TextDiagnostic] = []

        mutating func loadRoot(_ source: TextSource) {
            let parsed = TextParser().parse(source)
            diagnostics.append(contentsOf: parsed.diagnostics)
            guard let syntax = parsed.syntax else { return }
            let name = syntax.module?.value ?? source.fileID
            loading.append(name)
            loadImports(of: syntax)
            _ = loading.popLast()
            loaded.insert(name)
            modules.append(.init(name: name, syntax: syntax, isRoot: true))
        }

        mutating func loadImports(of syntax: TextCompositionSyntax) {
            for declaration in syntax.imports {
                load(declaration.name.value, from: declaration.range)
            }
        }

        mutating func load(_ name: String, from range: SourceRange) {
            if loaded.contains(name) { return }
            if let cycleStart = loading.firstIndex(of: name) {
                let cycle = (loading[cycleStart...] + [name]).joined(separator: " -> ")
                diagnostics.append(.init(.error, message: "Cyclic module import: \(cycle)", range: range))
                return
            }
            guard let source = provider.source(for: name) else {
                diagnostics.append(.init(.error, message: "Module '\(name)' was not found", range: range))
                return
            }
            let parsed = TextParser().parse(source)
            diagnostics.append(contentsOf: parsed.diagnostics)
            guard let syntax = parsed.syntax else { return }
            if let declaredName = syntax.module?.value, declaredName != name {
                diagnostics.append(.init(
                    .error,
                    message: "Imported module '\(name)' declares itself as '\(declaredName)'",
                    range: syntax.module?.range ?? syntax.range
                ))
                return
            }
            loading.append(name)
            loadImports(of: syntax)
            _ = loading.popLast()
            guard !loaded.contains(name) else { return }
            loaded.insert(name)
            modules.append(.init(name: name, syntax: syntax, isRoot: false))
        }
    }
}
