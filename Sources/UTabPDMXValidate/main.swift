// Copyright 2026 Mattias Holm
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

import Foundation
import UniversalTabs
import ZIPFoundation

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

private struct ValidationRecord: Encodable {
    let sourcePath: String
    let mxlPath: String
    let originalBytes: Int
    let exportedBytes: Int?
    let firstEventCount: Int?
    let roundTripEventCount: Int?
    let importDiagnostics: [String]
    let exportDiagnostics: [String]
    let roundTripDiagnostics: [String]
    let validationErrors: [String]
    let error: String?
}

private func usage() {
    print("Usage: utab-pdmx-validate [--subset NAME] [--limit COUNT] <PDMX directory> <report.jsonl>")
}

var subset = "all_valid"
var limit: Int?
let rawArguments = Array(CommandLine.arguments.dropFirst())
var arguments: [String] = []
var argumentIndex = 0
while argumentIndex < rawArguments.count {
    if rawArguments[argumentIndex] == "--subset", argumentIndex + 1 < rawArguments.count {
        subset = rawArguments[argumentIndex + 1]
        argumentIndex += 2
    } else if rawArguments[argumentIndex] == "--limit", argumentIndex + 1 < rawArguments.count {
        limit = Int(rawArguments[argumentIndex + 1])
        argumentIndex += 2
    } else {
        arguments.append(rawArguments[argumentIndex])
        argumentIndex += 1
    }
}
guard arguments.count == 2 else { usage(); exit(EXIT_FAILURE) }

let datasetURL = URL(fileURLWithPath: arguments[0], isDirectory: true)
let reportURL = URL(fileURLWithPath: arguments[1])
let subsetURL = datasetURL.appendingPathComponent("subset_paths/\(subset).txt")

private func eventCount(_ document: UTabDocument) -> Int {
    document.tracks.reduce(0) { total, track in
        total + (track.events?.count ?? 0) + (track.parts?.reduce(0) { $0 + $1.events.count } ?? 0)
    }
}

do {
    let paths = try String(contentsOf: subsetURL, encoding: .utf8)
        .split(whereSeparator: \Character.isNewline)
        .prefix(limit ?? .max)
    FileManager.default.createFile(atPath: reportURL.path, contents: nil)
    let report = try FileHandle(forWritingTo: reportURL)
    defer { report.closeFile() }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    var passed = 0
    var failed = 0

    for (recordIndex, sourceSubstring) in paths.enumerated() {
        let sourcePath = String(sourceSubstring)
        let relative = sourcePath.hasPrefix("./data/") ? String(sourcePath.dropFirst(7)) : sourcePath
        let stem = relative.hasSuffix(".json") ? String(relative.dropLast(5)) : relative
        let mxlPath = "mxl/\(stem).mxl"
        let archiveURL = datasetURL.appendingPathComponent(mxlPath)
        var record: ValidationRecord
        do {
            let archive = try Archive(url: archiveURL, accessMode: .read)
            guard let archiveEntry = archive.first(where: {
                      $0.type == .file && $0.path.lowercased().hasSuffix(".xml") && !$0.path.hasPrefix("META-INF/")
                  }) else {
                throw MusicXMLError.malformed("could not find score XML in \(mxlPath)")
            }
            var originalXML = Data()
            _ = try archive.extract(archiveEntry) { originalXML.append($0) }
            let imported = try MusicXMLInterchange.importDocument(originalXML)
            let firstDocument = try JSONDecoder().decode(UTabDocument.self, from: imported.data)
            let firstValidation = UTabValidator().validate(firstDocument).map(\.description)
            let exported = try MusicXMLInterchange.exportDocument(imported.data)
            let roundTrip = try MusicXMLInterchange.importDocument(exported.data)
            let roundTripDocument = try JSONDecoder().decode(UTabDocument.self, from: roundTrip.data)
            let roundTripValidation = UTabValidator().validate(roundTripDocument).map(\.description)
            let validationErrors = firstValidation + roundTripValidation
            record = .init(
                sourcePath: sourcePath,
                mxlPath: mxlPath,
                originalBytes: originalXML.count,
                exportedBytes: exported.data.count,
                firstEventCount: eventCount(firstDocument),
                roundTripEventCount: eventCount(roundTripDocument),
                importDiagnostics: imported.diagnostics,
                exportDiagnostics: exported.diagnostics,
                roundTripDiagnostics: roundTrip.diagnostics,
                validationErrors: validationErrors,
                error: nil
            )
            passed += 1
        } catch {
            record = .init(sourcePath: sourcePath, mxlPath: mxlPath, originalBytes: 0, exportedBytes: nil, firstEventCount: nil, roundTripEventCount: nil, importDiagnostics: [], exportDiagnostics: [], roundTripDiagnostics: [], validationErrors: [], error: String(describing: error))
            failed += 1
        }
        var encoded = try encoder.encode(record)
        encoded.append(0x0A)
        report.write(encoded)
        if (recordIndex + 1) % 100 == 0 {
            FileHandle.standardError.write(Data("validated \(recordIndex + 1): passed \(passed), failed \(failed)\n".utf8))
        }
    }
    FileHandle.standardError.write(Data("complete: passed \(passed), failed \(failed), report \(reportURL.path)\n".utf8))
    if failed > 0 { exit(EXIT_FAILURE) }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(EXIT_FAILURE)
}
