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
import UTABInstrumentLibrary
import UTABLowering

#if os(Windows)
import ucrt
#elseif canImport(Glibc)
import Glibc
#else
import Darwin
#endif

@main
struct UTabCompilerCommand {
    struct CompilationFailure: Error {}
    struct Options {
        var input: String?
        var output: String?
        var includePaths: [String] = []
        var formats: Set<UTabTextOutputFormat> = []
        var prettyPrintedJSON = true
        var verifyDiagnostics = false
        var showHelp = false
    }

    enum ArgumentError: Error, CustomStringConvertible {
        case message(String)
        var description: String {
            switch self { case .message(let value): value }
        }
    }

    static func main() {
        do {
            try execute(Array(CommandLine.arguments.dropFirst()))
        } catch let error as ArgumentError {
            writeError("error: \(error)\n\n\(usage)")
            exit(EXIT_FAILURE)
        } catch {
            if !(error is CompilationFailure) { writeError("error: \(error)") }
            exit(EXIT_FAILURE)
        }
    }

    static func execute(_ arguments: [String]) throws {
            var options = try parse(arguments)
            if options.showHelp { print(usage); return }
            guard let inputPath = options.input else { throw ArgumentError.message("missing input .utab file") }
            if options.formats.isEmpty { options.formats = [.uTabJSON] }
            if options.output != nil, options.formats.count != 1 {
                throw ArgumentError.message("-o requires exactly one --emit format")
            }

            let inputURL = URL(fileURLWithPath: inputPath).standardizedFileURL
            let source = TextSource(
                try String(contentsOf: inputURL, encoding: .utf8),
                fileID: stableFileID(for: inputURL)
            )
            let roots = [inputURL.deletingLastPathComponent()] + options.includePaths.map {
                URL(fileURLWithPath: $0).standardizedFileURL
            }
            let provider = LayeredTextModuleProvider([
                FileSystemTextModuleProvider(searchRoots: roots),
                StandardTextModuleProvider(),
            ])
            let result = UTabTextCompiler().compile(
                source,
                modules: provider,
                options: .init(outputs: options.formats, prettyPrintedJSON: options.prettyPrintedJSON)
            )
            for diagnostic in result.diagnostics { writeError(diagnostic.description) }
            if options.verifyDiagnostics {
                let diagnostics = result.diagnostics.compactMap { diagnostic -> TextDiagnostic? in
                    guard let range = diagnostic.range else { return nil }
                    let severity: TextDiagnostic.Severity = diagnostic.severity == .error ? .error : .warning
                    return .init(severity, message: diagnostic.message, range: range)
                }
                let verification = TextDiagnosticVerifier().verify(source, diagnostics: diagnostics)
                for issue in verification.issues { writeError(issue.description) }
                guard verification.succeeded else { throw CompilationFailure() }
                return
            }
            guard result.succeeded else { throw CompilationFailure() }

            for artifact in result.artifacts {
                let outputURL: URL
                if let output = options.output {
                    outputURL = URL(fileURLWithPath: output).standardizedFileURL
                } else {
                    let stem = inputURL.deletingPathExtension().lastPathComponent
                    outputURL = inputURL.deletingLastPathComponent()
                        .appendingPathComponent(stem + "." + artifact.suggestedFileExtension)
                }
                try artifact.data.write(to: outputURL, options: .atomic)
            }
    }

    static func parse(_ arguments: [String]) throws -> Options {
        var options = Options()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--help", "-h": options.showHelp = true
            case "--compact": options.prettyPrintedJSON = false
            case "--verify": options.verifyDiagnostics = true
            case "--emit", "-I", "-o":
                index += 1
                guard index < arguments.count else { throw ArgumentError.message("missing value after \(argument)") }
                try set(value: arguments[index], for: argument, options: &options)
            default:
                if argument.hasPrefix("--emit=") {
                    try addFormat(String(argument.dropFirst("--emit=".count)), to: &options)
                } else if argument.hasPrefix("-I"), argument.count > 2 {
                    options.includePaths.append(String(argument.dropFirst(2)))
                } else if argument.hasPrefix("-") {
                    throw ArgumentError.message("unknown option '\(argument)'")
                } else if options.input == nil {
                    options.input = argument
                } else {
                    throw ArgumentError.message("multiple input files are not supported")
                }
            }
            index += 1
        }
        return options
    }

    static func set(value: String, for option: String, options: inout Options) throws {
        switch option {
        case "--emit": try addFormat(value, to: &options)
        case "-I": options.includePaths.append(value)
        case "-o": options.output = value
        default: break
        }
    }

    static func addFormat(_ value: String, to options: inout Options) throws {
        switch value {
        case "utab-json", "json": options.formats.insert(.uTabJSON)
        case "midi", "mid": options.formats.insert(.midi)
        case "musicxml", "xml": options.formats.insert(.musicXML)
        case "lilypond", "ly": options.formats.insert(.lilyPond)
        case "mei": options.formats.insert(.mei)
        default: throw ArgumentError.message("unknown output format '\(value)'")
        }
    }

    static func writeError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    /// Produces a portable source identity for diagnostics and generated semantic IDs.
    /// Files beneath the working directory retain their relative path; external files
    /// fall back to their name instead of leaking a machine-specific absolute path.
    static func stableFileID(for url: URL) -> String {
        let filePath = url.standardizedFileURL.path
        let workingDirectory = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).standardizedFileURL.path
        let prefix = workingDirectory.hasSuffix("/") ? workingDirectory : workingDirectory + "/"
        if filePath.hasPrefix(prefix) {
            return String(filePath.dropFirst(prefix.count))
        }
        return url.lastPathComponent
    }

    static let usage = """
    Usage: utabc [options] <input.utab>

    Compile Universal Tabs composer source.

      --emit <utab-json|midi|musicxml|lilypond|mei>
                               Emit a format; may be repeated (default: utab-json)
      -o <path>                Output path when exactly one format is emitted
      -I <directory>           Add a module search directory; may be repeated
      --compact                Emit compact rather than pretty-printed JSON
      --verify                 Verify expected diagnostics embedded in source comments
      -h, --help               Show this help

    Without -o, outputs are written beside the input using the format's standard extension.
    """
}
