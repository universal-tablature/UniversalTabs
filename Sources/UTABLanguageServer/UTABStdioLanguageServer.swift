// Copyright 2026 Mattias Holm
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0

import Foundation
import LanguageServerProtocol
import LanguageServerProtocolTransport

/// Runs the UTAB language server using standard LSP `Content-Length` framing.
public enum UTABStdioLanguageServer {
    public static func run(configuration: UTABLanguageServerConfiguration = .init()) async {
        let server = UTABLanguageServer(configuration: configuration)
        let handler = UTABLSPMessageHandler(server: server)
        let connection = JSONRPCConnection(
            name: "utab-lsp",
            protocol: .lspProtocol,
            receiveFD: .standardInput,
            sendFD: .standardOutput
        )
        handler.connect(to: connection)

        await withCheckedContinuation { continuation in
            connection.start(receiveHandler: handler) {
                continuation.resume()
            }
        }
    }
}
