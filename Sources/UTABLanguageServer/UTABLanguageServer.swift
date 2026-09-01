import Foundation
import UTABComposerCore
import UTABComposerText
import UTABInstrumentLibrary
import UTABLowering

public struct UTABLanguageServerConfiguration: Sendable, Equatable {
    public var moduleSearchPaths: [URL]

    public init(moduleSearchPaths: [URL] = []) {
        self.moduleSearchPaths = moduleSearchPaths
    }
}

public struct UTABUnpositionedDiagnostic: Sendable, Equatable {
    public enum Severity: String, Sendable {
        case warning
        case error
    }

    public let severity: Severity
    public let stage: String
    public let path: String?
    public let message: String
}

public struct UTABUnpositionedDiagnosticsUpdate: Sendable, Equatable {
    public let uri: String
    public let version: Int?
    public let diagnostics: [UTABUnpositionedDiagnostic]
}

public actor UTABLanguageServer {
    private struct Document: Sendable {
        var text: String
        var version: Int
        var languageID: String
    }

    private let configuration: UTABLanguageServerConfiguration
    private var documents: [String: Document] = [:]
    private var shutdownRequested = false
    private var unpositionedDiagnosticsHandler: (@Sendable (UTABUnpositionedDiagnosticsUpdate) -> Void)?
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    public init(configuration: UTABLanguageServerConfiguration = .init()) {
        self.configuration = configuration
    }

    /// Handles one JSON-RPC message and returns zero or more JSON-RPC messages to send.
    public func handle(_ data: Data) async -> [Data] {
        do {
            let value = try decoder.decode(JSONValue.self, from: data)
            guard let message = value.objectValue,
                  message["jsonrpc"]?.stringValue == "2.0",
                  let method = message["method"]?.stringValue else {
                return [encode(error: -32600, message: "Invalid Request", id: messageID(from: value))]
            }

            let id = message["id"]
            let params = message["params"]?.objectValue ?? [:]

            switch method {
            case "initialize":
                return id.map { [encode(result: initializeResult, id: $0)] } ?? []
            case "initialized":
                return []
            case "shutdown":
                shutdownRequested = true
                return id.map { [encode(result: .null, id: $0)] } ?? []
            case "exit":
                documents.removeAll()
                return []
            case "textDocument/didOpen":
                return await didOpen(params)
            case "textDocument/didChange":
                return await didChange(params)
            case "textDocument/didClose":
                return didClose(params)
            default:
                guard let id else { return [] }
                return [encode(error: -32601, message: "Method not found: \(method)", id: id)]
            }
        } catch {
            return [encode(error: -32700, message: "Parse error: \(error)", id: .null)]
        }
    }

    public var isShutdownRequested: Bool {
        shutdownRequested
    }

    public func setUnpositionedDiagnosticsHandler(
        _ handler: (@Sendable (UTABUnpositionedDiagnosticsUpdate) -> Void)?
    ) {
        unpositionedDiagnosticsHandler = handler
    }

    private var initializeResult: JSONValue {
        .object([
            "capabilities": .object([
                "textDocumentSync": .object([
                    "openClose": .bool(true),
                    "change": .number(1),
                ]),
            ]),
            "serverInfo": .object([
                "name": .string("UTAB Language Server"),
                "version": .string("0.1.0"),
            ]),
        ])
    }

    private func didOpen(_ params: [String: JSONValue]) async -> [Data] {
        guard let item = params["textDocument"]?.objectValue,
              let uri = item["uri"]?.stringValue,
              let text = item["text"]?.stringValue else { return [] }

        let version = item["version"]?.intValue ?? 0
        let languageID = item["languageId"]?.stringValue ?? "utab"
        documents[uri] = Document(text: text, version: version, languageID: languageID)
        return await diagnosticsNotification(uri: uri, version: version)
    }

    private func didChange(_ params: [String: JSONValue]) async -> [Data] {
        guard let item = params["textDocument"]?.objectValue,
              let uri = item["uri"]?.stringValue,
              let changes = params["contentChanges"]?.arrayValue,
              let text = changes.last?.objectValue?["text"]?.stringValue,
              var document = documents[uri] else { return [] }

        let version = item["version"]?.intValue ?? document.version + 1
        document.text = text
        document.version = version
        documents[uri] = document
        return await diagnosticsNotification(uri: uri, version: version)
    }

    private func didClose(_ params: [String: JSONValue]) -> [Data] {
        guard let item = params["textDocument"]?.objectValue,
              let uri = item["uri"]?.stringValue else { return [] }
        documents[uri] = nil
        reportUnpositioned(uri: uri, version: nil, diagnostics: [])
        return [publishDiagnostics(uri: uri, version: nil, diagnostics: [])]
    }

    private func diagnosticsNotification(uri: String, version: Int) async -> [Data] {
        guard let document = documents[uri], document.version == version else { return [] }

        // JSON documents continue to use Monaco's JSON worker until UTAB JSON schema support lands.
        guard document.languageID != "json" else {
            reportUnpositioned(uri: uri, version: version, diagnostics: [])
            return [publishDiagnostics(uri: uri, version: version, diagnostics: [])]
        }

        let text = document.text
        let searchPaths = configuration.moduleSearchPaths
        let diagnostics = await Task.detached(priority: .userInitiated) {
            let provider = LayeredTextModuleProvider([
                FileSystemTextModuleProvider(searchRoots: searchPaths),
                StandardTextModuleProvider(),
            ])
            return UTabTextCompiler()
                .compile(TextSource(text, fileID: uri), modules: provider)
                .diagnostics
        }.value

        guard documents[uri]?.version == version else { return [] }
        reportUnpositioned(
            uri: uri,
            version: version,
            diagnostics: diagnostics.filter { $0.range == nil }
        )
        let values = diagnostics.compactMap { diagnostic -> JSONValue? in
            guard let sourceRange = diagnostic.range, sourceRange.fileID == uri else { return nil }
            return .object([
                "range": lspRange(sourceRange, in: text),
                "severity": .number(diagnostic.severity == .error ? 1 : 2),
                "source": .string("utabc"),
                "code": .string(diagnostic.stage.rawValue),
                "message": .string(diagnostic.message),
            ])
        }
        return [publishDiagnostics(uri: uri, version: version, diagnostics: values)]
    }

    private func reportUnpositioned(
        uri: String,
        version: Int?,
        diagnostics: [UTabTextCompilerDiagnostic]
    ) {
        let values = diagnostics.map {
            UTABUnpositionedDiagnostic(
                severity: $0.severity == .error ? .error : .warning,
                stage: $0.stage.rawValue,
                path: $0.path,
                message: $0.message
            )
        }
        unpositionedDiagnosticsHandler?(.init(uri: uri, version: version, diagnostics: values))
    }

    private func publishDiagnostics(uri: String, version: Int?, diagnostics: [JSONValue]) -> Data {
        var params: [String: JSONValue] = [
            "uri": .string(uri),
            "diagnostics": .array(diagnostics),
        ]
        if let version { params["version"] = .number(Double(version)) }
        return encode(.object([
            "jsonrpc": .string("2.0"),
            "method": .string("textDocument/publishDiagnostics"),
            "params": .object(params),
        ]))
    }

    private func encode(result: JSONValue, id: JSONValue) -> Data {
        encode(.object([
            "jsonrpc": .string("2.0"),
            "id": id,
            "result": result,
        ]))
    }

    private func encode(error code: Int, message: String, id: JSONValue?) -> Data {
        encode(.object([
            "jsonrpc": .string("2.0"),
            "id": id ?? .null,
            "error": .object([
                "code": .number(Double(code)),
                "message": .string(message),
            ]),
        ]))
    }

    private func encode(_ value: JSONValue) -> Data {
        (try? encoder.encode(value)) ?? Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal error"}}"#.utf8)
    }

    private func messageID(from value: JSONValue) -> JSONValue? {
        value.objectValue?["id"]
    }
}

private func lspRange(_ range: SourceRange, in text: String) -> JSONValue {
    .object([
        "start": lspPosition(line: range.start.line, column: range.start.column, in: text),
        "end": lspPosition(
            line: (range.end ?? range.start).line,
            column: (range.end ?? range.start).column,
            in: text
        ),
    ])
}

private func lspPosition(line: Int, column: Int, in text: String) -> JSONValue {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    let lineIndex = max(0, min(line - 1, max(0, lines.count - 1)))
    let sourceLine = lines.isEmpty ? Substring() : lines[lineIndex]
    let characterIndex = max(0, column - 1)
    let end = sourceLine.index(
        sourceLine.startIndex,
        offsetBy: min(characterIndex, sourceLine.count),
        limitedBy: sourceLine.endIndex
    ) ?? sourceLine.endIndex
    let utf16Column = sourceLine[..<end].utf16.count
    return .object([
        "line": .number(Double(lineIndex)),
        "character": .number(Double(utf16Column)),
    ])
}
