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

#if os(Windows)
import ucrt
#elseif canImport(Glibc)
import Glibc
#else
import Darwin
#endif

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
