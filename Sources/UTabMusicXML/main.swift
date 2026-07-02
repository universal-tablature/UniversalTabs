import Foundation
import UniversalTabs
#if os(Windows)
import ucrt
#elseif canImport(Glibc)
import Glibc
#else
import Darwin
#endif

let args = Array(CommandLine.arguments.dropFirst())
guard args.count == 3, args[0] == "import" || args[0] == "export" else {
    print("Usage: utab-musicxml <import|export> <input> <output>"); exit(1)
}
do {
    let input = try Data(contentsOf: URL(fileURLWithPath: args[1]))
    let result = try args[0] == "import" ? MusicXMLInterchange.importDocument(input) : MusicXMLInterchange.exportDocument(input)
    for warning in result.diagnostics { FileHandle.standardError.write(Data("warning: \(warning)\n".utf8)) }
    try result.data.write(to: URL(fileURLWithPath: args[2]), options: .atomic)
} catch { FileHandle.standardError.write(Data("error: \(error)\n".utf8)); exit(1) }
