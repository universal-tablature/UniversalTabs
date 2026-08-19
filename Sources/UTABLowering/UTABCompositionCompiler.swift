import UTABComposerCore
import UTABInstruments
import UniversalTabs

public struct UTABCompositionCompiler: Sendable {
    public let catalog: InstrumentCatalog
    public let instrumentBindings: [String: InstrumentInstanceDefinition]

    public init(
        catalog: InstrumentCatalog,
        instrumentBindings: [String: InstrumentInstanceDefinition]
    ) {
        self.catalog = catalog
        self.instrumentBindings = instrumentBindings
    }

    public func compile(_ composition: Composition) -> CompilerStageResult<UTabDocument> {
        var diagnostics = CompositionValidator().validate(composition)
        guard !hasErrors(diagnostics) else { return .init(output: nil, diagnostics: diagnostics) }

        let named = NameResolutionStage().run(composition)
        diagnostics += named.diagnostics
        guard let namedOutput = named.output else { return .init(output: nil, diagnostics: diagnostics) }

        let expanded = ReferenceExpansionStage().run(namedOutput)
        diagnostics += expanded.diagnostics
        guard let expandedOutput = expanded.output else { return .init(output: nil, diagnostics: diagnostics) }

        let timed = TemporalResolutionStage().run(expandedOutput)
        diagnostics += timed.diagnostics
        guard let timedOutput = timed.output else { return .init(output: nil, diagnostics: diagnostics) }

        let aligned = LyricAlignmentStage().run(timedOutput)
        diagnostics += aligned.diagnostics
        guard let alignedOutput = aligned.output else { return .init(output: nil, diagnostics: diagnostics) }

        let pitched = PitchResolutionStage().run(alignedOutput)
        diagnostics += pitched.diagnostics
        guard let pitchedOutput = pitched.output else { return .init(output: nil, diagnostics: diagnostics) }

        let realized = InstrumentRealizationStage().run(.init(
            composition: pitchedOutput,
            catalog: catalog,
            instrumentBindings: instrumentBindings
        ))
        diagnostics += realized.diagnostics
        guard let realizedOutput = realized.output else { return .init(output: nil, diagnostics: diagnostics) }

        let lowered = MinimalUTabLoweringStage().run(realizedOutput)
        diagnostics += lowered.diagnostics
        return .init(output: lowered.output, diagnostics: diagnostics)
    }

    private func hasErrors(_ diagnostics: [ComposerDiagnostic]) -> Bool {
        diagnostics.contains { $0.severity == .error }
    }
}
