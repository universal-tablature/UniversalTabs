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
import UTABComposerCore

public enum UTabComposerLanguage {
    /// Composer source uses `.utab`; serialized interchange documents remain `.utab.json`.
    public static let fileExtension = "utab"
    public static let syntheticFileID = "<memory>"
}

public struct ExpectedTextDiagnostic: Sendable, Hashable {
    public let severity: TextDiagnostic.Severity
    public let line: Int
    public let messageSubstring: String
    public let directiveRange: SourceRange
}

public struct TextDiagnosticVerificationIssue: Sendable, Hashable, CustomStringConvertible {
    public enum Kind: String, Sendable, Hashable {
        case malformedDirective
        case missingDiagnostic
        case unexpectedDiagnostic
    }

    public let kind: Kind
    public let message: String
    public let range: SourceRange

    public var description: String {
        "\(range.fileID):\(range.start.line):\(range.start.column): \(kind.rawValue): \(message)"
    }
}

public struct TextDiagnosticVerificationResult: Sendable {
    public let diagnostics: [TextDiagnostic]
    public let expectations: [ExpectedTextDiagnostic]
    public let issues: [TextDiagnosticVerificationIssue]

    public var succeeded: Bool { issues.isEmpty }
}

/// Verifies clang-style diagnostics embedded in line comments:
/// `// expected-error {{message text}}` or
/// `// expected-warning@+1 {{message text}}`.
public struct TextDiagnosticVerifier: Sendable {
    public init() {}

    public func verify(_ source: TextSource) -> TextDiagnosticVerificationResult {
        let diagnostics = TextCompositionFrontend().compile(source).diagnostics
        return verify(source, diagnostics: diagnostics)
    }

    public func verify(_ source: TextSource, diagnostics: [TextDiagnostic]) -> TextDiagnosticVerificationResult {
        let parsed = parseExpectations(source)
        var issues = parsed.issues
        var unmatched = Array(diagnostics.indices)

        for expectation in parsed.expectations {
            guard let unmatchedIndex = unmatched.firstIndex(where: { index in
                let diagnostic = diagnostics[index]
                return diagnostic.severity == expectation.severity
                    && diagnostic.range.fileID == source.fileID
                    && diagnostic.range.start.line == expectation.line
                    && diagnostic.message.range(of: expectation.messageSubstring) != nil
            }) else {
                issues.append(.init(
                    kind: .missingDiagnostic,
                    message: "Expected \(expectation.severity.rawValue) on line \(expectation.line) containing '{{\(expectation.messageSubstring)}}'",
                    range: expectation.directiveRange
                ))
                continue
            }
            unmatched.remove(at: unmatchedIndex)
        }

        for index in unmatched {
            let diagnostic = diagnostics[index]
            issues.append(.init(
                kind: .unexpectedDiagnostic,
                message: "Unexpected \(diagnostic.severity.rawValue): \(diagnostic.message)",
                range: diagnostic.range
            ))
        }
        return .init(diagnostics: diagnostics, expectations: parsed.expectations, issues: issues)
    }

    private func parseExpectations(_ source: TextSource) -> (expectations: [ExpectedTextDiagnostic], issues: [TextDiagnosticVerificationIssue]) {
        var expectations: [ExpectedTextDiagnostic] = []
        var issues: [TextDiagnosticVerificationIssue] = []
        for (zeroBasedLine, lineSlice) in source.text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let lineNumber = zeroBasedLine + 1
            let line = String(lineSlice)
            var searchStart = line.startIndex
            while let comment = line.range(of: "//", range: searchStart..<line.endIndex) {
                let commentText = line[comment.upperBound...]
                guard let marker = marker(in: commentText) else { break }
                let column = line.distance(from: line.startIndex, to: comment.lowerBound) + 1
                let range = SourceRange(
                    fileID: source.fileID,
                    start: .init(line: lineNumber, column: column),
                    end: .init(line: lineNumber, column: line.count + 1)
                )
                guard let expectation = parse(marker: marker, directiveLine: lineNumber, range: range) else {
                    issues.append(.init(kind: .malformedDirective, message: "Malformed expected diagnostic directive", range: range))
                    break
                }
                expectations.append(expectation)
                searchStart = comment.upperBound
                break // The rest of a line comment is not lexically separable.
            }
        }
        return (expectations, issues)
    }

    private func marker(in comment: Substring) -> Substring? {
        if let range = comment.range(of: "expected-error") { return comment[range.lowerBound...] }
        if let range = comment.range(of: "expected-warning") { return comment[range.lowerBound...] }
        return nil
    }

    private func parse(marker: Substring, directiveLine: Int, range: SourceRange) -> ExpectedTextDiagnostic? {
        let severity: TextDiagnostic.Severity
        let keyword: String
        if marker.hasPrefix("expected-error") { severity = .error; keyword = "expected-error" }
        else if marker.hasPrefix("expected-warning") { severity = .warning; keyword = "expected-warning" }
        else { return nil }

        var remainder = marker.dropFirst(keyword.count)
        var offset = 0
        if remainder.first == "@" {
            remainder = remainder.dropFirst()
            let offsetText = remainder.prefix { $0 == "+" || $0 == "-" || $0.isNumber }
            guard !offsetText.isEmpty, let parsed = Int(offsetText) else { return nil }
            offset = parsed
            remainder = remainder.dropFirst(offsetText.count)
        }
        guard let opening = remainder.range(of: "{{"),
              let closing = remainder.range(of: "}}", range: opening.upperBound..<remainder.endIndex) else { return nil }
        let message = remainder[opening.upperBound..<closing.lowerBound]
        guard !message.isEmpty, directiveLine + offset > 0 else { return nil }
        return .init(severity: severity, line: directiveLine + offset, messageSubstring: String(message), directiveRange: range)
    }
}
