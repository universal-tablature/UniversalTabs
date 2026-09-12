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
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket
import Testing
@testable import UTABLanguageServer

@Suite("UTAB language server")
struct UTABLanguageServerTests {
    @Test("Initialize advertises full document synchronization")
    func initialize() async throws {
        let server = UTABLanguageServer()
        let responses = await server.handle(message(method: "initialize", id: 1, params: [:]))

        #expect(responses.count == 1)
        let response = try decode(responses[0])
        let capabilities = response.objectValue?["result"]?.objectValue?["capabilities"]?.objectValue
        #expect(capabilities?["textDocumentSync"]?.objectValue?["change"]?.intValue == 1)
    }

    @Test("Opening native UTAB publishes compiler diagnostics")
    func nativeDiagnostics() async throws {
        let server = UTABLanguageServer()
        let uri = "file:///main.utab"
        let responses = await server.handle(message(
            method: "textDocument/didOpen",
            params: [
                "textDocument": .object([
                    "uri": .string(uri),
                    "languageId": .string("utab"),
                    "version": .number(1),
                    "text": .string("title \"😀\" !"),
                ]),
            ]
        ))

        #expect(responses.count == 1)
        let notification = try decode(responses[0]).objectValue
        #expect(notification?["method"]?.stringValue == "textDocument/publishDiagnostics")
        let diagnostics = notification?["params"]?.objectValue?["diagnostics"]?.arrayValue ?? []
        let unexpectedCharacter = diagnostics.first {
            $0.objectValue?["message"]?.stringValue?.contains("Unexpected character") == true
        }
        #expect(unexpectedCharacter != nil)

        // LSP columns are UTF-16 based; the emoji occupies two code units.
        let start = unexpectedCharacter?.objectValue?["range"]?.objectValue?["start"]?.objectValue
        #expect(start?["line"]?.intValue == 0)
        #expect(start?["character"]?.intValue == 11)
    }

