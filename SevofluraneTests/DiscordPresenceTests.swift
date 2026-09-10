import Foundation
import Testing
@testable import Sevoflurane

/// What the app says to the Discord client on its local socket.
///
/// The tests drive the real socket path against a Discord of their own, so the
/// framing, the handshake and the activity JSON are asserted as bytes on a
/// wire rather than as the arguments of a mock.
struct DiscordPresenceTests {
    @Test
    func `frames carry the opcode and the length little-endian`() {
        let frame = DiscordPresence.frame(opcode: .handshake, payload: Data("ab".utf8))
        #expect(Array(frame) == [0, 0, 0, 0, 2, 0, 0, 0, 0x61, 0x62])

        let close = DiscordPresence.frame(opcode: .close, payload: Data())
        #expect(Array(close) == [2, 0, 0, 0, 0, 0, 0, 0])
    }

    @Test
    func `finds no Discord in a directory that holds none`() throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(DiscordPresence.connectToDiscord(in: directory) == nil)
        #expect(!DiscordPresence.isDiscordRunning(in: directory))
    }

    @Test
    func `hands Discord the application id, then the game, then nothing`() async throws {
        let discord = try FakeDiscord(replyingWith: .ready)
        defer { discord.stop() }

        let presence = DiscordPresence(directory: discord.directory, applicationID: "1234")
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        try await presence.show(
            .init(name: "Subnautica", steamAppID: 264_710, started: started),
        )
        try await Self.wait(for: 2, on: discord)

        let handshake = discord.frames[0]
        #expect(handshake.opcode == DiscordPresence.Opcode.handshake.rawValue)
        #expect(String(decoding: handshake.payload, as: UTF8.self) == #"{"client_id":"1234","v":1}"#)

        let published = discord.frames[1]
        #expect(published.opcode == DiscordPresence.Opcode.frame.rawValue)
        let body = try Self.object(published.payload)
        #expect(body["cmd"] as? String == "SET_ACTIVITY")
        #expect(UUID(uuidString: body["nonce"] as? String ?? "") != nil)

        let arguments = try #require(body["args"] as? [String: Any])
        #expect(arguments["pid"] as? Int == Int(getpid()))
        let activity = try #require(arguments["activity"] as? [String: Any])
        #expect(activity["type"] as? Int == 0)
        #expect(activity["details"] as? String == "Subnautica")
        // 2 is DETAILS, so the member list reads "Playing Subnautica" rather
        // than "Playing Sevoflurane".
        #expect(activity["status_display_type"] as? Int == 2)
        #expect((activity["timestamps"] as? [String: Any])?["start"] as? Int == 1_700_000_000_000)
        let assets = try #require(activity["assets"] as? [String: Any])
        #expect(assets["large_image"] as? String
            == "https://cdn.cloudflare.steamstatic.com/steam/apps/264710/header.jpg")
        #expect(assets["large_url"] as? String == "https://store.steampowered.com/app/264710")

        await presence.clear()
        try await Self.wait(for: 3, on: discord)
        let cleared = try Self.object(discord.frames[2].payload)
        let clearedArguments = try #require(cleared["args"] as? [String: Any])
        #expect(clearedArguments["activity"] is NSNull)
    }

    @Test
    func `a close reply ends the session and publishes nothing`() async throws {
        let discord = try FakeDiscord(replyingWith: .close)
        defer { discord.stop() }

        let presence = DiscordPresence(directory: discord.directory, applicationID: "0")
        // Discord refusing the application id is an answer, not a fault.
        try await presence.show(.init(name: "Subnautica"))
        try await Self.wait(for: 1, on: discord)
        try await Task.sleep(for: .milliseconds(200))
        #expect(discord.frames.count == 1)
    }

    @Test
    func `publishes nothing without an application id`() async throws {
        let discord = try FakeDiscord(replyingWith: .ready)
        defer { discord.stop() }

        let presence = DiscordPresence(directory: discord.directory, applicationID: "")
        try await presence.show(.init(name: "Subnautica"))
        try await Task.sleep(for: .milliseconds(200))
        #expect(discord.frames.isEmpty)
    }

    // MARK: - Helpers

    /// A directory short enough for `sun_path`, which holds 104 bytes.
    private static func makeDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dp-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func object(_ payload: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
    }

    private static func wait(for count: Int, on discord: FakeDiscord) async throws {
        for _ in 0 ..< 100 where discord.frames.count < count {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(discord.frames.count >= count)
    }
}

/// A Discord client that only listens, records what it is told, and answers the
/// handshake one agreed way.
private final class FakeDiscord: @unchecked Sendable {
    enum Reply {
        /// What a Discord that accepted the application id sends back.
        case ready
        /// What a Discord that refused it sends back.
        case close
    }

    let directory: URL

    private let listener: Int32
    private let reply: Reply
    private let lock = NSLock()
    private var received: [(opcode: UInt32, payload: Data)] = []
    private var stopped = false

    var frames: [(opcode: UInt32, payload: Data)] {
        lock.withLock { received }
    }

    init(replyingWith reply: Reply) throws {
        self.reply = reply
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dp-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let path = directory.appendingPathComponent("discord-ipc-0").path
        listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        withUnsafeMutablePointer(to: &address.sun_path) { field in
            field.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                _ = strlcpy(destination, path, capacity)
            }
        }
        let bound = withUnsafePointer(to: &address) { unix in
            unix.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                Darwin.bind(listener, generic, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        #expect(bound == 0)
        #expect(Darwin.listen(listener, 4) == 0)

        let thread = Thread { [weak self] in self?.serve() }
        thread.stackSize = 512 * 1024
        thread.start()
    }

    func stop() {
        lock.withLock { stopped = true }
        Darwin.close(listener)
        try? FileManager.default.removeItem(at: directory)
    }

    private func serve() {
        let client = Darwin.accept(listener, nil, nil)
        guard client >= 0 else { return }
        defer { Darwin.close(client) }
        while !lock.withLock({ stopped }) {
            guard let header = read(client, exactly: 8) else { return }
            let opcode = header.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            let length = header.dropFirst(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            guard let payload = length > 0 ? read(client, exactly: Int(length)) : Data() else {
                return
            }
            lock.withLock { received.append((UInt32(littleEndian: opcode), payload)) }
            guard opcode == DiscordPresence.Opcode.handshake.rawValue else { continue }
            switch reply {
            case .ready:
                write(client, DiscordPresence.frame(
                    opcode: .frame, payload: Data(#"{"evt":"READY"}"#.utf8),
                ))
            case .close:
                write(client, DiscordPresence.frame(
                    opcode: .close,
                    payload: Data(#"{"code":4000,"message":"Invalid Client ID"}"#.utf8),
                ))
                return
            }
        }
    }

    private func read(_ client: Int32, exactly count: Int) -> Data? {
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let got = bytes.withUnsafeMutableBytes { buffer in
                Darwin.recv(client, buffer.baseAddress! + offset, count - offset, 0)
            }
            guard got > 0 else { return nil }
            offset += got
        }
        return Data(bytes)
    }

    private func write(_ client: Int32, _ data: Data) {
        var bytes = data
        bytes.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let sent = Darwin.send(
                    client, buffer.baseAddress! + offset, buffer.count - offset, 0,
                )
                guard sent > 0 else { return }
                offset += sent
            }
        }
    }
}
