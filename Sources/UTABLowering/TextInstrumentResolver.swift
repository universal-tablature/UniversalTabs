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
        in catalog: InstrumentCatalog,
        modelBindings: [String: InstrumentID] = [:]
    ) -> TextInstrumentResolutionResult {
        var bindings: [String: InstrumentInstanceDefinition] = [:]
        var diagnostics: [TextDiagnostic] = []
        for declaration in declarations {
            let matches = catalog.models.filter {
                $0.id.rawValue == declaration.model
                    || $0.name.caseInsensitiveCompare(declaration.model) == .orderedSame
                    || modelBindings[declaration.model] == $0.id
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
            let tuning: InstrumentID?
            if let requested = declaration.tuning {
                func normalized(_ value: String) -> String {
                    value.lowercased().filter(\.isLetter)
                }
                let candidates = catalog.tunings.filter {
                    model.tunings.contains($0.id) && (
                        $0.id.rawValue == requested
                            || $0.id.rawValue.split(separator: ":").last.map(String.init) == requested
                            || $0.id.rawValue.split(separator: ":").last.map { normalized(String($0)) == normalized(requested) } == true
                            || $0.name.caseInsensitiveCompare(requested) == .orderedSame
                    )
                }
                guard candidates.count == 1, let selected = candidates.first else {
                    diagnostics.append(.init(.error, message: candidates.isEmpty ? "Unknown tuning '\(requested)' for '\(model.name)'" : "Ambiguous tuning '\(requested)' for '\(model.name)'", range: declaration.range))
                    continue
                }
                tuning = selected.id
            } else { tuning = model.defaultTuning }
            let fingering: InstrumentID?
            if let requested = declaration.fingering {
                let candidates = catalog.fingerings.filter {
                    model.fingerings.contains($0.id) && ($0.id.rawValue == requested || $0.name.caseInsensitiveCompare(requested) == .orderedSame)
                }
                guard candidates.count == 1, let selected = candidates.first else {
                    diagnostics.append(.init(.error, message: candidates.isEmpty ? "Unknown fingering '\(requested)' for '\(model.name)'" : "Ambiguous fingering '\(requested)' for '\(model.name)'", range: declaration.range))
                    continue
                }
                fingering = selected.id
            } else { fingering = model.defaultFingering }
            bindings[declaration.name] = .init(
                id: .init(rawValue: declaration.name),
                name: declaration.displayName ?? declaration.name,
                model: model.id,
                tuning: tuning,
                fingering: fingering
            )
        }
        return .init(bindings: bindings, diagnostics: diagnostics)
    }
}
