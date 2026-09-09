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
