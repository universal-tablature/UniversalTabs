import ArgumentParser
import Foundation
import UniversalTabs

@main
struct UTabMEICommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "utab-mei", abstract: "Import or export MEI 5.1 Common Music Notation.")
    @Argument(help: "Operation: import or export") var operation: String
    @Argument(help: "Input path") var input: String
    @Argument(help: "Output path") var output: String

    mutating func run() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: input))
        let result: MusicXMLResult
        switch operation {
        case "import": result = try MEIInterchange.importDocument(data)
        case "export": result = try MEIInterchange.exportDocument(data)
        default: throw ValidationError("operation must be 'import' or 'export'")
        }
        for item in result.diagnostics { FileHandle.standardError.write(Data("warning: \(item)\n".utf8)) }
        try result.data.write(to: URL(fileURLWithPath: output), options: .atomic)
    }
}
