import ArgumentParser
import Foundation
import UniversalTabs

@main
struct UTabLilyPondCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "utab-lilypond", abstract: "Export UTAB JSON as LilyPond source.")

    @Argument(help: "Input .utab.json file") var input: String
    @Argument(help: "Output .ly file") var output: String
    @Flag(help: "Run LilyPond to produce a PDF after exporting") var render = false
    @Flag(help: "Open the rendered PDF with the default viewer; implies --render") var open = false

    mutating func run() throws {
        let result = try LilyPondInterchange.exportDocument(Data(contentsOf: URL(fileURLWithPath: input)))
        for diagnostic in result.diagnostics { FileHandle.standardError.write(Data("warning: \(diagnostic)\n".utf8)) }
        let outputURL = URL(fileURLWithPath: output).standardizedFileURL
        try result.data.write(to: outputURL, options: .atomic)
        if render || open {
            let pdfURL = try renderPDF(source: outputURL)
            if open { try openPDF(pdfURL) }
        }
    }

    private func renderPDF(source: URL) throws -> URL {
        guard let executable = findExecutable(named: "lilypond") else {
            throw ValidationError("LilyPond was not found in PATH or a standard installation location")
        }
        let baseURL = source.deletingPathExtension()
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--pdf", "--output=\(baseURL.path)", source.path]
        process.currentDirectoryURL = source.deletingLastPathComponent()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ValidationError("LilyPond exited with status \(process.terminationStatus)")
        }
        let pdfURL = baseURL.appendingPathExtension("pdf")
        guard FileManager.default.fileExists(atPath: pdfURL.path) else {
            throw ValidationError("LilyPond completed without producing \(pdfURL.path)")
        }
        return pdfURL
    }

    private func findExecutable(named name: String) -> URL? {
        #if os(Windows)
        let separator: Character = ";"
        let executableName = name + ".exe"
        #else
        let separator: Character = ":"
        let executableName = name
        #endif
        let pathCandidates = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: separator)
            .map { URL(fileURLWithPath: String($0), isDirectory: true).appendingPathComponent(executableName) } ?? []
        #if os(macOS)
        let standardCandidates = [
            URL(fileURLWithPath: "/opt/homebrew/bin/lilypond"),
            URL(fileURLWithPath: "/usr/local/bin/lilypond"),
            URL(fileURLWithPath: "/Applications/LilyPond.app/Contents/Resources/bin/lilypond"),
        ]
        #else
        let standardCandidates: [URL] = []
        #endif
        return (pathCandidates + standardCandidates).first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }

    private func openPDF(_ pdfURL: URL) throws {
        let process = Process()
        #if os(macOS)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [pdfURL.path]
        #elseif os(Linux)
        guard let opener = findExecutable(named: "xdg-open") else {
            throw ValidationError("xdg-open was not found in PATH")
        }
        process.executableURL = opener
        process.arguments = [pdfURL.path]
        #elseif os(Windows)
        process.executableURL = URL(fileURLWithPath: "C:\\Windows\\System32\\cmd.exe")
        process.arguments = ["/c", "start", "", pdfURL.path]
        #else
        throw ValidationError("Opening PDFs is not supported on this platform")
        #endif
        try process.run()
    }
}
