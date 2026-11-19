import Darwin
import Foundation
import Testing
@testable import Sevoflurane

/// The loopback server's bound on open connections, driven over real sockets.
struct HTTPServerConnectionTests {
    /// A blocking loopback socket connected to `port`, or -1.
    private static func connect(to port: UInt16) -> Int32 {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { return -1 }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            close(socket)
            return -1
        }
        return socket
    }

    /// Connections that never send a request cannot fill the server: at the
    /// limit, a new one takes the place of the longest-silent, and its request
    /// is answered.
    @Test
    func `silent connections cannot lock out a client`() async throws {
        let port = UInt16.random(in: 42000 ..< 48000)
        let server = try HTTPServer(port: port, gate: LoopbackGate(port: port, origins: [])) { _ in
            .ok(Data("hello".utf8), type: "text/plain")
        }
        try await server.startWaitingForThePort()

        var silent: [Int32] = []
        defer { silent.forEach { close($0) } }
        for _ in 0 ..< HTTPServer.connectionLimit {
            let socket = Self.connect(to: port)
            try #require(socket >= 0)
            silent.append(socket)
        }
        // Let the listener register every one before the client arrives.
        try await Task.sleep(for: .milliseconds(300))

        let client = Self.connect(to: port)
        try #require(client >= 0)
        defer { close(client) }
        let request = "GET /x HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nConnection: close\r\n\r\n"
        _ = request.withCString { send(client, $0, strlen($0), 0) }
        var buffer = [UInt8](repeating: 0, count: 512)
        let received = recv(client, &buffer, buffer.count, 0)
        let reply = String(decoding: buffer.prefix(max(0, received)), as: UTF8.self)
        #expect(reply.hasPrefix("HTTP/1.1 "))
    }
}
