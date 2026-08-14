public struct ComposerDiagnostic: Sendable, Hashable, CustomStringConvertible {
    public enum Severity: String, Sendable { case warning, error }
    public let severity: Severity
    public let path: String
    public let message: String

    public init(_ severity: Severity, path: String, message: String) {
        self.severity = severity; self.path = path; self.message = message
    }

    public var description: String { "\(severity.rawValue): \(path): \(message)" }
}

public struct CompositionValidator: Sendable {
    public init() {}

    public func validate(_ composition: Composition) -> [ComposerDiagnostic] {
        var diagnostics: [ComposerDiagnostic] = []
        if composition.tempo <= 0 {
            diagnostics.append(.init(.error, path: "tempo", message: "Tempo must be positive"))
        }

        var phrases: [String: Phrase] = [:]
        for (index, phrase) in composition.phrases.enumerated() {
            if phrases.updateValue(phrase, forKey: phrase.name) != nil {
                diagnostics.append(.init(.error, path: "phrases[\(index)].name", message: "Duplicate phrase '\(phrase.name)'"))
            }
            for (barIndex, bar) in phrase.bars.enumerated() where bar.expression.duration != composition.meter.duration {
                diagnostics.append(.init(
                    .error,
                    path: "phrases[\(index)].bars[\(barIndex)]",
                    message: "Bar duration is \(bar.expression.duration); expected \(composition.meter.duration)"
                ))
            }
        }

        for (sectionIndex, section) in composition.sections.enumerated() {
            for (partIndex, part) in section.parts.enumerated() {
                for (voiceIndex, voice) in part.voices.enumerated() {
                    let path = "sections[\(sectionIndex)].parts[\(partIndex)].voices[\(voiceIndex)]"
                    var duration = MusicalDuration.zero
                    for item in voice.content {
                        switch item {
                        case .expression(let expression): duration = duration + expression.duration
                        case .phrase(let name):
                            guard let phrase = phrases[name] else {
                                diagnostics.append(.init(.error, path: path, message: "Unknown phrase '\(name)'"))
                                continue
                            }
                            duration = duration + phrase.duration
                        }
                    }
                    if duration != section.duration {
                        diagnostics.append(.init(.error, path: path, message: "Voice duration is \(duration); expected section duration \(section.duration)"))
                    }
                }
            }
        }
        return diagnostics
    }
}
