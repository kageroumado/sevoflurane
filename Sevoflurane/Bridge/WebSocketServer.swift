import Foundation
import Network

/// One accepted WebSocket client. `NWConnection` is internally thread-safe,
/// so sends may come from any isolation; receive callbacks arrive on the
/// server's queue and are forwarded to the handlers given to ``start``.
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

    /// Begins the receive loop. `onClose` fires exactly once, for any of
    /// error, cancel, a close frame from the peer, or the peer finishing its
    /// side; the connection is cancelled with it.
    func start(
        queue: DispatchQueue,
        onText: @escaping @Sendable (String) -> Void,
        onData: @escaping @Sendable (Data) -> Void,
        onClose: @escaping @Sendable () -> Void,
    ) {
        nonisolated(unsafe) var closed = false
        let finish: @Sendable () -> Void = { [connection] in
            // Runs on `queue` from both stateUpdateHandler and the receive
            // loop, which the serial queue serializes.
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
            // A finished stream with nothing in it is the peer gone: a
            // handshake the gate refused ends this way, with no error.
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

/// A loopback WebSocket server. Each accepted connection is handed to
/// `onConnection` before its receive loop starts, so the owner can register
/// it and then call ``WSConnection/start``.
///
/// The handshake passes through the port's ``LoopbackGate``, and one it
/// refuses is answered 400. The refused connection still reaches
/// `onConnection` — Network.framework offers no way to tell it apart there —
/// and closes as soon as its receive loop starts, so an owner must not treat
/// a connection as its peer before the first message arrives.
final nonisolated class WebSocketServer: Sendable {
    private let listener: NWListener
    let queue: DispatchQueue

    init(port: UInt16, label: String, gate: LoopbackGate, maxMessageSize: Int = 1 << 20) throws {
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

    /// The gate's verdict on one handshake. Network.framework hands the
    /// request's header fields over as `additionalHeaders`, `Host` and
    /// `Origin` among them.
    static func handshakeStatus(
        _ fields: [(name: String, value: String)], gate: LoopbackGate,
    ) -> NWProtocolWebSocket.Response.Status {
        var headers: [String: String] = [:]
        for field in fields {
            headers[field.name.lowercased()] = field.value
        }
        switch gate.verdict(method: "GET", path: "/", headers: headers) {
        case .admitted:
            return .accept
        case let .refused(reason):
            gate.noteRefusal(reason)
            return .reject
        }
    }

    func start(onConnection: @escaping @Sendable (WSConnection) -> Void) {
        listener.newConnectionHandler = { connection in
            onConnection(WSConnection(connection))
        }
        listener.start(queue: queue)
    }
}
