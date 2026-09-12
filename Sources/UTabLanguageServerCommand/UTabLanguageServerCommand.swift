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
            await UTABStdioLanguageServer.run(configuration: configuration)
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
