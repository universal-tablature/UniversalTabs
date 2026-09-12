import ArgumentParser
import Foundation
import UniversalTabs

@main
struct UTabDecompileCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "utab-decompile",
        abstract: "Decompile realized UTAB JSON into standalone UTAB composer language source."
    )

    @Argument(help: "Input UTAB JSON path") var input: String
    @Argument(help: "Output .utab path, or '-' for standard output") var output: String = "-"

    mutating func run() throws {
        let result = try UTabComposerDecompiler.decompile(Data(contentsOf: URL(fileURLWithPath: input)))
        for diagnostic in result.diagnostics {
            FileHandle.standardError.write(Data("warning: \(diagnostic)\n".utf8))
        }
        let data = Data(result.source.utf8)
        if output == "-" { FileHandle.standardOutput.write(data) }
        else { try data.write(to: URL(fileURLWithPath: output), options: .atomic) }
    }
}
