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
            for (barIndex, bar) in phrase.bars.enumerated() {
                let expectedDuration = bar.meter?.duration ?? composition.meter.duration
                guard let actualDuration = bar.expression.duration else {
                    diagnostics.append(.init(
                        .error,
                        path: "phrases[\(index)].bars[\(barIndex)]",
                        message: "Bar duration cannot be determined before reference resolution"
                    ))
                    continue
                }
                guard actualDuration != expectedDuration else { continue }
                diagnostics.append(.init(
                    .error,
                    path: "phrases[\(index)].bars[\(barIndex)]",
                    message: "Bar duration is \(actualDuration); expected \(expectedDuration)"
                ))
            }
        }

        for (sectionIndex, section) in composition.sections.enumerated() {
            for (partIndex, part) in section.parts.enumerated() {
                for (voiceIndex, voice) in part.voices.enumerated() {
                    let path = "sections[\(sectionIndex)].parts[\(partIndex)].voices[\(voiceIndex)]"
                    var duration: MusicalDuration? = .zero
                    for item in voice.content {
                        switch item {
                        case .expression(let expression):
                            guard let current = duration, let expressionDuration = expression.duration else {
                                duration = nil
                                continue
                            }
                            duration = current + expressionDuration
                        case .phrase(let name):
                            guard let phrase = phrases[name] else {
                                diagnostics.append(.init(.error, path: path, message: "Unknown phrase '\(name)'"))
                                continue
                            }
                            guard let current = duration, let phraseDuration = phrase.duration else {
                                duration = nil
                                continue
                            }
                            duration = current + phraseDuration
                        case .reference(let id):
                            guard let phrase = composition.phrases.first(where: { $0.id == id }) else {
                                diagnostics.append(.init(.error, path: path, message: "Unknown declaration '\(id)'"))
                                continue
                            }
                            guard let current = duration, let phraseDuration = phrase.duration else {
                                duration = nil
                                continue
                            }
                            duration = current + phraseDuration
                        }
                    }
                    guard let expectedDuration = section.expectedDuration else { continue }
                    guard let duration else {
                        diagnostics.append(.init(.error, path: path, message: "Voice duration cannot be determined before reference resolution"))
                        continue
                    }
                    if duration != expectedDuration {
                        diagnostics.append(.init(.error, path: path, message: "Voice duration is \(duration); expected section duration \(expectedDuration)"))
                    }
                }
            }
        }
        return diagnostics
    }
}
