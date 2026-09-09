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

public struct SemanticID: RawRepresentable, Sendable, Hashable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        precondition(!rawValue.isEmpty, "A semantic ID cannot be empty")
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }

    public var description: String { rawValue }

    public static func named(_ kind: String, _ name: String) -> Self {
        Self(rawValue: "\(kind):\(name)")
    }

    public static func source(
        kind: String,
        fileID: String,
        line: UInt,
        column: UInt
    ) -> Self {
        Self(rawValue: "\(kind):\(fileID):\(line):\(column)")
    }

    /// Produces a reproducible structural ID without relying on Swift's randomized `Hasher`.
    public static func derived(kind: String, components: [SemanticID]) -> Self {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in ([kind] + components.map(\.rawValue)).joined(separator: "\u{1f}").utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return Self(rawValue: "\(kind):\(String(hash, radix: 16))")
    }
}

public struct SourcePosition: Sendable, Hashable {
    public let line: Int
    public let column: Int

    public init(line: Int, column: Int) {
        precondition(line > 0 && column > 0, "Source positions are one-based")
        self.line = line
        self.column = column
    }
}

public struct SourceRange: Sendable, Hashable {
    public let fileID: String
    public let start: SourcePosition
    public let end: SourcePosition?

    public init(fileID: String, start: SourcePosition, end: SourcePosition? = nil) {
        self.fileID = fileID
        self.start = start
        self.end = end
    }

    public static func point(fileID: String, line: UInt, column: UInt) -> Self {
        Self(fileID: fileID, start: .init(line: Int(line), column: Int(column)))
    }
}

public indirect enum MetadataValue: Sendable, Hashable {
    case string(String)
    case integer(Int)
    case decimal(Double)
    case boolean(Bool)
    case list([MetadataValue])
    case object([String: MetadataValue])
    case reference(SemanticID)
}

public struct SemanticAnnotations: Sendable, Hashable {
    public let metadata: [String: MetadataValue]
    public let source: SourceRange?

    public init(metadata: [String: MetadataValue] = [:], source: SourceRange? = nil) {
        self.metadata = metadata
        self.source = source
    }
}
