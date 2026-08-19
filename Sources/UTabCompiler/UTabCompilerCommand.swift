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
    struct Options {
        var input: String?
        var output: String?
        var includePaths: [String] = []
        var formats: Set<UTabTextOutputFormat> = []
        var prettyPrintedJSON = true
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
            var options = try parse(Array(CommandLine.arguments.dropFirst()))
            if options.showHelp { print(usage); return }
            guard let inputPath = options.input else { throw ArgumentError.message("missing input .utab file") }
            if options.formats.isEmpty { options.formats = [.uTabJSON] }
            if options.output != nil, options.formats.count != 1 {
                throw ArgumentError.message("-o requires exactly one --emit format")
            }

            let inputURL = URL(fileURLWithPath: inputPath).standardizedFileURL
            let source = TextSource(
                try String(contentsOf: inputURL, encoding: .utf8),
                fileID: inputURL.path
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
            guard result.succeeded else { exit(EXIT_FAILURE) }

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
        } catch let error as ArgumentError {
            writeError("error: \(error)\n\n\(usage)")
            exit(EXIT_FAILURE)
        } catch {
            writeError("error: \(error)")
            exit(EXIT_FAILURE)
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
        default: throw ArgumentError.message("unknown output format '\(value)'")
        }
    }

    static func writeError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    static let usage = """
    Usage: utabc [options] <input.utab>

    Compile Universal Tabs composer source.

      --emit <utab-json|midi>  Emit a format; may be repeated (default: utab-json)
      -o <path>                Output path when exactly one format is emitted
      -I <directory>           Add a module search directory; may be repeated
      --compact                Emit compact rather than pretty-printed JSON
      -h, --help               Show this help

    Without -o, outputs are written beside the input as <name>.utab.json and <name>.mid.
    """
}
