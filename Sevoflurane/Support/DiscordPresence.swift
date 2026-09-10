import Foundation

/// What Sevoflurane is playing, published to the Discord client on this Mac.
///
/// Most Windows games ship no Discord support at all, and Discord's own game
/// scanner sees `wine64-preloader` rather than a game, so nothing appears in a
/// player's status by itself. The app knows the game, its Steam app id and how
/// long it has been running, and Discord's local IPC socket is reachable from
/// the host side, so it publishes the activity directly.
///
/// A game that ships its own Discord library publishes a richer activity of
/// its own through the in-bottle bridge, and that one must win — see
/// ``publishesItsOwn(appID:)``.
///
/// The transport is Discord's RPC framing: an 8-byte header of two
/// little-endian `UInt32`s, opcode then payload length, followed by JSON.
/// Opcode 0 is the handshake, 1 a frame, 2 a close.
actor DiscordPresence {
    /// The session the app publishes through.
    static let shared = DiscordPresence()

    /// The application Discord attributes the activity to.
    ///
    /// The maintainer registers the application at
    /// <https://discord.com/developers/applications> and puts its id here. Its
    /// name is what Discord shows above the activity, so it wants to read
    /// "Sevoflurane". Until then the id is empty, ``isConfigured`` is false,
    /// and the Settings switch is off and disabled.
    static let builtInApplicationID = ""

    /// The application id in force: the `discordApplicationID` preference when
    /// one is set, else the built-in.
    static var applicationID: String {
        let stored = Preferences.shared.string(forKey: applicationIDKey)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return stored.isEmpty ? builtInApplicationID : stored
    }

    static let applicationIDKey = "discordApplicationID"

    /// Whether there is an application id to hand Discord.
    static var isConfigured: Bool {
        !applicationID.isEmpty
    }

    /// One game, as Discord will show it.
    struct Activity: Sendable, Equatable {
        /// The game's name, shown as the activity's details.
        var name: String
        /// The Steam app id, which supplies the artwork and the store link.
        var steamAppID: Int?
        /// When play began.
        var started: Date

        init(name: String, steamAppID: Int? = nil, started: Date = .now) {
            self.name = name
            self.steamAppID = steamAppID
            self.started = started
        }
    }

    enum Failure: Error {
        /// No Discord client answered any of the ten socket indexes.
        case discordAbsent
        /// The socket closed under a read or a write.
        case connectionLost
    }

    private let directory: URL
    private let applicationID: String
    private var socket: Int32?

    /// - Parameters:
    ///   - directory: where the `discord-ipc-N` sockets live. Discord resolves
    ///     the same per-user `TMPDIR` the app does, since neither is sandboxed.
    ///     Injectable so a test can point at a socket of its own.
    ///   - applicationID: the application Discord attributes the activity to.
    init(
        directory: URL = URL(fileURLWithPath: NSTemporaryDirectory()),
        applicationID: String = DiscordPresence.applicationID,
    ) {
        self.directory = directory
        self.applicationID = applicationID
    }

    // MARK: - Publishing

    /// Shows `activity` as what the user is playing, opening the session first
    /// if it is not already open.
    ///
    /// A Discord that refuses the handshake answers with a close frame; the
    /// session ends there and nothing is published. That is an answer, not an
    /// error, so it does not throw.
    func show(_ activity: Activity) throws {
        guard !applicationID.isEmpty else { return }
        if socket == nil {
            guard try openSession() else { return }
        }
        try send(opcode: .frame, payload: Self.setActivity(activity))
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
    }

    /// Opens the socket and completes the handshake.
    ///
    /// - Returns: whether Discord accepted the application id.
    private func openSession() throws -> Bool {
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

    /// The `SET_ACTIVITY` payload for a game that is running.
    ///
    /// `status_display_type` 2 selects the details field, so the member list
    /// reads "Playing <game>" rather than "Playing Sevoflurane". `pid` is the
    /// app's own, which is the process Discord watches to clear the activity.
    static func setActivity(_ activity: Activity) -> Data {
        var payload: [String: Any] = [
            "type": 0,
            "details": activity.name,
            "status_display_type": 2,
            "timestamps": ["start": Int(activity.started.timeIntervalSince1970 * 1000)],
        ]
        if let steamAppID = activity.steamAppID {
            payload["assets"] = [
                "large_image": "https://cdn.cloudflare.steamstatic.com/steam/apps/\(steamAppID)/header.jpg",
                "large_text": activity.name,
                "large_url": "https://store.steampowered.com/app/\(steamAppID)",
            ]
        }
        return command("SET_ACTIVITY", activity: payload)
    }

    /// The `SET_ACTIVITY` payload that takes the activity away.
    static func clearActivity() -> Data {
        command("SET_ACTIVITY", activity: nil)
    }

    private static func command(_ name: String, activity: [String: Any]?) -> Data {
        // A null activity is how SET_ACTIVITY takes the status away, so the
        // key stays and only its value goes.
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
    /// answering. The app is publishing a status line; nothing is worth a
    /// stalled task.
    private static let replyTimeout = timeval(tv_sec: 2, tv_usec: 0)

    /// Whether a Discord client answers one of the sockets right now.
    ///
    /// Discord leaves its socket file behind when it exits and takes the next
    /// free index on restart, so liveness is decided by connecting rather than
    /// by looking. The connection is opened and dropped without a handshake,
    /// which Discord treats as a client that changed its mind.
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
        return descriptor
    }

    private func send(opcode: Opcode, payload: Data) throws {
        guard let socket else { throw Failure.connectionLost }
        var bytes = Self.frame(opcode: opcode, payload: payload)
        try bytes.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.send(
                    socket, buffer.baseAddress! + offset, buffer.count - offset, 0,
                )
                guard written > 0 else { throw Failure.connectionLost }
                offset += written
            }
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

    /// How deep the search goes. A game's Discord dll sits beside its exe or
    /// one folder down, the same shape ``GameExecutables`` scans for.
    private static let maxDepth = 3

    /// Whether the installed game ships a Discord library of its own.
    ///
    /// Such a game publishes its own activity through the in-bottle bridge,
    /// with its own artwork, state and buttons. The app stays quiet so the two
    /// do not fight over the same status line.
    static func publishesItsOwn(appID: Int) -> Bool {
        guard let installed = SharedGames.installed(appID: appID) else { return false }
        var queue: [(URL, Int)] = [(installed.directory, 0)]
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
