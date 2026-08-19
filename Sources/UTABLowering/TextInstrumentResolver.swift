import Foundation
import UTABComposerText
import UTABInstruments

public struct TextInstrumentResolutionResult: Sendable {
    public let bindings: [String: InstrumentInstanceDefinition]
    public let diagnostics: [TextDiagnostic]

    public var succeeded: Bool { diagnostics.isEmpty }
}

public struct TextInstrumentResolver: Sendable {
    public init() {}

    public func resolve(
        _ declarations: [TextInstrumentInstanceDeclaration],
        in catalog: InstrumentCatalog
    ) -> TextInstrumentResolutionResult {
        var bindings: [String: InstrumentInstanceDefinition] = [:]
        var diagnostics: [TextDiagnostic] = []
        for declaration in declarations {
            let matches = catalog.models.filter {
                $0.id.rawValue == declaration.model
                    || $0.name.caseInsensitiveCompare(declaration.model) == .orderedSame
            }
            guard matches.count == 1, let model = matches.first else {
                let message = matches.isEmpty
                    ? "Unknown instrument model '\(declaration.model)'"
                    : "Ambiguous instrument model '\(declaration.model)'"
                diagnostics.append(.init(.error, message: message, range: declaration.range))
                continue
            }
            if bindings[declaration.name] != nil {
                diagnostics.append(.init(.error, message: "Duplicate instrument instance '\(declaration.name)'", range: declaration.range))
                continue
            }
            bindings[declaration.name] = .init(
                id: .init(rawValue: declaration.name),
                name: declaration.displayName ?? declaration.name,
                model: model.id
            )
        }
        return .init(bindings: bindings, diagnostics: diagnostics)
    }
}