    @Test("Full document changes replace diagnostics")
    func documentChanges() async throws {
        let server = UTABLanguageServer()
        let uri = "file:///main.utab"
        _ = await server.handle(message(
            method: "textDocument/didOpen",
            params: [
                "textDocument": .object([
                    "uri": .string(uri),
                    "languageId": .string("utab"),
                    "version": .number(1),
                    "text": .string("!"),
                ]),
            ]
        ))

        let responses = await server.handle(message(
            method: "textDocument/didChange",
            params: [
                "textDocument": .object([
                    "uri": .string(uri),
                    "version": .number(2),
                ]),
                "contentChanges": .array([
                    .object(["text": .string("")]),
                ]),
            ]
        ))

        let diagnostics = try decode(responses[0])
            .objectValue?["params"]?.objectValue?["diagnostics"]?.arrayValue ?? []
        #expect(!diagnostics.contains {
            $0.objectValue?["message"]?.stringValue?.contains("Unexpected character") == true
        })
    }

    @Test("JSON documents remain owned by Monaco's JSON worker")
    func jsonDocuments() async throws {
        let server = UTABLanguageServer()
        let responses = await server.handle(message(
            method: "textDocument/didOpen",
            params: [
                "textDocument": .object([
                    "uri": .string("file:///main.utab.json"),
                    "languageId": .string("json"),
                    "version": .number(1),
                    "text": .string("{"),
                ]),
            ]
        ))

        let diagnostics = try decode(responses[0])
            .objectValue?["params"]?.objectValue?["diagnostics"]?.arrayValue
        #expect(diagnostics?.isEmpty == true)
    }

    @Test("Diagnostics retain their source line")
    func diagnosticLocation() async throws {
        let server = UTABLanguageServer()
        let uri = "file:///main.utab"
        let source = """
        module composition.test

        title "Test"
        !
        """
        let responses = await server.handle(message(
            method: "textDocument/didOpen",
            params: [
                "textDocument": .object([
                    "uri": .string(uri),
                    "languageId": .string("utab"),
                    "version": .number(1),
                    "text": .string(source),
                ]),
            ]
        ))

        let diagnostics = try decode(responses[0])
            .objectValue?["params"]?.objectValue?["diagnostics"]?.arrayValue ?? []
        let unexpectedCharacter = diagnostics.first {
            $0.objectValue?["message"]?.stringValue?.contains("Unexpected character") == true
        }
        let start = unexpectedCharacter?.objectValue?["range"]?.objectValue?["start"]?.objectValue
        #expect(start?["line"]?.intValue == 3)
        #expect(start?["character"]?.intValue == 0)
    }

    @Test("Voice duration diagnostics point to the voice declaration")
    func voiceDurationDiagnosticLocation() async throws {
        let server = UTABLanguageServer()
        let uri = "file:///main.utab"
        let source = """
        module composition.test
        import instruments.guitar
        title "Test"
        instrument guitar : Guitar as "Guitar"
        meter 4/4
        tempo 96
        section verse : 1 bars {
            guitar {
                voice melody {
                    E4 q
                    F4 q
                    G4 q
                    A4 q
                    B4 q
                }
            }
        }
        main { verse }
        """
        let responses = await server.handle(message(
            method: "textDocument/didOpen",
            params: [
                "textDocument": .object([
                    "uri": .string(uri),
                    "languageId": .string("utab"),
                    "version": .number(1),
                    "text": .string(source),
                ]),
            ]
        ))

        let diagnostics = try decode(responses[0])
            .objectValue?["params"]?.objectValue?["diagnostics"]?.arrayValue ?? []
        let durationError = diagnostics.first {
            $0.objectValue?["message"]?.stringValue?.contains("Voice duration is 5/4") == true
        }
        let start = durationError?.objectValue?["range"]?.objectValue?["start"]?.objectValue
        #expect(durationError != nil)
        #expect(start?["line"]?.intValue == 8)
    }

    @Test("Embedded WebSocket carries standard JSON-RPC")
    func embeddedWebSocket() async throws {
        let embedded = EmbeddedUTABLanguageServer()
        let url = try await embedded.start()
        defer { embedded.stop() }

        let data = try await exchangeWebSocketMessage(
            message(method: "initialize", id: 7, params: [:]),
            at: url
        )

        let response = try decode(data).objectValue
        #expect(response?["id"]?.intValue == 7)
        #expect(response?["result"]?.objectValue?["capabilities"] != nil)
    }
    @Test("Scoped naming and rational durations use compiler diagnostics")
    func scopedNamingDiagnostics() async throws {
        let server = UTABLanguageServer()
        let source = """
            import instruments.guitar
            import std.naming.western.german
            meter 4/4
            tempo 100
            instrument guitar : Guitar
            section s { guitar { voice v {
                using notation German
                H4 q.
                tuplet 3:2 { E4 e; Fis4 e; G4 e }
                rest [3/8]
            } } }
            main { s }
            """
        for (version, text) in [(1, source), (2, source.replacingOccurrences(of: "H4 q.", with: "Z4 q."))] {
            let responses = await server.handle(message(method: "textDocument/didOpen", params: [
                "textDocument": .object(["uri": .string("file:///notation.utab"), "languageId": .string("utab"), "version": .number(Double(version)), "text": .string(text)])
            ]))
            let response = try decode(try #require(responses.first)).objectValue
            let diagnostics = response?["params"]?.objectValue?["diagnostics"]?.arrayValue ?? []
            if version == 1 { #expect(diagnostics.isEmpty, "\(diagnostics)") }
            else { #expect(diagnostics.contains { $0.objectValue?["message"]?.stringValue?.contains("Unknown note name 'Z'") == true }) }
        }
    }

    private enum WebSocketUpgradeResult: Sendable {
        case upgraded(NIOAsyncChannel<WebSocketFrame, WebSocketFrame>)
        case rejected
    }

    private enum WebSocketTestError: Error {
        case invalidURL
        case upgradeRejected
        case connectionClosed
    }

    private func exchangeWebSocketMessage(_ message: Data, at url: URL) async throws -> Data {
        guard let host = url.host, let port = url.port else {
            throw WebSocketTestError.invalidURL
        }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let upgradeFuture: EventLoopFuture<WebSocketUpgradeResult> = try await ClientBootstrap(group: group)
                .connect(host: host, port: port) { channel in
                    channel.eventLoop.makeCompletedFuture {
                        let upgrader = NIOTypedWebSocketClientUpgrader<WebSocketUpgradeResult>(
                            upgradePipelineHandler: { channel, _ in
                                channel.eventLoop.makeCompletedFuture {
                                    let asyncChannel = try NIOAsyncChannel<WebSocketFrame, WebSocketFrame>(
                                        wrappingChannelSynchronously: channel
                                    )
                                    return .upgraded(asyncChannel)
                                }
                            }
                        )
                        let request = HTTPRequestHead(
                            version: .http1_1,
                            method: .GET,
                            uri: url.path,
                            headers: ["Host": host]
                        )
                        let configuration = NIOTypedHTTPClientUpgradeConfiguration(
                            upgradeRequestHead: request,
                            upgraders: [upgrader],
                            notUpgradingCompletionHandler: { channel in
                                channel.eventLoop.makeSucceededFuture(.rejected)
                            }
                        )
                        return try channel.pipeline.syncOperations.configureUpgradableHTTPClientPipeline(
                            configuration: .init(upgradeConfiguration: configuration)
                        )
                    }
                }

            let result: Data
            switch try await upgradeFuture.get() {
            case .upgraded(let channel):
                result = try await channel.executeThenClose { inbound, outbound in
                    var buffer = ByteBufferAllocator().buffer(capacity: message.count)
                    buffer.writeBytes(message)
                    let frame = WebSocketFrame(
                        fin: true,
                        opcode: .text,
                        maskKey: [1, 2, 3, 4],
                        data: buffer
                    )
                    try await outbound.write(frame)

                    guard let reply = try await inbound.first(where: {
                        $0.opcode == .text || $0.opcode == .binary
                    }) else {
                        throw WebSocketTestError.connectionClosed
                    }
                    return Data(reply.unmaskedData.readableBytesView)
                }
            case .rejected:
                throw WebSocketTestError.upgradeRejected
            }

            try await group.shutdownGracefully()
            return result
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    private func message(
        method: String,
        id: Int? = nil,
        params: [String: JSONValue]
    ) -> Data {
        var object: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "method": .string(method),
            "params": .object(params),
        ]
        if let id { object["id"] = .number(Double(id)) }
        return try! JSONEncoder().encode(JSONValue.object(object))
    }

    private func decode(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }
}
