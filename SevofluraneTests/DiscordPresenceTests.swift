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
    func `hands Discord the game's application id, then the game, then nothing`() async throws {
        let discord = try FakeDiscord(replyingWith: .ready)
        defer { discord.stop() }

        let presence = DiscordPresence(directory: discord.directory)
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        try await presence.show(
            .init(applicationID: "1505320535268261888", name: "Subnautica 2", started: started),
            forGame: 1, ticket: 0,
        )
        try await Self.wait(for: 2, on: discord)

        // The handshake is where the game is named: Discord shows the activity
        // as the application it accepted here.
        let handshake = discord.frames[0]
        #expect(handshake.opcode == DiscordPresence.Opcode.handshake.rawValue)
        #expect(String(decoding: handshake.payload, as: UTF8.self)
            == #"{"client_id":"1505320535268261888","v":1}"#)

        let published = discord.frames[1]
        #expect(published.opcode == DiscordPresence.Opcode.frame.rawValue)
        let body = try Self.object(published.payload)
        #expect(body["cmd"] as? String == "SET_ACTIVITY")
        #expect(UUID(uuidString: body["nonce"] as? String ?? "") != nil)

        let arguments = try #require(body["args"] as? [String: Any])
        #expect(arguments["pid"] as? Int == Int(getpid()))
        let activity = try #require(arguments["activity"] as? [String: Any])
        #expect(activity.keys.sorted() == ["timestamps", "type"])
        #expect(activity["type"] as? Int == 0)
        #expect((activity["timestamps"] as? [String: Any])?["start"] as? Int == 1_700_000_000_000)

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

        let presence = DiscordPresence(directory: discord.directory)
        // Discord refusing the application id is an answer, not a fault.
        try await presence.show(.init(applicationID: "0", name: "Subnautica"), forGame: 1, ticket: 0)
        try await Self.wait(for: 1, on: discord)
        try await Task.sleep(for: .milliseconds(200))
        #expect(discord.frames.count == 1)
    }

    @Test
    func `a second game handshakes again under its own application id`() async throws {
        let discord = try FakeDiscord(replyingWith: .ready)
        defer { discord.stop() }

        let presence = DiscordPresence(directory: discord.directory)
        try await presence.show(.init(applicationID: "111", name: "First"), forGame: 1, ticket: 0)
        try await Self.wait(for: 2, on: discord)
        try await presence.show(.init(applicationID: "222", name: "Second"), forGame: 1, ticket: 0)
        try await Self.wait(for: 4, on: discord)

        #expect(discord.frames[2].opcode == DiscordPresence.Opcode.handshake.rawValue)
        #expect(String(decoding: discord.frames[2].payload, as: UTF8.self)
            == #"{"client_id":"222","v":1}"#)
    }

    @Test
    func `publishes nothing for a game with no application id`() async throws {
        let discord = try FakeDiscord(replyingWith: .ready)
        defer { discord.stop() }

        let presence = DiscordPresence(directory: discord.directory)
        try await presence.show(.init(applicationID: "", name: "Subnautica"), forGame: 1, ticket: 0)
        try await Task.sleep(for: .milliseconds(200))
        #expect(discord.frames.isEmpty)
    }

    @Test
    func `a write to a Discord that has hung up throws instead of signalling`() async throws {
        let discord = try FakeDiscord(replyingWith: .hangsUpAfterActivity)
        defer { discord.stop() }

        let presence = DiscordPresence(directory: discord.directory)
        try await presence.show(.init(applicationID: "111", name: "First"), forGame: 1, ticket: 0)
        try await Self.wait(for: 2, on: discord)
        try await Task.sleep(for: .milliseconds(100))
        // The peer is gone. A write raises SIGPIPE unless the socket opts out,
        // and the signal ends the test host before this line returns.
        await #expect(throws: DiscordPresence.Failure.self) {
            try await presence.show(.init(applicationID: "111", name: "First"), forGame: 1, ticket: 0)
        }
    }

    @Test
    func `clearing another game keeps the activity`() async throws {
        let discord = try FakeDiscord(replyingWith: .ready)
        defer { discord.stop() }

        let presence = DiscordPresence(directory: discord.directory)
        try await presence.show(.init(applicationID: "111", name: "First"), forGame: 1, ticket: 0)
        try await Self.wait(for: 2, on: discord)
        await presence.clear(forGame: 2)
        try await Task.sleep(for: .milliseconds(200))
        #expect(discord.frames.count == 2)

        await presence.clear(forGame: 1)
        try await Self.wait(for: 3, on: discord)
    }

    @Test
    func `a game that stopped during the lookup publishes nothing`() async throws {
        let discord = try FakeDiscord(replyingWith: .ready)
        defer { discord.stop() }

        let presence = DiscordPresence(directory: discord.directory)
        let ticket = presence.ticket(forGame: 7)
        presence.gameStopped(7)
        try await presence.show(.init(applicationID: "111", name: "First"), forGame: 7, ticket: ticket)
        try await Task.sleep(for: .milliseconds(200))
        #expect(discord.frames.isEmpty)

        try await presence.show(
            .init(applicationID: "111", name: "First"),
            forGame: 7, ticket: presence.ticket(forGame: 7),
        )
        try await Self.wait(for: 2, on: discord)
    }

    /// The app keeps its Discord connection open for the life of the game,
    /// so the fake sits mid-session on a client that never hangs up when its
    /// test ends. A fake that waited for the peer there kept the test host
    /// alive after the suite (2026-09-26, with Discord running beside it).
    @Test
    func `a client that never hangs up does not keep the fake serving`() throws {
        let discord = try FakeDiscord(replyingWith: .ready)
        let client = try #require(DiscordPresence.connectToDiscord(in: discord.directory))
        defer { Darwin.close(client) }
        // Long enough for the fake to accept the client and wait on it.
        Thread.sleep(forTimeInterval: 0.3)
        #expect(discord.stop())
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
        /// A Discord that accepts the application id and one activity, then quits.
        case hangsUpAfterActivity
    }

    let directory: URL

    private let listener: Int32
    private let reply: Reply
    private let lock = NSLock()
    private var received: [(opcode: UInt32, payload: Data)] = []
    private var stopped = false
    /// Signalled once the serving thread has returned.
    private let served = DispatchSemaphore(value: 0)

    /// How long one wait on the wire lasts before `stopped` is looked at
    /// again. The sockets block otherwise, and the app keeps its Discord
    /// connection open for the life of the game: a fake that waited in
    /// `recv` for the peer to hang up waited for the rest of the test host's
    /// life (2026-09-26, Discord running beside the suite).
    private static let pollMilliseconds: Int32 = 100

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

    /// Ends the serving thread and removes the socket. Returns once the
    /// thread has returned, so nothing of the fake outlives its test; false
    /// when it has not within two seconds.
    @discardableResult
    func stop() -> Bool {
        lock.withLock { stopped = true }
        Darwin.shutdown(listener, SHUT_RDWR)
        Darwin.close(listener)
        let ended = served.wait(timeout: .now() + 2) == .success
        try? FileManager.default.removeItem(at: directory)
        return ended
    }

    /// Whether `descriptor` has something to read, waited for in
    /// ``pollMilliseconds`` slices so a stop is seen between them. False once
    /// stopped, and for a descriptor that is gone.
    private func waitReadable(_ descriptor: Int32) -> Bool {
        while !lock.withLock({ stopped }) {
            var watched = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = Darwin.poll(&watched, 1, Self.pollMilliseconds)
            if ready > 0 { return watched.revents & Int16(POLLNVAL) == 0 }
            if ready < 0, errno != EINTR { return false }
        }
        return false
    }

    /// Serves one client at a time, for as many as connect: a game that
    /// replaces another opens a second session under its own application id.
    private func serve() {
        defer { served.signal() }
        while waitReadable(listener) {
            let client = Darwin.accept(listener, nil, nil)
            guard client >= 0 else { return }
            session(client)
            Darwin.close(client)
        }
    }

    private func session(_ client: Int32) {
        while !lock.withLock({ stopped }) {
            guard let header = read(client, exactly: 8) else { return }
            let opcode = header.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            let length = header.dropFirst(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            guard let payload = length > 0 ? read(client, exactly: Int(length)) : Data() else {
                return
            }
            lock.withLock { received.append((UInt32(littleEndian: opcode), payload)) }
            guard opcode == DiscordPresence.Opcode.handshake.rawValue else {
                if reply == .hangsUpAfterActivity { return }
                continue
            }
            switch reply {
            case .ready, .hangsUpAfterActivity:
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

    /// Exactly `count` bytes, or nil once the fake is stopped or the client
    /// has hung up.
    private func read(_ client: Int32, exactly count: Int) -> Data? {
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            guard waitReadable(client) else { return nil }
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
