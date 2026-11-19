import Foundation
import Network

/// One accepted WebSocket client. Sends may come from any isolation
/// (`NWConnection` is thread-safe); receive callbacks arrive on the server's
/// queue.
final nonisolated class WSConnection: Sendable {
    private let connection: NWConnection

    init(_ connection: NWConnection) {
        self.connection = connection
    }

    func send(text: String) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        connection.send(
            content: Data(text.utf8),
            contentContext: context,
            completion: .contentProcessed { _ in },
        )
    }

    func send(data: Data) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "binary", metadata: [metadata])
        connection.send(
            content: data,
            contentContext: context,
            completion: .contentProcessed { _ in },
        )
    }

    func close() {
        connection.cancel()
    }

    /// Begins the receive loop. `onClose` fires exactly once, for an error,
    /// a cancel, a close frame or the peer finishing, and cancels the
    /// connection.
    func start(
        queue: DispatchQueue,
        onText: @escaping @Sendable (String) -> Void,
        onData: @escaping @Sendable (Data) -> Void,
        onClose: @escaping @Sendable () -> Void,
    ) {
        nonisolated(unsafe) var closed = false
        let finish: @Sendable () -> Void = { [connection] in
            // Both callers run on the serial `queue`.
            if !closed {
                closed = true
                connection.cancel()
                onClose()
            }
        }
        connection.stateUpdateHandler = { state in
            if case .failed = state { finish() }
            if case .cancelled = state { finish() }
        }
        connection.start(queue: queue)
        receive(onText: onText, onData: onData, onClose: finish)
    }

    private func receive(
        onText: @escaping @Sendable (String) -> Void,
        onData: @escaping @Sendable (Data) -> Void,
        onClose: @escaping @Sendable () -> Void,
    ) {
        connection.receiveMessage { [weak self] data, context, isComplete, error in
            guard let self else { return }
            // A finished empty stream is the peer gone, as after a refused
            // handshake.
            if error != nil || (isComplete && data == nil) {
                onClose()
                return
            }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata
            switch metadata?.opcode {
            case .text:
                if let data, let text = String(data: data, encoding: .utf8) { onText(text) }
            case .binary:
                if let data { onData(data) }
            case .close:
                onClose()
                return
            default:
                break
            }
            self.receive(onText: onText, onData: onData, onClose: onClose)
        }
    }
}

/// A loopback WebSocket server. Each accepted connection reaches
/// `onConnection` before its receive loop starts.
///
/// The handshake passes through the port's ``LoopbackGate``, which answers a
/// refusal 400. A refused connection still reaches `onConnection` and closes
/// once its loop starts, so an owner must not treat a connection as its peer
/// before its first message.
final nonisolated class WebSocketServer: Sendable {
    private let listener: NWListener
    let queue: DispatchQueue
    private let label: String
    private let port: UInt16

    init(port: UInt16, label: String, gate: LoopbackGate, maxMessageSize: Int = 1 << 20) throws {
        self.label = label
        self.port = port
        queue = DispatchQueue(label: "sevo.ws.\(label)", qos: .userInitiated)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!,
        )
        parameters.allowLocalEndpointReuse = true
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        websocket.maximumMessageSize = maxMessageSize
        websocket.setClientRequestHandler(queue) { _, additionalHeaders in
            let status = Self.handshakeStatus(additionalHeaders, gate: gate)
            return NWProtocolWebSocket.Response(status: status, subprotocol: nil)
        }
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        listener = try NWListener(using: parameters)
    }

    /// The gate's verdict on one handshake's header fields.
    static func handshakeStatus(
        _ fields: [(name: String, value: String)], gate: LoopbackGate,
    ) -> NWProtocolWebSocket.Response.Status {
        var headers: [String: String] = [:]
        for field in fields {
            headers[field.name.lowercased()] = field.value
        }
        switch gate.verdict(method: "GET", target: "/", headers: headers) {
        case .admitted:
            return .accept
        case let .refused(reason), let .unauthorized(reason):
            gate.noteRefusal(reason)
            return .reject
        }
    }

    func start(onConnection: @escaping @Sendable (WSConnection) -> Void) {
        listener.newConnectionHandler = { connection in
            onConnection(WSConnection(connection))
        }
        // A port another process holds fails here, after `start` returned;
        // unlogged, the page never boots and nothing says why.
        listener.stateUpdateHandler = { [label, port] state in
            if case let .failed(error) = state {
                EventLog.enqueue(.bridge, "\(label) ws :\(port) failed: \(error.localizedDescription)")
            }
        }
        listener.start(queue: queue)
    }
}
