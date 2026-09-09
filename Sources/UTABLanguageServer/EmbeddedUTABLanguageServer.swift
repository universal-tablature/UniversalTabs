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
#if canImport(Network)
import Network
#endif

public enum EmbeddedUTABLanguageServerError: Error {
    case listenerStopped
    case unavailablePort
    case networkFrameworkUnavailable
}

/// Hosts the LSP actor on a loopback WebSocket for an embedded Monaco client.
public final class EmbeddedUTABLanguageServer: @unchecked Sendable {
    private let server: UTABLanguageServer
#if canImport(Network)
    private let queue = DispatchQueue(label: "UniversalTabs.UTABLanguageServer")
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
#endif

    public init(configuration: UTABLanguageServerConfiguration = .init()) {
        server = UTABLanguageServer(configuration: configuration)
    }

    public func setUnpositionedDiagnosticsHandler(
        _ handler: (@Sendable (UTABUnpositionedDiagnosticsUpdate) -> Void)?
    ) async {
        await server.setUnpositionedDiagnosticsHandler(handler)
    }

    public func start() async throws -> URL {
#if canImport(Network)
        if let listener, let port = listener.port {
            return URL(string: "ws://127.0.0.1:\(port.rawValue)/lsp")!
        }

        let webSocketOptions = NWProtocolWebSocket.Options()
        webSocketOptions.autoReplyPing = true
        let parameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocketOptions, at: 0)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)

        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        return try await withCheckedThrowingContinuation { continuation in
            let startup = ListenerStartup(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard let port = listener.port else {
                        startup.fail(EmbeddedUTABLanguageServerError.unavailablePort)
                        return
                    }
                    startup.succeed(URL(string: "ws://127.0.0.1:\(port.rawValue)/lsp")!)
                case .failed(let error):
                    startup.fail(error)
                case .cancelled:
                    startup.fail(EmbeddedUTABLanguageServerError.listenerStopped)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
#else
        throw EmbeddedUTABLanguageServerError.networkFrameworkUnavailable
#endif
    }

    public func stop() {
#if canImport(Network)
        queue.async { [weak self] in
            guard let self else { return }
            listener?.cancel()
            listener = nil
            for connection in connections.values {
                connection.cancel()
            }
            connections.removeAll()
        }
#endif
    }

#if canImport(Network)
    private func accept(_ connection: NWConnection) {
        let id = UUID()
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let connection { receive(on: connection, id: id) }
            case .failed, .cancelled:
                connections[id] = nil
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receive(on connection: NWConnection, id: UUID) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let self, let connection else { return }
            if let data, !data.isEmpty {
                Task {
                    let responses = await server.handle(data)
                    for response in responses {
                        send(response, on: connection)
                    }
                }
            }
            if error == nil {
                receive(on: connection, id: id)
            } else {
                connections[id] = nil
            }
        }
    }

    private func send(_ data: Data, on connection: NWConnection) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(
            identifier: "utab-lsp",
            metadata: [metadata]
        )
        connection.send(
            content: data,
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed { _ in }
        )
    }
#endif
}

#if canImport(Network)
private final class ListenerStartup: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, any Error>?

    init(_ continuation: CheckedContinuation<URL, any Error>) {
        self.continuation = continuation
    }

    func succeed(_ url: URL) {
        finish(with: .success(url))
    }

    func fail(_ error: any Error) {
        finish(with: .failure(error))
    }

    private func finish(with result: Result<URL, any Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
#endif
