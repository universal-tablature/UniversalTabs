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
import UniversalTabs
import ZIPFoundation

#if os(Windows)
import ucrt
#elseif canImport(Glibc)
import Glibc
#else
import Darwin
#endif

private struct TabIndexEntry: Decodable {
    let sourcePath: String
    let mxlPath: String
    let xmlEntry: String
    let evidence: [String]
}

private struct ImportRecord: Encodable {
    let sourcePath: String
    let mxlPath: String
    let xmlEntry: String
    let outputPath: String?
    let evidence: [String]
    let diagnostics: [String]
    let error: String?
}

private func usage() {
    print("Usage: utab-pdmx-import <index.jsonl> <PDMX directory> <output directory>")
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 3 else { usage(); exit(EXIT_FAILURE) }
let indexURL = URL(fileURLWithPath: arguments[0])
let datasetURL = URL(fileURLWithPath: arguments[1], isDirectory: true)
let outputURL = URL(fileURLWithPath: arguments[2], isDirectory: true)
let manifestURL = outputURL.appendingPathComponent("manifest.jsonl")

do {
    try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: manifestURL.path, contents: nil)
    let manifest = try FileHandle(forWritingTo: manifestURL)
    defer { manifest.closeFile() }
    let decoder = JSONDecoder()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let lines = try String(contentsOf: indexURL, encoding: .utf8).split(whereSeparator: \Character.isNewline)
    var imported = 0
    var failed = 0

    for line in lines {
        let entry = try decoder.decode(TabIndexEntry.self, from: Data(line.utf8))
        var record: ImportRecord
        do {
            let archiveURL = datasetURL.appendingPathComponent(entry.mxlPath)
            guard let archive = Archive(url: archiveURL, accessMode: .read) else {
                throw MusicXMLError.malformed("archive '\(entry.mxlPath)' could not be opened")
            }
            guard let archiveEntry = archive[entry.xmlEntry] else {
                throw MusicXMLError.malformed("archive entry '\(entry.xmlEntry)' is missing")
            }
            var xml = Data()
            _ = try archive.extract(archiveEntry, consumer: { xml.append($0) })
            let result = try MusicXMLInterchange.importDocument(xml)
            let document = try JSONDecoder().decode(UTabDocument.self, from: result.data)
            let validation = UTabValidator().validate(document).map(\.description)
            let stem = URL(fileURLWithPath: entry.mxlPath).deletingPathExtension().lastPathComponent
            let fileName = "\(stem).utab.json"
            let destination = outputURL.appendingPathComponent(fileName)
            try result.data.write(to: destination, options: .atomic)
            record = ImportRecord(sourcePath: entry.sourcePath, mxlPath: entry.mxlPath, xmlEntry: entry.xmlEntry, outputPath: fileName, evidence: entry.evidence, diagnostics: result.diagnostics + validation, error: nil)
            imported += 1
        } catch {
            record = ImportRecord(sourcePath: entry.sourcePath, mxlPath: entry.mxlPath, xmlEntry: entry.xmlEntry, outputPath: nil, evidence: entry.evidence, diagnostics: [], error: String(describing: error))
            failed += 1
        }
        var encoded = try encoder.encode(record)
        encoded.append(0x0A)
        manifest.write(encoded)
    }
    FileHandle.standardError.write(Data("complete: imported \(imported), failed \(failed)\n".utf8))
    if failed > 0 { exit(EXIT_FAILURE) }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(EXIT_FAILURE)
}
