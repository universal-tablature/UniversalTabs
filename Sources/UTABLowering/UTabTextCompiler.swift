import Foundation
import UTABComposerCore
import UTABComposerText
import UTABInstruments
import UniversalTabs

public enum UTabTextOutputFormat: String, Sendable, Hashable, CaseIterable {
    case uTabJSON
    case midi

    public var fileExtension: String {
        switch self {
        case .uTabJSON: "utab.json"
        case .midi: "mid"
        }
    }

    public var mediaType: String {
        switch self {
        case .uTabJSON: "application/json"
        case .midi: "audio/midi"
        }
    }
}

public struct UTabTextCompilerOptions: Sendable, Hashable {
    public let outputs: Set<UTabTextOutputFormat>
    public let prettyPrintedJSON: Bool

    public init(outputs: Set<UTabTextOutputFormat> = [], prettyPrintedJSON: Bool = true) {
        self.outputs = outputs
        self.prettyPrintedJSON = prettyPrintedJSON
    }
}

public struct UTabTextArtifact: Sendable, Hashable {
    public let format: UTabTextOutputFormat
    public let suggestedFileExtension: String
    public let mediaType: String
    public let data: Data
}

public struct UTabTextCompilerDiagnostic: Sendable, Hashable, CustomStringConvertible {
    public enum Severity: String, Sendable, Hashable { case warning, error }
    public enum Stage: String, Sendable, Hashable { case modules, catalog, syntax, semantics, pipeline, backend }

    public let severity: Severity
    public let stage: Stage
    public let message: String
    public let range: SourceRange?
    public let path: String?

    public var description: String {
        if let range {
            return "\(range.fileID):\(range.start.line):\(range.start.column): \(severity.rawValue): \(message)"
        }
        if let path, !path.isEmpty { return "\(path): \(severity.rawValue): \(message)" }
        return "\(severity.rawValue): \(message)"
    }
}

public struct UTabTextCompilationResult: Sendable {
    public let modules: [TextLoadedModule]
    public let catalog: InstrumentCatalog
    public let composition: Composition?
    public let instrumentBindings: [String: InstrumentInstanceDefinition]
    public let document: UTabDocument?
    public let artifacts: [UTabTextArtifact]
    public let diagnostics: [UTabTextCompilerDiagnostic]

    public var succeeded: Bool {
        document != nil && !diagnostics.contains { $0.severity == .error }
    }

    public func artifact(_ format: UTabTextOutputFormat) -> UTabTextArtifact? {
        artifacts.first { $0.format == format }
    }
}

/// End-to-end compiler for authored `.utab` source. The module provider remains caller-owned,
/// allowing package, filesystem, mmap, editor, or in-memory source stores to use one pipeline.
public struct UTabTextCompiler: Sendable {
    public let baseCatalog: InstrumentCatalog

    public init(baseCatalog: InstrumentCatalog = .init(profiles: [], models: [])) {
        self.baseCatalog = baseCatalog
    }

    public func compile(
        _ root: TextSource,
        modules provider: any TextModuleProvider,
        options: UTabTextCompilerOptions = .init()
    ) -> UTabTextCompilationResult {
        let loaded = TextModuleLoader().load(root: root, provider: provider)
        var diagnostics = loaded.diagnostics.map { diagnostic($0, stage: .modules) }
        guard loaded.succeeded, let rootModule = loaded.root else {
            return result(modules: loaded.modules, diagnostics: diagnostics)
        }

        let catalogResult = TextInstrumentCatalogCompiler().compile(loaded.modules, extending: baseCatalog)
        diagnostics += catalogResult.diagnostics.map { diagnostic($0, stage: .catalog) }
        guard catalogResult.succeeded else {
            return result(modules: loaded.modules, catalog: catalogResult.catalog, diagnostics: diagnostics)
        }

        let semantic = TextSemanticLowerer().lower(rootModule.syntax)
        diagnostics += semantic.diagnostics.map { diagnostic($0, stage: .semantics) }
        guard semantic.succeeded, let composition = semantic.composition else {
            return result(modules: loaded.modules, catalog: catalogResult.catalog, composition: semantic.composition, diagnostics: diagnostics)
        }

        let resolution = TextInstrumentResolver().resolve(
            semantic.instruments,
            in: catalogResult.catalog,
            modelBindings: catalogResult.modelBindings
        )
        diagnostics += resolution.diagnostics.map { diagnostic($0, stage: .semantics) }
        guard resolution.succeeded else {
            return result(modules: loaded.modules, catalog: catalogResult.catalog, composition: composition, bindings: resolution.bindings, diagnostics: diagnostics)
        }

        let compiled = UTABCompositionCompiler(catalog: catalogResult.catalog, instrumentBindings: resolution.bindings).compile(composition)
        diagnostics += compiled.diagnostics.map(diagnostic)
        guard let document = compiled.output else {
            return result(modules: loaded.modules, catalog: catalogResult.catalog, composition: composition, bindings: resolution.bindings, diagnostics: diagnostics)
        }

        var artifacts: [UTabTextArtifact] = []
        if options.outputs.contains(.uTabJSON) {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = options.prettyPrintedJSON ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
                artifacts.append(artifact(.uTabJSON, data: try encoder.encode(document)))
            } catch {
                diagnostics.append(.init(severity: .error, stage: .backend, message: "UTAB JSON encoding failed: \(error)", range: nil, path: nil))
            }
        }
        if options.outputs.contains(.midi) {
            let converted = UTabMIDIConverter().convert(document: document)
            artifacts.append(artifact(.midi, data: converted.midi))
            diagnostics += converted.diagnostics.map {
                .init(severity: .warning, stage: .backend, message: $0, range: nil, path: nil)
            }
        }

        return .init(
            modules: loaded.modules,
            catalog: catalogResult.catalog,
            composition: composition,
            instrumentBindings: resolution.bindings,
            document: document,
            artifacts: artifacts,
            diagnostics: diagnostics
        )
    }

    private func result(
        modules: [TextLoadedModule],
        catalog: InstrumentCatalog? = nil,
        composition: Composition? = nil,
        bindings: [String: InstrumentInstanceDefinition] = [:],
        diagnostics: [UTabTextCompilerDiagnostic]
    ) -> UTabTextCompilationResult {
        .init(modules: modules, catalog: catalog ?? baseCatalog, composition: composition, instrumentBindings: bindings, document: nil, artifacts: [], diagnostics: diagnostics)
    }

    private func artifact(_ format: UTabTextOutputFormat, data: Data) -> UTabTextArtifact {
        .init(format: format, suggestedFileExtension: format.fileExtension, mediaType: format.mediaType, data: data)
    }

    private func diagnostic(_ value: TextDiagnostic, stage: UTabTextCompilerDiagnostic.Stage) -> UTabTextCompilerDiagnostic {
        .init(
            severity: value.severity == .error ? .error : .warning,
            stage: stage,
            message: value.message,
            range: value.range,
            path: nil
        )
    }

    private func diagnostic(_ value: ComposerDiagnostic) -> UTabTextCompilerDiagnostic {
        .init(
            severity: value.severity == .error ? .error : .warning,
            stage: .pipeline,
            message: value.message,
            range: nil,
            path: value.path
        )
    }
}
