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

public enum EmbeddedUTABLanguageServerError: Error {
    case listenerStopped
    case unavailablePort
}

/// Hosts the LSP service on a cross-platform loopback WebSocket for Monaco.
public final class EmbeddedUTABLanguageServer: @unchecked Sendable {
    private let server: UTABLanguageServer
    private let lock = NSLock()
    private var eventLoopGroup: MultiThreadedEventLoopGroup?
    private var channel: Channel?

    public init(configuration: UTABLanguageServerConfiguration = .init()) {
        server = UTABLanguageServer(configuration: configuration)
    }

    public func setUnpositionedDiagnosticsHandler(
        _ handler: (@Sendable (UTABUnpositionedDiagnosticsUpdate) -> Void)?
    ) async {
        await server.setUnpositionedDiagnosticsHandler(handler)
    }

    public func start() async throws -> URL {
        if let port = lock.withLock({ channel?.localAddress?.port }) {
            return try webSocketURL(port: port)
        }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let server = self.server
            let bootstrap = ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.backlog, value: 16)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    let upgrader = NIOWebSocketServerUpgrader(
                        shouldUpgrade: { channel, request in
                            guard request.uri == "/lsp" else {
                                return channel.eventLoop.makeSucceededFuture(nil)
                            }
                            return channel.eventLoop.makeSucceededFuture(HTTPHeaders())
                        },
                        upgradePipelineHandler: { channel, _ in
                            channel.pipeline.addHandler(UTABWebSocketHandler(server: server))
                        }
                    )
                    return channel.pipeline.configureHTTPServerPipeline(
                        withServerUpgrade: (
                            upgraders: [upgrader],
                            completionHandler: { _ in }
                        )
                    )
                }
                .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

            let channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
            guard let port = channel.localAddress?.port else {
                try await channel.close().get()
                throw EmbeddedUTABLanguageServerError.unavailablePort
            }
            lock.withLock {
                eventLoopGroup = group
                self.channel = channel
            }
            return try webSocketURL(port: port)
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    public func stop() {
        let resources = lock.withLock { () -> (Channel?, MultiThreadedEventLoopGroup?) in
            defer {
                channel = nil
                eventLoopGroup = nil
            }
            return (channel, eventLoopGroup)
        }
        resources.0?.close(promise: nil)
        resources.1?.shutdownGracefully { _ in }
    }

    private func webSocketURL(port: Int) throws -> URL {
        guard let url = URL(string: "ws://127.0.0.1:\(port)/lsp") else {
            throw EmbeddedUTABLanguageServerError.unavailablePort
        }
        return url
    }
}

private final class UTABWebSocketHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let server: UTABLanguageServer
    private var fragmentedMessage: ByteBuffer?

    init(server: UTABLanguageServer) {
        self.server = server
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var frame = unwrapInboundIn(data)
        switch frame.opcode {
        case .text, .binary:
            if frame.fin {
                dispatch(frame.unmaskedData, context: context)
            } else {
                fragmentedMessage = frame.unmaskedData
            }
        case .continuation:
            var continuationData = frame.unmaskedData
            if fragmentedMessage == nil {
                fragmentedMessage = context.channel.allocator.buffer(capacity: continuationData.readableBytes)
            }
            fragmentedMessage?.writeBuffer(&continuationData)
            if frame.fin, let message = fragmentedMessage {
                fragmentedMessage = nil
                dispatch(message, context: context)
            }
        case .ping:
            context.writeAndFlush(wrapOutboundOut(WebSocketFrame(fin: true, opcode: .pong, data: frame.unmaskedData)), promise: nil)
        case .connectionClose:
            context.close(promise: nil)
        default:
            break
        }
    }

    private func dispatch(_ buffer: ByteBuffer, context: ChannelHandlerContext) {
        let payload = Data(buffer.readableBytesView)
        let contextBox = SendableContext(context)
        Task {
            let responses = await server.handle(payload)
            contextBox.value.eventLoop.execute {
                let context = contextBox.value
                for response in responses {
                    var buffer = context.channel.allocator.buffer(capacity: response.count)
                    buffer.writeBytes(response)
                    let frame = WebSocketFrame(fin: true, opcode: .text, data: buffer)
                    context.write(self.wrapOutboundOut(frame), promise: nil)
                }
                context.flush()
            }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }
}

private final class SendableContext: @unchecked Sendable {
    let value: ChannelHandlerContext

    init(_ value: ChannelHandlerContext) {
        self.value = value
    }
}
