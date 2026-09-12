// Copyright 2026 Mattias Holm
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0

import Foundation
import LanguageServerProtocol

/// Typed `swift-tools-protocols` entry point for the UTAB language service.
public final class UTABLSPMessageHandler: MessageHandler, @unchecked Sendable {
    private let server: UTABLanguageServer
    private let lock = NSLock()
    private var client: (any Connection)?

    public init(server: UTABLanguageServer) {
        self.server = server
    }

    public func connect(to client: any Connection) {
        lock.withLock {
            self.client = client
        }
    }

    public func handle(_ notification: some NotificationType) {
        Task {
            if let notification = notification as? DidOpenTextDocumentNotification {
                await forward(notification)
            } else if let notification = notification as? DidChangeTextDocumentNotification {
                await forward(notification)
            } else if let notification = notification as? DidCloseTextDocumentNotification {
                await forward(notification)
            } else if notification is ExitNotification {
                await forward(notification)
            }
        }
    }

    public func handle<Request: RequestType>(
        _ request: Request,
        id: RequestID,
        reply: @Sendable @escaping (LSPResult<Request.Response>) -> Void
    ) {
        if request is InitializeRequest {
            let capabilities = ServerCapabilities(
                textDocumentSync: .options(.init(
                    openClose: true,
                    change: .full,
                    willSave: false,
                    willSaveWaitUntil: false,
                    save: nil
                ))
            )
            reply(.success(InitializeResult(capabilities: capabilities) as! Request.Response))
            return
        }

        if request is ShutdownRequest {
            Task {
                await forwardRequest(request, id: id)
                reply(.success(VoidResponse() as! Request.Response))
            }
            return
        }

        reply(.failure(.methodNotFound(Request.method)))
    }

    private func forward(_ notification: some NotificationType) async {
        guard let data = try? JSONRPCEnvelope.notification(notification) else { return }
        let responses = await server.handle(data)
        for response in responses {
            sendServerNotification(response)
        }
    }

    private func forwardRequest(_ request: some RequestType, id: RequestID) async {
        guard let data = try? JSONRPCEnvelope.request(request, id: id) else { return }
        _ = await server.handle(data)
    }

    private func sendServerNotification(_ data: Data) {
        guard let envelope = try? JSONDecoder().decode(JSONRPCEnvelope.self, from: data),
              envelope.method == PublishDiagnosticsNotification.method,
              let params = envelope.params,
              let paramsData = try? JSONEncoder().encode(params),
              let notification = try? JSONDecoder().decode(PublishDiagnosticsNotification.self, from: paramsData)
        else { return }

        lock.withLock { client }?.send(notification)
    }
}

private struct JSONRPCEnvelope: Codable {
    var jsonrpc = "2.0"
    var id: JSONValue?
    var method: String?
    var params: JSONValue?

    static func notification(_ notification: some NotificationType) throws -> Data {
        let params = try JSONValue.from(notification)
        return try JSONEncoder().encode(JSONRPCEnvelope(method: type(of: notification).method, params: params))
    }

    static func request(_ request: some RequestType, id: RequestID) throws -> Data {
        let params = try JSONValue.from(request)
        let requestID = try JSONValue.from(id)
        return try JSONEncoder().encode(JSONRPCEnvelope(id: requestID, method: type(of: request).method, params: params))
    }
}

private extension JSONValue {
    static func from(_ value: some Encodable) throws -> JSONValue {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
}
