import Foundation
import Synchronization

/// What the player is playing, published to the Discord client on this Mac
/// under the game's own Discord application.
///
/// The activity goes under the application id Discord's database gives the
/// game (``DiscordApplications``), so it reads "Playing Subnautica 2" with
/// the game's icon. A game the database does not name goes under
/// ``fallbackApplicationID`` with its own name and Steam box art, which
/// Discord shows over the application's.
///
/// Most Windows games ship no Discord support, and Discord's own game scanner
/// sees `wine64-preloader` rather than a game, so the app publishes the
/// activity itself over Discord's local IPC socket.
///
/// A game that ships its own Discord library wins
/// (``publishesItsOwn(appID:)``).
///
/// Discord's RPC framing: two little-endian `UInt32`s, opcode then payload
/// length, followed by JSON.
actor DiscordPresence {
    /// The session the app publishes through.
    static let shared = DiscordPresence()

    /// Sevoflurane's Discord application, for games the database lacks.
    static let fallbackApplicationID = "1562606589373055026"

    /// One game, as Discord will show it.
    struct Activity: Sendable, Equatable {
        var applicationID: String
        var name: String
        /// Box art, used under ``fallbackApplicationID`` only.
        var cover: URL?
        var started: Date

        init(applicationID: String, name: String, cover: URL? = nil, started: Date = .now) {
            self.applicationID = applicationID
            self.name = name
            self.cover = cover
            self.started = started
        }

        var isFallback: Bool {
            applicationID == fallbackApplicationID
        }

        /// A game Discord's database does not name, under Sevoflurane's
        /// application, pictured by `cover` when Steam has art for it.
        static func fallback(named name: String, cover: URL? = nil, started: Date = .now) -> Activity {
            Activity(applicationID: fallbackApplicationID, name: name, cover: cover, started: started)
        }
    }

    enum Failure: Error {
        /// No Discord client answered any of the ten socket indexes.
        case discordAbsent
        /// The socket closed under a read or a write.
        case connectionLost
    }

    private let directory: URL
    private var socket: Int32?
    /// The application the open session handshook with.
    private var openApplicationID: String?
    /// The Steam game whose activity is on the status line.
    private var shownGame: Int?
    /// Stops per game: a publish whose ticket no longer matches is for a game
    /// already gone. Locked rather than isolated, so the main actor orders a
    /// stop against publishes it started earlier.
    private nonisolated let stops = Mutex<[Int: UInt64]>([:])

    /// - Parameter directory: where the `discord-ipc-N` sockets live, the
    ///   per-user `TMPDIR` both unsandboxed apps share.
    init(directory: URL = URL(fileURLWithPath: NSTemporaryDirectory())) {
        self.directory = directory
    }

    // MARK: - Publishing

    /// The ticket a publish carries, good until the game stops.
    nonisolated func ticket(forGame appID: Int) -> UInt64 {
        stops.withLock { $0[appID, default: 0] }
    }

    /// Marks `appID` as stopped, which voids every ticket taken for it so far.
    nonisolated func gameStopped(_ appID: Int) {
        stops.withLock { $0[appID, default: 0] &+= 1 }
    }

    /// Shows `activity` for `appID`, opening the session if needed; a voided
    /// `ticket` publishes nothing.
    ///
    /// A Discord that refuses the handshake answers with a close frame; the
    /// session ends there and nothing is published, without throwing.
    func show(_ activity: Activity, forGame appID: Int, ticket: UInt64) throws {
        guard !activity.applicationID.isEmpty, ticket == self.ticket(forGame: appID) else { return }
        if openApplicationID != activity.applicationID { end() }
        if socket == nil {
            guard try openSession(applicationID: activity.applicationID) else { return }
        }
        try send(opcode: .frame, payload: Self.setActivity(activity))
        shownGame = appID
    }

    /// Withdraws the activity and ends the session if it is `appID`'s.
    func clear(forGame appID: Int) {
        guard shownGame == appID else { return }
        clear()
    }

    /// Withdraws the activity and ends the session.
    func clear() {
        guard socket != nil else { return }
        try? send(opcode: .frame, payload: Self.clearActivity())
        end()
    }

    /// Closes the socket without telling Discord, for a quit that has no time
    /// to be polite. Discord drops the activity when the connection goes.
    func end() {
        if let socket { Darwin.close(socket) }
        socket = nil
        openApplicationID = nil
        shownGame = nil
    }

    /// Opens the socket and handshakes; answers whether Discord accepted.
    private func openSession(applicationID: String) throws -> Bool {
        guard let opened = Self.connectToDiscord(in: directory) else { throw Failure.discordAbsent }
        socket = opened
        let handshake = Self.json(["v": 1, "client_id": applicationID])
        do {
            try send(opcode: .handshake, payload: handshake)
            let reply = try receiveFrame()
            guard reply.opcode != .close else {
                end()
                return false
            }
        } catch {
            end()
            throw error
        }
        openApplicationID = applicationID
        return true
    }

    // MARK: - The frames

    enum Opcode: UInt32 {
        case handshake = 0
        case frame = 1
        case close = 2
        case ping = 3
        case pong = 4
    }

    /// One frame's bytes: opcode, payload length, payload.
    static func frame(opcode: Opcode, payload: Data) -> Data {
        var bytes = Data(capacity: 8 + payload.count)
        for value in [opcode.rawValue, UInt32(payload.count)] {
            withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
        }
        bytes.append(payload)
        return bytes
    }

    /// The `SET_ACTIVITY` payload: type and start time, plus for a fallback
    /// the game's `name` and an `https` `large_image`, which Discord shows
    /// over the application's. `pid` is the app's, which Discord watches to
    /// clear the activity.
    static func setActivity(_ activity: Activity) -> Data {
        var payload: [String: Any] = [
            "type": 0,
            "timestamps": ["start": Int(activity.started.timeIntervalSince1970 * 1000)],
        ]
        if activity.isFallback {
            payload["name"] = activity.name
            if let cover = activity.cover {
                payload["assets"] = ["large_image": cover.absoluteString, "large_text": activity.name]
            }
        }
        return command("SET_ACTIVITY", activity: payload)
    }

    /// The `SET_ACTIVITY` payload that takes the activity away.
    static func clearActivity() -> Data {
        command("SET_ACTIVITY", activity: nil)
    }

    private static func command(_ name: String, activity: [String: Any]?) -> Data {
        // A null activity clears the status, so the key stays.
        let arguments: [String: Any] = [
            "pid": Int(getpid()),
            "activity": activity.map { $0 as Any } ?? NSNull(),
        ]
        return json(["cmd": name, "nonce": UUID().uuidString, "args": arguments])
    }

    private static func json(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes],
        )) ?? Data()
    }

    // MARK: - The socket

    /// How long a read waits before giving up on a Discord that has stopped
    /// answering.
    private static let replyTimeout = timeval(tv_sec: 2, tv_usec: 0)

    /// Whether a Discord client answers a socket now, by connecting: Discord
    /// leaves stale socket files behind.
    static func isDiscordRunning(
        in directory: URL = URL(fileURLWithPath: NSTemporaryDirectory()),
    ) -> Bool {
        guard let socket = connectToDiscord(in: directory) else { return false }
        Darwin.close(socket)
        return true
    }

    static func connectToDiscord(in directory: URL) -> Int32? {
        for index in 0 ... 9 {
            let path = directory.appendingPathComponent("discord-ipc-\(index)").path
            if let socket = connect(toSocketAt: path) { return socket }
        }
        return nil
    }

    private static func connect(toSocketAt path: String) -> Int32? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { return nil }
        withUnsafeMutablePointer(to: &address.sun_path) { field in
            field.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                _ = strlcpy(destination, path, capacity)
            }
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        let joined = withUnsafePointer(to: &address) { unix in
            unix.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                Darwin.connect(descriptor, generic, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard joined == 0 else {
            Darwin.close(descriptor)
            return nil
        }
        var timeout = replyTimeout
        setsockopt(
            descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size),
        )
        // Without this a write to a quit Discord raises SIGPIPE and ends the
        // app.
        var noSignal: Int32 = 1
        setsockopt(
            descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size),
        )
        return descriptor
    }

    /// Writes one frame; a failed write ends the session.
    private func send(opcode: Opcode, payload: Data) throws {
        guard let socket else { throw Failure.connectionLost }
        var bytes = Self.frame(opcode: opcode, payload: payload)
        let delivered = bytes.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.send(
                    socket, buffer.baseAddress! + offset, buffer.count - offset, 0,
                )
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
        guard delivered else {
            end()
            throw Failure.connectionLost
        }
    }

    private func receiveFrame() throws -> (opcode: Opcode, payload: Data) {
        let header = try receive(exactly: 8)
        let opcode = header.prefix(4).littleEndianUInt32
        let length = header.dropFirst(4).littleEndianUInt32
        let payload = length > 0 ? try receive(exactly: Int(length)) : Data()
        return (Opcode(rawValue: opcode) ?? .close, payload)
    }

    private func receive(exactly count: Int) throws -> Data {
        guard let socket else { throw Failure.connectionLost }
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let got = bytes.withUnsafeMutableBytes { buffer in
                recv(socket, buffer.baseAddress! + offset, count - offset, 0)
            }
            guard got > 0 else { throw Failure.connectionLost }
            offset += got
        }
        return Data(bytes)
    }

    // MARK: - Games that publish their own

    /// Files that mean the game talks to Discord itself.
    private static let ownLibraries = [
        "discord_game_sdk.dll", "discord_partner_sdk.dll", "discord-rpc.dll", "discord-rpc64.dll",
    ]

    /// How many folders down the search goes.
    private static let maxDepth = 3

    /// Whether the game ships a Discord library of its own and so publishes
    /// through the in-bottle bridge, where the app stays quiet.
    static func publishesItsOwn(appID: Int) -> Bool {
        let folder = AdoptedPrograms.program(appID)?.url.deletingLastPathComponent()
            ?? SharedGames.installed(appID: appID)?.directory
        guard let folder else { return false }
        return shipsDiscordLibrary(in: folder)
    }

    /// Whether `folder`, or a folder up to ``maxDepth`` below it, holds a
    /// Discord library.
    static func shipsDiscordLibrary(in folder: URL) -> Bool {
        var queue: [(URL, Int)] = [(folder, 0)]
        while let (folder, depth) = queue.first {
            queue.removeFirst()
            for entry in InstallDirectory.entries(in: folder) {
                if entry.isDirectory {
                    if depth + 1 <= maxDepth { queue.append((entry.url, depth + 1)) }
                    continue
                }
                let name = entry.name.lowercased()
                if ownLibraries.contains(name) { return true }
                if name.hasPrefix("discord-rpc"), name.hasSuffix(".dll") { return true }
            }
        }
        return false
    }
}

private extension Data {
    /// The first four bytes read as a little-endian `UInt32`.
    nonisolated var littleEndianUInt32: UInt32 {
        reduce(into: (value: UInt32(0), shift: UInt32(0))) { total, byte in
            total.value |= UInt32(byte) << total.shift
            total.shift += 8
        }.value
    }
}
