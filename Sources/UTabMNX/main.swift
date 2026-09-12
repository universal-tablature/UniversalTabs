import ArgumentParser
import Foundation
import UniversalTabs

@main
struct UTabMNXCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "utab-mnx",
        abstract: "Import or export the experimental MNX 1.0 draft (not a final MNX specification)."
    )

    @Argument(help: "Operation: import or export") var operation: String
    @Argument(help: "Input path (.mnx JSON for import, UTAB JSON for export)") var input: String
    @Argument(help: "Output path") var output: String

    mutating func run() throws {
        FileHandle.standardError.write(Data("warning: \(MNXDraft1Interchange.notice)\n".utf8))
        let data = try Data(contentsOf: URL(fileURLWithPath: input))
        let result: MusicXMLResult
        switch operation {
        case "import": result = try MNXDraft1Interchange.importDocument(data)
        case "export": result = try MNXDraft1Interchange.exportDocument(data)
        default: throw ValidationError("operation must be 'import' or 'export'")
        }
        for item in result.diagnostics where item != MNXDraft1Interchange.notice {
            FileHandle.standardError.write(Data("warning: \(item)\n".utf8))
        }
        try result.data.write(to: URL(fileURLWithPath: output), options: .atomic)
    }
}
