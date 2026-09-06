import Foundation
import ZIPFoundation

#if os(Windows)
import ucrt
#elseif canImport(Glibc)
import Glibc
#else
import Darwin
#endif

private struct IndexEntry: Codable {
    let sourcePath: String
    let mxlPath: String
    let xmlEntry: String
    let evidence: [String]
    let compressedBytes: UInt64
    let uncompressedBytes: UInt64
}

private func usage() {
    print("Usage: utab-pdmx-index [--subset NAME] [--limit COUNT] <PDMX directory> <output.jsonl>")
}

var subset = "all_valid"
var limit: Int?
let rawArguments = Array(CommandLine.arguments.dropFirst())
var arguments: [String] = []
var argumentIndex = 0
while argumentIndex < rawArguments.count {
    if rawArguments[argumentIndex] == "--subset", argumentIndex + 1 < rawArguments.count {
        subset = rawArguments[argumentIndex + 1]; argumentIndex += 2
    } else if rawArguments[argumentIndex] == "--limit", argumentIndex + 1 < rawArguments.count {
        limit = Int(rawArguments[argumentIndex + 1]); argumentIndex += 2
    } else {
        arguments.append(rawArguments[argumentIndex]); argumentIndex += 1
    }
}
guard arguments.count == 2 else { usage(); exit(EXIT_FAILURE) }

let root = URL(fileURLWithPath: arguments[0], isDirectory: true)
let output = URL(fileURLWithPath: arguments[1])
let listURL = root.appendingPathComponent("subset_paths/\(subset).txt")

do {
    let contents = try String(contentsOf: listURL, encoding: .utf8)
    let paths = contents.split(whereSeparator: \Character.isNewline).prefix(limit ?? .max)
    FileManager.default.createFile(atPath: output.path, contents: nil)
    let handle = try FileHandle(forWritingTo: output)
    defer { handle.closeFile() }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    var scanned = 0
    var matched = 0
    var failures = 0

    for sourceSubstring in paths {
        let sourcePath = String(sourceSubstring)
        let relative = sourcePath.hasPrefix("./data/") ? String(sourcePath.dropFirst(7)) : sourcePath
        let stem = relative.hasSuffix(".json") ? String(relative.dropLast(5)) : relative
        let mxlRelative = "mxl/\(stem).mxl"
        let mxlURL = root.appendingPathComponent(mxlRelative)
        scanned += 1
        do {
            guard let archive = Archive(url: mxlURL, accessMode: .read) else {
                failures += 1; continue
            }
            guard let xmlEntry = archive.first(where: { $0.type == .file && $0.path.lowercased().hasSuffix(".xml") && !$0.path.hasPrefix("META-INF/") }) else {
                failures += 1; continue
            }
            var xml = Data()
            _ = try archive.extract(xmlEntry, consumer: { xml.append($0) })
            guard let text = String(data: xml, encoding: .utf8) else { failures += 1; continue }
            var evidence: [String] = []
            if text.range(of: "<staff-type>tablature</staff-type>", options: [.caseInsensitive]) != nil { evidence.append("staff-type") }
            if text.range(of: "<sign>TAB</sign>", options: [.caseInsensitive]) != nil { evidence.append("tab-clef") }
            if text.range(of: "<technical", options: [.caseInsensitive]) != nil,
               text.range(of: "<string", options: [.caseInsensitive]) != nil,
               text.range(of: "<fret", options: [.caseInsensitive]) != nil { evidence.append("technical-string-fret") }
            guard !evidence.isEmpty else { continue }
            let archiveBytes = try mxlURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            let entry = IndexEntry(sourcePath: sourcePath, mxlPath: mxlRelative, xmlEntry: xmlEntry.path, evidence: evidence, compressedBytes: UInt64(archiveBytes), uncompressedBytes: UInt64(xml.count))
            var line = try encoder.encode(entry); line.append(0x0A); handle.write(line)
            matched += 1
        } catch {
            failures += 1
        }
        if scanned % 1000 == 0 { FileHandle.standardError.write(Data("scanned \(scanned), matched \(matched), failures \(failures)\n".utf8)) }
    }
    FileHandle.standardError.write(Data("complete: scanned \(scanned), matched \(matched), failures \(failures)\n".utf8))
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8)); exit(EXIT_FAILURE)
}
