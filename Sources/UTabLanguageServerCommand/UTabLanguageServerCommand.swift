import Foundation
import UTABLanguageServer

@main
struct UTabLanguageServerCommand {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments.contains("--help") || arguments.contains("-h") {
                print(usage)
                return
            }
            let configuration = try parse(arguments)
            let server = UTABLanguageServer(configuration: configuration)
            var reader = StdioMessageReader()

            while let message = try reader.nextMessage() {
                let responses = await server.handle(message)
                for response in responses {
                    try write(response)
                }
            }
        } catch {
            FileHandle.standardError.write(Data("utab-lsp: \(error)\n".utf8))
            Foundation.exit(EXIT_FAILURE)
        }
    }

    private static func parse(_ arguments: [String]) throws -> UTABLanguageServerConfiguration {
        var searchPaths: [URL] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "-I" || argument == "--module-search-path" {
                index += 1
                guard index < arguments.count else {
                    throw CommandError("missing path after \(argument)")
                }
                searchPaths.append(URL(fileURLWithPath: arguments[index]).standardizedFileURL)
            } else if argument.hasPrefix("-I"), argument.count > 2 {
                searchPaths.append(
                    URL(fileURLWithPath: String(argument.dropFirst(2))).standardizedFileURL
                )
            } else {
                throw CommandError("unknown option '\(argument)'")
            }
            index += 1
        }
        return UTABLanguageServerConfiguration(moduleSearchPaths: searchPaths)
    }

    private static func write(_ message: Data) throws {
        var framed = Data("Content-Length: \(message.count)\r\n\r\n".utf8)
        framed.append(message)
        try FileHandle.standardOutput.write(contentsOf: framed)
    }

    private static let usage = """
    Usage: utab-lsp [options]

    Run the Universal Tabs language server over LSP/JSON-RPC on stdio.

      -I, --module-search-path <directory>  Add a module search directory; may be repeated
      -h, --help                            Show this help
    """
}

private struct CommandError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

private struct StdioMessageReader {
    private var buffer = Data()
    private let separator = Data("\r\n\r\n".utf8)

    mutating func nextMessage() throws -> Data? {
        while true {
            if let message = extractMessage() {
                return message
            }
            guard let chunk = try FileHandle.standardInput.read(upToCount: 16_384),
                  !chunk.isEmpty else {
                return nil
            }
            buffer.append(chunk)
        }
    }

    private mutating func extractMessage() -> Data? {
        guard let headerRange = buffer.range(of: separator) else { return nil }
        let headerData = buffer.subdata(in: buffer.startIndex..<headerRange.lowerBound)
        guard let headers = String(data: headerData, encoding: .utf8),
              let contentLength = headers
                .split(separator: "\r\n")
                .first(where: { $0.lowercased().hasPrefix("content-length:") })
                .flatMap({ Int($0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)) })
        else { return nil }

        let bodyStart = headerRange.upperBound
        let bodyEnd = bodyStart + contentLength
        guard bodyEnd <= buffer.endIndex else { return nil }
        let message = buffer.subdata(in: bodyStart..<bodyEnd)
        buffer.removeSubrange(buffer.startIndex..<bodyEnd)
        return message
    }
}
