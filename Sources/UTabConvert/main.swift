import ArgumentParser
import Foundation
import UTABConversion

@main
struct UTabConvertCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "utab-convert",
        abstract: "Convert between UTAB composer source, UTAB JSON, MEI, LilyPond, MusicXML, and MNX."
    )

    @Argument(help: "Input path, or '-' for standard input") var input: String
    @Argument(help: "Output path, or '-' for standard output") var output: String?
    @Option(name: .long, help: "Destination: utab, utab-json, mei, lilypond, musicxml, or mnx") var to: String
    @Option(name: .long, help: "Override input autodetection") var from: String?

    mutating func run() throws {
        guard let destination = UTabConversionFormat(rawValue: to.lowercased()) else {
            throw ValidationError("unknown destination format '\(to)'")
        }
        let sourceFormat: UTabConversionFormat?
        if let from {
            guard let parsed = UTabConversionFormat(rawValue: from.lowercased()) else { throw ValidationError("unknown input format '\(from)'") }
            sourceFormat = parsed
        } else { sourceFormat = nil }

        let data = input == "-" ? FileHandle.standardInput.readDataToEndOfFile() : try Data(contentsOf: URL(fileURLWithPath: input))
        let result = try UTabConverter().convert(data, from: sourceFormat, to: destination, fileName: input == "-" ? nil : input)
        for diagnostic in result.diagnostics { FileHandle.standardError.write(Data("warning: \(diagnostic)\n".utf8)) }

        if let output, output != "-" {
            try result.data.write(to: URL(fileURLWithPath: output), options: .atomic)
        } else if output == "-" || input == "-" {
            FileHandle.standardOutput.write(result.data)
        } else {
            let inputURL = URL(fileURLWithPath: input)
            var base = inputURL.deletingPathExtension()
            if input.lowercased().hasSuffix(".utab.json") { base.deletePathExtension() }
            var url = base.appendingPathExtension(destination.fileExtension)
            if url.standardizedFileURL == inputURL.standardizedFileURL {
                url = base.appendingPathExtension("converted.\(destination.fileExtension)")
            }
            try result.data.write(to: url, options: .atomic)
            FileHandle.standardError.write(Data("wrote \(url.path)\n".utf8))
        }
    }
}
