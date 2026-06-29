import Foundation
import UniversalTabs

private func usage() {
    print("""
    Usage: utab-midi [--strict] <input.utab.json> <output.mid>

    Converts a draft Universal Tabs document to a Standard MIDI File.
    --strict  Treat conversion diagnostics as errors and do not write output.
    """)
}

var arguments = Array(CommandLine.arguments.dropFirst())
let strict = arguments.contains("--strict")
arguments.removeAll { $0 == "--strict" }
if arguments.contains("--help") || arguments.contains("-h") {
    usage()
    exit(EXIT_SUCCESS)
}
guard arguments.count == 2 else {
    usage()
    exit(EXIT_FAILURE)
}

do {
    let inputURL = URL(fileURLWithPath: arguments[0])
    let outputURL = URL(fileURLWithPath: arguments[1])
    let input = try Data(contentsOf: inputURL)
    let result = try UTabMIDIConverter().convert(data: input)
    for diagnostic in result.diagnostics {
        FileHandle.standardError.write(Data("warning: \(diagnostic)\n".utf8))
    }
    if strict && !result.diagnostics.isEmpty {
        FileHandle.standardError.write(Data("error: strict conversion failed with \(result.diagnostics.count) warning(s)\n".utf8))
        exit(EXIT_FAILURE)
    }
    try result.midi.write(to: outputURL, options: .atomic)
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(EXIT_FAILURE)
}
